use super::*;
use near_sdk::test_utils::{get_logs, VMContextBuilder};
use near_sdk::testing_env;

const HUB: &str = "hub.testnet";
const OWNER: &str = "owner.testnet";
const ALICE: &str = "alice.testnet";
const BOB: &str = "bob.testnet";

const ALICE_FULL: &str = "ed25519:DiTkcni3wzyyhNHg2LG3wXma7Q7Fcswyzvk5Uss81J9Q";
const ALICE_AGENT: &str = "ed25519:6k3USpxxT68Tv22Bt3CQSTda7J9nLr7xYwpwg9BU4NMC";
const ALICE_APPROVER: &str =
    "secp256k1:5aTf8UKWZ9KEQT7gmWPsEvcqsjHAvvaAawQ2E2LTNMBM1tc16doJEacBYfME9XbY4EssC9tfigcFiUeh85VoLD4f";

const BOB_FULL: &str = "ed25519:9n2PYqJX6UBXorh6hQmHWcjkoBAeN31phrxxwGkVXYaj";
const BOB_AGENT: &str =
    "secp256k1:TujYPm5QoENiFkXvdR1JueQZDA48SevaXSELh7XrYhBYGSRjGriqypHN1j8SAvzxp2Y1KY6V9QuFpFPRVx2ycrd";
const BOB_APPROVER: &str =
    "secp256k1:5Xgb4XNggExBmiUX5d4EBuKUNPfBTc79UNbgHD68NtvDvRSjKvE9GSvBs4LRgreNwZob8JfWaqraEhzcfzd2hp8K";

const OWNER_KEY: &str = "ed25519:6E8sCci9badyRkXb3JoRpBj5p8C6Tw41ELDZoiihKEtp";

fn near(n: u128) -> NearToken {
    NearToken::from_near(n)
}

fn milli(n: u128) -> NearToken {
    NearToken::from_millinear(n)
}

fn context(predecessor: &str, signer_key: &str, deposit: NearToken) {
    testing_env!(VMContextBuilder::new()
        .current_account_id(HUB.parse().unwrap())
        .predecessor_account_id(predecessor.parse().unwrap())
        .signer_account_id(predecessor.parse().unwrap())
        .signer_account_pk(signer_key.parse().unwrap())
        .block_timestamp(10 * NANOS_PER_DAY + 1)
        .account_balance(near(100))
        .attached_deposit(deposit)
        .build());
}

fn policy(per_tx: NearToken, daily: NearToken, allow: &[&str]) -> Policy {
    Policy {
        per_tx_max: per_tx,
        daily_max: daily,
        allowlist: allow.iter().map(|a| a.parse().unwrap()).collect(),
    }
}

fn new_hub() -> PolicyHub {
    context(OWNER, OWNER_KEY, NearToken::from_yoctonear(0));
    PolicyHub::new(OWNER.parse().unwrap(), milli(10))
}

fn register(hub: &mut PolicyHub, user: &str, full_key: &str, approver: &str, agent: &str, p: Policy) {
    context(user, full_key, milli(10));
    hub.register(approver.parse().unwrap(), agent.parse().unwrap(), p);
}

fn register_alice(hub: &mut PolicyHub) {
    register(
        hub,
        ALICE,
        ALICE_FULL,
        ALICE_APPROVER,
        ALICE_AGENT,
        policy(milli(500), near(1), &["testnet"]),
    );
}

fn deposit(hub: &mut PolicyHub, user: &str, full_key: &str, amount: NearToken) {
    context(user, full_key, amount);
    hub.deposit();
}

fn agent_spend(hub: &mut PolicyHub, user: &str, agent_key: &str, to: &str, amount: NearToken) -> SpendOutcome {
    context(user, agent_key, NearToken::from_yoctonear(0));
    hub.request_spend(to.parse().unwrap(), amount, "invoice".into())
}

fn approve(hub: &mut PolicyHub, user: &str, approver_key: &str, id: u64) {
    context(user, approver_key, NearToken::from_yoctonear(0));
    hub.approve(U64(id));
}

fn reject(hub: &mut PolicyHub, user: &str, approver_key: &str, id: u64) {
    context(user, approver_key, NearToken::from_yoctonear(0));
    hub.reject(U64(id));
}

