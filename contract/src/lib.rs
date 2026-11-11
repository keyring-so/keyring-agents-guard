//! Shared spending-policy hub.
//!
//! One contract serves many users. Each user registers with their own approver and agent keys and
//! keeps a per-user policy, pending queue, and balance. Funds are pooled in this contract and
//! accounted per user; the agent spends from the user's balance, never from another user's.
//!
//! Keys stay on the user's own NEAR account as function-call keys scoped to this contract:
//! - agent key: `request_spend` only
//! - approver key: `approve`, `reject`, `set_policy`, `set_agent_key`, `pause`, `unpause`,
//!   `withdraw`, `unregister`
//!
//! The contract checks the signer key as a second layer behind NEAR's key permissions. It cannot
//! verify that a key is full-access; the account's key permissions do that.
//!
//! Custody note: the contract holds every user's funds. The owner can withdraw only registration
//! fees, never user balances, but the owner can still upgrade the code. For production, deploy the
//! code immutably (global contract by hash) or behind a timelock.

use near_sdk::json_types::U64;
use near_sdk::serde_json::json;
use near_sdk::store::IterableMap;
use near_sdk::{
    env, near, require, AccountId, Gas, NearToken, PanicOnDefault, Promise, PromiseError, PublicKey,
};

const NANOS_PER_DAY: u64 = 86_400 * 1_000_000_000;
const MAX_PENDING: u32 = 32;
const MAX_ALLOWLIST: usize = 32;
const MAX_MEMO_LEN: usize = 256;
const CALLBACK_GAS: Gas = Gas::from_tgas(10);

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
    InsufficientFunds,
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

#[near(serializers = [json])]
#[derive(Debug, PartialEq)]
pub struct UserView {
    pub account: AccountId,
    pub policy: Policy,
    pub budget: Budget,
    pub balance: NearToken,
    pub keys: Keys,
    pub pending_count: u32,
    pub paused: bool,
    pub registered_at: U64,
}

#[near(serializers = [json])]
#[derive(Debug, PartialEq)]
pub struct Stats {
    pub owner: AccountId,
    pub users: u32,
    pub fees_collected: NearToken,
    pub registration_fee: NearToken,
    pub paused: bool,
}

#[near(serializers = [borsh])]
pub struct UserState {
    approver_key: PublicKey,
    agent_key: PublicKey,
    policy: Policy,
    day: u64,
    spent_today: NearToken,
    balance: NearToken,
    next_id: u64,
    pending: IterableMap<u64, PendingSpend>,
    registered_at: u64,
    paused: bool,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct PolicyHub {
    owner: AccountId,
    registration_fee: NearToken,
    fees_collected: NearToken,
    paused: bool,
    users: IterableMap<AccountId, UserState>,
}

#[near]
impl PolicyHub {
    #[init]
    pub fn new(owner: AccountId, registration_fee: NearToken) -> Self {
        Self {
            owner,
            registration_fee,
            fees_collected: NearToken::from_yoctonear(0),
            paused: false,
            users: IterableMap::new(b"u"),
        }
    }

    /// Register the calling account. The attached deposit must cover the registration fee; any
    /// excess becomes the user's starting balance.
    #[payable]
    pub fn register(&mut self, approver_key: PublicKey, agent_key: PublicKey, policy: Policy) {
        assert_direct();
        let user = env::predecessor_account_id();
        require!(user != env::current_account_id(), "the contract cannot register itself");
        require!(self.users.get(&user).is_none(), "already registered");
        require!(approver_key != agent_key, "approver and agent keys must differ");
        validate_policy(&policy);

        let fee = self.registration_fee;
        let deposit = env::attached_deposit();
        require!(deposit >= fee, "registration fee required");
        let excess = deposit.saturating_sub(fee);
        self.fees_collected = self.fees_collected.saturating_add(fee);

        let state = UserState {
            approver_key,
            agent_key,
            policy,
            day: today(),
            spent_today: NearToken::from_yoctonear(0),
            balance: excess,
            next_id: 0,
            pending: IterableMap::new(pending_prefix(&user)),
            registered_at: env::block_timestamp(),
            paused: false,
        };
        self.users.insert(user.clone(), state);
        emit(
            "user_registered",
            json!({ "account": &user, "fee": fee, "balance": excess }),
        );
    }

