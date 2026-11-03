//! Spending policy for an AI agent, deployed on the user's own NEAR account.
//!
//! The account has two keys:
//! - the Keyring card's secp256k1 key — full access, the human ("approver");
//! - the agent's key — a function-call key that may only call `request_spend` here.
//!
//! A spend inside the policy (per-transaction cap, daily budget, allowlisted receiver) is paid
//! at once. Anything else is parked as pending until the card signs `approve` or `reject`.
//! Every method also checks *which key* signed, so the policy holds even if the agent's key
//! were granted more methods by mistake.

use near_sdk::json_types::U64;
use near_sdk::serde_json::json;
use near_sdk::store::IterableMap;
use near_sdk::{
    env, near, require, AccountId, Gas, NearToken, PanicOnDefault, Promise, PromiseError,
    PublicKey,
};

const NANOS_PER_DAY: u64 = 86_400 * 1_000_000_000;
const MAX_PENDING: u32 = 32;
const MAX_MEMO_LEN: usize = 256;
const CALLBACK_GAS: Gas = Gas::from_tgas(5);

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug, PartialEq)]
pub struct Policy {
    /// Largest single payment the agent may make on its own.
    pub per_tx_max: NearToken,
    /// Total the agent may pay on its own per UTC day.
    pub daily_max: NearToken,
    /// Receivers the agent may pay on its own. Empty means any receiver.
    pub allowlist: Vec<AccountId>,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum HoldReason {
    OverTxLimit,
    OverDailyLimit,
    NotAllowlisted,
}

#[near(serializers = [borsh, json])]
#[derive(Clone, Debug, PartialEq)]
pub struct PendingSpend {
    pub id: U64,
    pub receiver_id: AccountId,
    pub amount: NearToken,
    pub memo: String,
    pub reason: HoldReason,
    pub requested_at: U64,
}

#[near(serializers = [json])]
#[serde(tag = "status", rename_all = "snake_case")]
#[derive(Debug, PartialEq)]
pub enum SpendOutcome {
    Paid,
    Pending { id: U64, reason: HoldReason },
}

#[near(serializers = [json])]
#[derive(Debug, PartialEq)]
pub struct Budget {
    pub spent_today: NearToken,
    pub remaining_today: NearToken,
}

#[near(serializers = [json])]
#[derive(Debug, PartialEq)]
pub struct Keys {
    pub approver_key: PublicKey,
    pub agent_key: PublicKey,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct SpendPolicy {
    approver_key: PublicKey,
    agent_key: PublicKey,
    policy: Policy,
    day: u64,
    spent_today: NearToken,
    next_id: u64,
    pending: IterableMap<u64, PendingSpend>,
}

#[near]
impl SpendPolicy {
    #[init]
    pub fn new(approver_key: PublicKey, agent_key: PublicKey, policy: Policy) -> Self {
        require!(approver_key != agent_key, "approver and agent keys must differ");
        Self {
            approver_key,
            agent_key,
            policy,
            day: today(),
            spent_today: NearToken::from_yoctonear(0),
            next_id: 0,
            pending: IterableMap::new(b"p"),
        }
    }

    /// Agent: pay `amount` to `receiver_id`, or park it for the card if it breaks the policy.
    pub fn request_spend(
        &mut self,
        receiver_id: AccountId,
        amount: NearToken,
        memo: String,
    ) -> SpendOutcome {
        self.assert_signed_by(&self.agent_key, "agent");
        require!(!amount.is_zero(), "amount must be positive");
        require!(memo.len() <= MAX_MEMO_LEN, "memo too long");
        self.roll_day();

        let reason = if amount > self.policy.per_tx_max {
            Some(HoldReason::OverTxLimit)
        } else if self.spent_today.saturating_add(amount) > self.policy.daily_max {
            Some(HoldReason::OverDailyLimit)
        } else if !self.policy.allowlist.is_empty() && !self.policy.allowlist.contains(&receiver_id) {
            Some(HoldReason::NotAllowlisted)
        } else {
            None
        };

        match reason {
            None => {
                self.spent_today = self.spent_today.saturating_add(amount);
                emit("spend_paid", json!({ "receiver_id": receiver_id, "amount": amount, "memo": memo, "by": "agent" }));
                self.pay(receiver_id, amount, true);
                SpendOutcome::Paid
            }
            Some(reason) => {
                // Parked spends cost this account storage, so the agent cannot flood the queue.
                require!(self.pending.len() < MAX_PENDING, "too many pending spends");
                let id = self.next_id;
                self.next_id += 1;
                let spend = PendingSpend {
                    id: U64(id),
                    receiver_id,
                    amount,
                    memo,
                    reason,
                    requested_at: U64(env::block_timestamp()),
                };
                emit("spend_pending", json!(spend));
                self.pending.insert(id, spend);
                SpendOutcome::Pending { id: U64(id), reason }
            }
        }
    }