#[test]
fn registers_and_deposits() {
    let mut hub = new_hub();
    register_alice(&mut hub);

    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.balance, NearToken::from_yoctonear(0));
    assert_eq!(user.pending_count, 0);
    assert_eq!(hub.get_stats().users, 1);
    assert_eq!(hub.get_stats().fees_collected, milli(10));

    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, near(1));
}

#[test]
fn registration_excess_credits_balance() {
    let mut hub = new_hub();
    context(ALICE, ALICE_FULL, milli(20));
    hub.register(
        ALICE_APPROVER.parse().unwrap(),
        ALICE_AGENT.parse().unwrap(),
        policy(milli(500), near(1), &[]),
    );
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, milli(10));
    assert_eq!(hub.get_stats().fees_collected, milli(10));
}

#[test]
fn pays_within_policy() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100)),
        SpendOutcome::Paid
    );
    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.balance, milli(900));
    assert_eq!(user.budget.spent_today, milli(100));
    assert!(get_logs()[0].contains("\"event\":\"spend_paid\""));
}

#[test]
fn holds_over_tx_limit() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600)),
        SpendOutcome::Pending { id: U64(0), reason: HoldReason::OverTxLimit }
    );
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, near(1));
    assert_eq!(hub.get_pending(ALICE.parse().unwrap()).len(), 1);
}

#[test]
fn holds_over_daily_limit() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(2));

    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(500)),
        SpendOutcome::Paid
    );
    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(500)),
        SpendOutcome::Paid
    );
    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(1)),
        SpendOutcome::Pending { id: U64(0), reason: HoldReason::OverDailyLimit }
    );
}

#[test]
fn holds_not_allowlisted() {
    let mut hub = new_hub();
    register(
        &mut hub,
        ALICE,
        ALICE_FULL,
        ALICE_APPROVER,
        ALICE_AGENT,
        policy(milli(500), near(1), &["vendor.testnet"]),
    );
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "scam.testnet", milli(100)),
        SpendOutcome::Pending { id: U64(0), reason: HoldReason::NotAllowlisted }
    );
}

#[test]
fn holds_insufficient_funds() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, milli(50));

    assert_eq!(
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100)),
        SpendOutcome::Pending { id: U64(0), reason: HoldReason::InsufficientFunds }
    );
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, milli(50));
}

#[test]
fn approver_pays_pending_without_charging_budget() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100));
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600));
    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.budget.spent_today, milli(100));

    approve(&mut hub, ALICE, ALICE_APPROVER, 0);
    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.balance, NearToken::from_yoctonear(300_000_000_000_000_000_000_000));
    assert_eq!(user.budget.spent_today, milli(100));
    assert_eq!(user.pending_count, 0);
    assert!(get_logs()[0].contains("spend_approved"));
}

#[test]
fn approver_rejects_pending() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600));
    reject(&mut hub, ALICE, ALICE_APPROVER, 0);

    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.balance, near(1));
    assert_eq!(user.pending_count, 0);
    assert!(get_logs()[0].contains("spend_rejected"));
}

#[test]
#[should_panic(expected = "only the approver key may call this")]
fn agent_cannot_approve() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600));
    approve(&mut hub, ALICE, ALICE_AGENT, 0);
}

#[test]
#[should_panic(expected = "only the agent key may call this")]
fn approver_cannot_request_spend() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    agent_spend(&mut hub, ALICE, ALICE_APPROVER, "testnet", milli(100));
}

#[test]
fn users_are_isolated() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    register(
        &mut hub,
        BOB,
        BOB_FULL,
        BOB_APPROVER,
        BOB_AGENT,
        policy(milli(500), near(1), &["testnet"]),
    );
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    deposit(&mut hub, BOB, BOB_FULL, near(1));

    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100));
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, milli(900));
    assert_eq!(hub.get_user(BOB.parse().unwrap()).balance, near(1));

    // Bob's agent key cannot spend as Alice.
    context(ALICE, BOB_AGENT, NearToken::from_yoctonear(0));
    let err = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        hub.request_spend("testnet".parse().unwrap(), milli(100), "x".into());
    }));
    assert!(err.is_err());
}