    /// Add funds to the calling user's balance.
    #[payable]
    pub fn deposit(&mut self) {
        assert_direct();
        let user = env::predecessor_account_id();
        let amount = env::attached_deposit();
        require!(!amount.is_zero(), "deposit must be positive");

        let state = self.users.get_mut(&user).expect("not registered");
        state.balance = state.balance.saturating_add(amount);
        emit(
            "deposit",
            json!({ "account": &user, "amount": amount, "balance": state.balance }),
        );
    }

    /// Withdraw part of the user's balance to the user's own account. Approver only.
    pub fn withdraw(&mut self, amount: NearToken) {
        assert_direct();
        let user = env::predecessor_account_id();
        require!(!amount.is_zero(), "amount must be positive");

        {
            let state = self.users.get_mut(&user).expect("not registered");
            assert_approver(&state);
            require!(state.balance >= amount, "insufficient balance");
            state.balance = state.balance.saturating_sub(amount);
        }

        emit("withdrawn", json!({ "account": &user, "amount": amount }));
        Promise::new(user).transfer(amount).detach();
    }

    /// Agent: pay `amount` to `receiver_id`, or park it for the approver if it breaks the policy.
    pub fn request_spend(
        &mut self,
        receiver_id: AccountId,
        amount: NearToken,
        memo: String,
    ) -> SpendOutcome {
        assert_direct();
        let user = env::predecessor_account_id();
        require!(!self.paused, "contract paused");
        require!(!amount.is_zero(), "amount must be positive");
        require!(memo.len() <= MAX_MEMO_LEN, "memo too long");

        let mut paid_day: Option<u64> = None;
        let mut pending_outcome: Option<(u64, HoldReason)> = None;

        {
            let state = self.users.get_mut(&user).expect("not registered");
            assert_agent(&state);
            require!(!state.paused, "user paused");
            roll_day(&mut *state);

            let reason = if amount > state.policy.per_tx_max {
                Some(HoldReason::OverTxLimit)
            } else if state.spent_today.saturating_add(amount) > state.policy.daily_max {
                Some(HoldReason::OverDailyLimit)
            } else if !state.policy.allowlist.is_empty()
                && !state.policy.allowlist.contains(&receiver_id)
            {
                Some(HoldReason::NotAllowlisted)
            } else if state.balance < amount {
                Some(HoldReason::InsufficientFunds)
            } else {
                None
            };

            match reason {
                None => {
                    state.spent_today = state.spent_today.saturating_add(amount);
                    state.balance = state.balance.saturating_sub(amount);
                    paid_day = Some(state.day);
                }
                Some(reason) => {
                    require!(state.pending.len() < MAX_PENDING, "too many pending spends");
                    let id = state.next_id;
                    state.next_id += 1;
                    let spend = PendingSpend {
                        id: U64(id),
                        receiver_id: receiver_id.clone(),
                        amount,
                        memo: memo.clone(),
                        reason,
                        requested_at: U64(env::block_timestamp()),
                    };
                    emit(
                        "spend_pending",
                        json!({ "account": &user, "spend": &spend }),
                    );
                    state.pending.insert(id, spend);
                    pending_outcome = Some((id, reason));
                }
            }
        }

        if let Some(day) = paid_day {
            emit(
                "spend_paid",
                json!({
                    "account": &user,
                    "receiver_id": &receiver_id,
                    "amount": amount,
                    "memo": &memo,
                    "by": "agent",
                }),
            );
            self.pay_agent(user, receiver_id, amount, day);
            SpendOutcome::Paid
        } else {
            let (id, reason) = pending_outcome.expect("pending outcome missing");
            SpendOutcome::Pending {
                id: U64(id),
                reason,
            }
        }
    }

    /// Approver: pay a pending spend. Approved spends do not count against the daily budget.
    pub fn approve(&mut self, id: U64) {
        assert_direct();
        let user = env::predecessor_account_id();

        let spend = {
            let state = self.users.get_mut(&user).expect("not registered");
            assert_approver(&state);
            let spend = state
                .pending
                .remove(&id.0)
                .unwrap_or_else(|| env::panic_str("no such pending spend"));
            require!(state.balance >= spend.amount, "insufficient balance");
            state.balance = state.balance.saturating_sub(spend.amount);
            spend
        };

        emit(
            "spend_approved",
            json!({ "account": &user, "spend": &spend }),
        );
        self.pay_approved(user, spend);
    }

    /// Approver: drop a pending spend.
    pub fn reject(&mut self, id: U64) {
        assert_direct();
        let user = env::predecessor_account_id();

        let spend = {
            let state = self.users.get_mut(&user).expect("not registered");
            assert_approver(&state);
            state
                .pending
                .remove(&id.0)
                .unwrap_or_else(|| env::panic_str("no such pending spend"))
        };

        emit(
            "spend_rejected",
            json!({ "account": &user, "spend": &spend }),
        );
    }