    /// Card: pay a pending spend. Approved spends do not count against the agent's daily budget.
    pub fn approve(&mut self, id: U64) {
        self.assert_signed_by(&self.approver_key, "approver");
        let spend = self.pending.remove(&id.0).unwrap_or_else(|| env::panic_str("no such pending spend"));
        emit("spend_approved", json!({ "id": id, "receiver_id": spend.receiver_id, "amount": spend.amount }));
        self.pay(spend.receiver_id, spend.amount, false);
    }

    /// Card: drop a pending spend.
    pub fn reject(&mut self, id: U64) {
        self.assert_signed_by(&self.approver_key, "approver");
        let spend = self.pending.remove(&id.0).unwrap_or_else(|| env::panic_str("no such pending spend"));
        emit("spend_rejected", json!({ "id": id, "receiver_id": spend.receiver_id, "amount": spend.amount }));
    }

    /// Card: replace the policy.
    pub fn set_policy(&mut self, policy: Policy) {
        self.assert_signed_by(&self.approver_key, "approver");
        emit("policy_changed", json!(policy));
        self.policy = policy;
    }

    /// Undo the daily-budget charge when an agent payment bounced (e.g. receiver does not exist).
    #[private]
    pub fn on_agent_payment(
        &mut self,
        amount: NearToken,
        day: u64,
        #[callback_result] result: Result<(), PromiseError>,
    ) {
        if result.is_err() {
            if day == self.day {
                self.spent_today = self.spent_today.saturating_sub(amount);
            }
            emit("spend_failed", json!({ "amount": amount }));
        }
    }

    pub fn get_policy(&self) -> Policy {
        self.policy.clone()
    }

    pub fn get_pending(&self) -> Vec<PendingSpend> {
        self.pending.values().cloned().collect()
    }

    /// What the agent has spent today and what it has left.
    pub fn get_budget(&self) -> Budget {
        let spent = if self.day == today() { self.spent_today } else { NearToken::from_yoctonear(0) };
        Budget { spent_today: spent, remaining_today: self.policy.daily_max.saturating_sub(spent) }
    }

    pub fn get_keys(&self) -> Keys {
        Keys { approver_key: self.approver_key.clone(), agent_key: self.agent_key.clone() }
    }
}

impl SpendPolicy {
    fn assert_signed_by(&self, key: &PublicKey, role: &str) {
        // Both keys live on this account, so calls must come straight from it.
        require!(
            env::predecessor_account_id() == env::current_account_id(),
            "must be called by this account"
        );
        if env::signer_account_pk() != *key {
            env::panic_str(&format!("only the {role} key may call this"));
        }
    }

    fn roll_day(&mut self) {
        let now = today();
        if now != self.day {
            self.day = now;
            self.spent_today = NearToken::from_yoctonear(0);
        }
    }

    fn pay(&self, receiver_id: AccountId, amount: NearToken, charged: bool) {
        let transfer = Promise::new(receiver_id).transfer(amount);
        if charged {
            transfer
                .then(
                    Self::ext(env::current_account_id())
                        .with_static_gas(CALLBACK_GAS)
                        .on_agent_payment(amount, self.day),
                )
                .detach();
        } else {
            transfer.detach();
        }
    }
}

fn today() -> u64 {
    env::block_timestamp() / NANOS_PER_DAY
}

/// NEP-297 event, so the approval app can follow the account's logs.
fn emit(event: &str, data: near_sdk::serde_json::Value) {
    env::log_str(&format!(
        "EVENT_JSON:{}",
        json!({ "standard": "spend_policy", "version": "1.0.0", "event": event, "data": [data] })
    ));
}

#[cfg(test)]
mod tests;