#[test]
#[should_panic(expected = "already registered")]
fn cannot_register_twice() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    register_alice(&mut hub);
}

#[test]
#[should_panic(expected = "registration fee required")]
fn registration_fee_is_required() {
    let mut hub = new_hub();
    context(ALICE, ALICE_FULL, NearToken::from_yoctonear(0));
    hub.register(
        ALICE_APPROVER.parse().unwrap(),
        ALICE_AGENT.parse().unwrap(),
        policy(milli(500), near(1), &[]),
    );
}

#[test]
#[should_panic(expected = "per-payment cap exceeds daily budget")]
fn rejects_bad_policy() {
    let mut hub = new_hub();
    register(
        &mut hub,
        ALICE,
        ALICE_FULL,
        ALICE_APPROVER,
        ALICE_AGENT,
        policy(near(2), near(1), &[]),
    );
}

#[test]
#[should_panic(expected = "too many pending spends")]
fn pending_queue_is_bounded() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(100));
    for _ in 0..=MAX_PENDING {
        agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600));
    }
}

#[test]
fn agent_payment_callback_refunds() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100));

    hub.on_agent_payment(ALICE.parse().unwrap(), milli(100), 10, Err(PromiseError::Failed));

    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.balance, near(1));
    assert_eq!(user.budget.spent_today, NearToken::from_yoctonear(0));
}

#[test]
fn approved_payment_callback_reinserts_pending() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600));

    let spend = hub.get_pending(ALICE.parse().unwrap()).remove(0);
    approve(&mut hub, ALICE, ALICE_APPROVER, 0);
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, milli(400));

    hub.on_approved_payment(ALICE.parse().unwrap(), spend, Err(PromiseError::Failed));

    let user = hub.get_user(ALICE.parse().unwrap());
    assert_eq!(user.balance, near(1));
    assert_eq!(user.pending_count, 1);
}

#[test]
fn withdraw_and_unregister() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.withdraw(milli(400));
    assert_eq!(hub.get_user(ALICE.parse().unwrap()).balance, milli(600));

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.unregister();
    assert_eq!(hub.get_stats().users, 0);
}

#[test]
#[should_panic(expected = "pending spends exist")]
fn cannot_unregister_with_pending() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(600));

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.unregister();
}

#[test]
fn owner_can_withdraw_fees_only() {
    let mut hub = new_hub();
    register_alice(&mut hub);

    context(OWNER, OWNER_KEY, NearToken::from_yoctonear(0));
    hub.withdraw_fees(milli(10), OWNER.parse().unwrap());
    assert_eq!(hub.get_stats().fees_collected, NearToken::from_yoctonear(0));
}

#[test]
#[should_panic(expected = "owner only")]
fn user_cannot_withdraw_fees() {
    let mut hub = new_hub();
    register_alice(&mut hub);

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.withdraw_fees(milli(10), ALICE.parse().unwrap());
}

#[test]
#[should_panic(expected = "contract paused")]
fn owner_can_pause_everyone() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    context(OWNER, OWNER_KEY, NearToken::from_yoctonear(0));
    hub.pause_all();
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100));
}

#[test]
#[should_panic(expected = "user paused")]
fn approver_can_pause_one_user() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.pause();
    agent_spend(&mut hub, ALICE, ALICE_AGENT, "testnet", milli(100));
}

#[test]
fn approver_can_change_policy_and_agent_key() {
    let mut hub = new_hub();
    register_alice(&mut hub);
    deposit(&mut hub, ALICE, ALICE_FULL, near(1));

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.set_policy(policy(milli(100), milli(200), &["vendor.testnet"]));
    assert_eq!(hub.get_policy(ALICE.parse().unwrap()).per_tx_max, milli(100));

    context(ALICE, ALICE_APPROVER, NearToken::from_yoctonear(0));
    hub.set_agent_key(BOB_AGENT.parse().unwrap());
    assert_eq!(hub.get_keys(ALICE.parse().unwrap()).agent_key, BOB_AGENT.parse().unwrap());

    agent_spend(&mut hub, ALICE, BOB_AGENT, "vendor.testnet", milli(50));
}