    /// Approver: replace this user's policy.
    pub fn set_policy(&mut self, policy: Policy) {
        assert_direct();
        let user = env::predecessor_account_id();
        validate_policy(&policy);

        let state = self.users.get_mut(&user).expect("not registered");
        assert_approver(&state);
        state.policy = policy;
        emit(
            "policy_changed",
            json!({ "account": &user, "policy": &state.policy }),
        );
    }

    /// Approver: rotate the agent key.
    pub fn set_agent_key(&mut self, agent_key: PublicKey) {
        assert_direct();
        let user = env::predecessor_account_id();

        let state = self.users.get_mut(&user).expect("not registered");
        assert_approver(&state);
        require!(agent_key != state.approver_key, "agent key must differ from approver key");
        state.agent_key = agent_key;
        emit(
            "agent_key_changed",
            json!({ "account": &user, "agent_key": &state.agent_key }),
        );
    }

    /// Approver: stop the agent from spending for this user.
    pub fn pause(&mut self) {
        assert_direct();
        let user = env::predecessor_account_id();
        let state = self.users.get_mut(&user).expect("not registered");
        assert_approver(&state);
        state.paused = true;
        emit("paused", json!({ "account": &user }));
    }

    /// Approver: let the agent spend again.
    pub fn unpause(&mut self) {
        assert_direct();
        let user = env::predecessor_account_id();
        let state = self.users.get_mut(&user).expect("not registered");
        assert_approver(&state);
        state.paused = false;
        emit("unpaused", json!({ "account": &user }));
    }

    /// Approver: remove this user. The balance is refunded; the registration fee is not.
    pub fn unregister(&mut self) {
        assert_direct();
        let user = env::predecessor_account_id();

        let balance = {
            let state = self.users.get_mut(&user).expect("not registered");
            assert_approver(&state);
            require!(state.pending.is_empty(), "pending spends exist");
            state.pending.clear();
            state.balance
        };

        self.users.remove(&user);
        emit(
            "user_unregistered",
            json!({ "account": &user, "refund": balance }),
        );
        if !balance.is_zero() {
            Promise::new(user).transfer(balance).detach();
        }
    }

    /// Owner: withdraw collected registration fees only.
    pub fn withdraw_fees(&mut self, amount: NearToken, to: AccountId) {
        assert_direct();
        let owner = env::predecessor_account_id();
        require!(owner == self.owner, "owner only");
        require!(!amount.is_zero(), "amount must be positive");
        require!(self.fees_collected >= amount, "insufficient fees");

        self.fees_collected = self.fees_collected.saturating_sub(amount);
        emit("fees_withdrawn", json!({ "amount": amount, "to": &to }));
        Promise::new(to).transfer(amount).detach();
    }

    /// Owner: pause every user.
    pub fn pause_all(&mut self) {
        assert_direct();
        require!(env::predecessor_account_id() == self.owner, "owner only");
        self.paused = true;
        emit("contract_paused", json!({}));
    }

    /// Owner: resume every user.
    pub fn unpause_all(&mut self) {
        assert_direct();
        require!(env::predecessor_account_id() == self.owner, "owner only");
        self.paused = false;
        emit("contract_unpaused", json!({}));
    }

    // Views -----------------------------------------------------------------------------------

    pub fn get_user(&self, account: AccountId) -> UserView {
        let state = self
            .users
            .get(&account)
            .unwrap_or_else(|| env::panic_str("not registered"));
        let spent = if state.day == today() {
            state.spent_today
        } else {
            NearToken::from_yoctonear(0)
        };
        UserView {
            account,
            policy: state.policy.clone(),
            budget: Budget {
                spent_today: spent,
                remaining_today: state.policy.daily_max.saturating_sub(spent),
            },
            balance: state.balance,
            keys: Keys {
                approver_key: state.approver_key.clone(),
                agent_key: state.agent_key.clone(),
            },
            pending_count: state.pending.len(),
            paused: state.paused,
            registered_at: U64(state.registered_at),
        }
    }

    pub fn get_pending(&self, account: AccountId) -> Vec<PendingSpend> {
        self.users
            .get(&account)
            .map(|state| state.pending.values().cloned().collect())
            .unwrap_or_default()
    }

    pub fn get_pending_by_id(&self, account: AccountId, id: U64) -> Option<PendingSpend> {
        self.users
            .get(&account)
            .and_then(|state| state.pending.get(&id.0).cloned())
    }

    pub fn get_policy(&self, account: AccountId) -> Policy {
        self.users
            .get(&account)
            .expect("not registered")
            .policy
            .clone()
    }

    pub fn get_keys(&self, account: AccountId) -> Keys {
        let state = self.users.get(&account).expect("not registered");
        Keys {
            approver_key: state.approver_key.clone(),
            agent_key: state.agent_key.clone(),
        }
    }

    pub fn get_stats(&self) -> Stats {
        Stats {
            owner: self.owner.clone(),
            users: self.users.len(),
            fees_collected: self.fees_collected,
            registration_fee: self.registration_fee,
            paused: self.paused,
        }
    }

    pub fn get_owner(&self) -> AccountId {
        self.owner.clone()
    }

    // Callbacks -------------------------------------------------------------------------------

    /// Refund the user's budget and balance if an agent payment bounced.
    #[private]
    pub fn on_agent_payment(
        &mut self,
        user: AccountId,
        amount: NearToken,
        day: u64,
        #[callback_result] result: Result<(), PromiseError>,
    ) {
        if result.is_err() {
            if let Some(state) = self.users.get_mut(&user) {
                if day == state.day {
                    state.spent_today = state.spent_today.saturating_sub(amount);
                }
                state.balance = state.balance.saturating_add(amount);
                emit(
                    "spend_failed",
                    json!({ "account": &user, "amount": amount, "kind": "agent" }),
                );
            }
        }
    }

    /// Put an approved spend back in the queue if its payment bounced.
    #[private]
    pub fn on_approved_payment(
        &mut self,
        user: AccountId,
        spend: PendingSpend,
        #[callback_result] result: Result<(), PromiseError>,
    ) {
        if result.is_err() {
            if let Some(state) = self.users.get_mut(&user) {
                state.balance = state.balance.saturating_add(spend.amount);
                let id = spend.id.0;
                emit(
                    "spend_failed",
                    json!({ "account": &user, "spend": &spend, "kind": "approved" }),
                );
                state.pending.insert(id, spend);
            }
        }
    }
}

impl PolicyHub {
    fn pay_agent(&self, user: AccountId, receiver_id: AccountId, amount: NearToken, day: u64) {
        Promise::new(receiver_id)
            .transfer(amount)
            .then(
                Self::ext(env::current_account_id())
                    .with_static_gas(CALLBACK_GAS)
                    .on_agent_payment(user, amount, day),
            )
            .detach();
    }

    fn pay_approved(&self, user: AccountId, spend: PendingSpend) {
        let receiver_id = spend.receiver_id.clone();
        let amount = spend.amount;
        Promise::new(receiver_id)
            .transfer(amount)
            .then(
                Self::ext(env::current_account_id())
                    .with_static_gas(CALLBACK_GAS)
                    .on_approved_payment(user, spend),
            )
            .detach();
    }
}

fn assert_direct() {
    require!(
        env::predecessor_account_id() == env::signer_account_id(),
        "must be called by the account"
    );
}

fn assert_agent(state: &UserState) {
    require!(
        env::signer_account_pk() == state.agent_key,
        "only the agent key may call this"
    );
}

fn assert_approver(state: &UserState) {
    require!(
        env::signer_account_pk() == state.approver_key,
        "only the approver key may call this"
    );
}

fn validate_policy(policy: &Policy) {
    require!(
        policy.per_tx_max <= policy.daily_max,
        "per-payment cap exceeds daily budget"
    );
    require!(
        policy.allowlist.len() <= MAX_ALLOWLIST,
        "allowlist too long"
    );
}

fn roll_day(state: &mut UserState) {
    let now = today();
    if now != state.day {
        state.day = now;
        state.spent_today = NearToken::from_yoctonear(0);
    }
}

fn today() -> u64 {
    env::block_timestamp() / NANOS_PER_DAY
}

fn pending_prefix(user: &AccountId) -> Vec<u8> {
    let mut prefix = b"p/".to_vec();
    prefix.extend_from_slice(user.as_bytes());
    prefix
}

/// NEP-297 event, so the approval app and indexers can follow the hub.
fn emit(event: &str, data: near_sdk::serde_json::Value) {
    env::log_str(&format!(
        "EVENT_JSON:{}",
        json!({ "standard": "spend_policy", "version": "2.0.0", "event": event, "data": [data] })
    ));
}

#[cfg(test)]
mod tests;
