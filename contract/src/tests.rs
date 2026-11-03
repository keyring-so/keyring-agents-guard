use super::*;
use near_sdk::test_utils::{get_logs, VMContextBuilder};
use near_sdk::testing_env;

const CARD: &str = "secp256k1:65KT5jcD7UdnLxpvKho2s2NtVbNCd6hPmLbgu74GZxoxnj4FbY7rAKjpCq1euZeuVWgebGhgZ5ytjcSDzhybs9yn";
const AGENT: &str = "ed25519:6E8sCci9badyRkXb3JoRpBj5p8C6Tw41ELDZoiihKEtp";
const OWNER: &str = "alice.testnet";

fn near(n: u128) -> NearToken {
    NearToken::from_near(n)
}

fn milli(n: u128) -> NearToken {
    NearToken::from_millinear(n)
}

fn context(signer_key: &str, predecessor: &str, day: u64) {
    testing_env!(VMContextBuilder::new()
        .current_account_id(OWNER.parse().unwrap())
        .signer_account_id(OWNER.parse().unwrap())
        .predecessor_account_id(predecessor.parse().unwrap())
        .signer_account_pk(signer_key.parse().unwrap())
        .block_timestamp(day * NANOS_PER_DAY + 1)
        .account_balance(near(100))
        .build());
}

fn as_agent() {
    context(AGENT, OWNER, 10);
}

fn as_card() {
    context(CARD, OWNER, 10);
}

fn contract(allowlist: Vec<&str>) -> SpendPolicy {
    as_card();
    SpendPolicy::new(
        CARD.parse().unwrap(),
        AGENT.parse().unwrap(),
        Policy {
            per_tx_max: near(1),
            daily_max: near(3),
            allowlist: allowlist.into_iter().map(|a| a.parse().unwrap()).collect(),
        },
    )
}

fn spend(c: &mut SpendPolicy, to: &str, amount: NearToken) -> SpendOutcome {
    c.request_spend(to.parse().unwrap(), amount, "invoice".into())
}

#[test]
fn pays_within_policy() {
    let mut c = contract(vec![]);
    as_agent();
    assert_eq!(spend(&mut c, "figma.testnet", milli(500)), SpendOutcome::Paid);
    assert_eq!(c.get_budget().spent_today, milli(500));
    assert!(get_logs()[0].contains("\"event\":\"spend_paid\""));
}

#[test]
fn holds_over_tx_limit() {
    let mut c = contract(vec![]);
    as_agent();
    let out = spend(&mut c, "figma.testnet", near(2));
    assert_eq!(out, SpendOutcome::Pending { id: U64(0), reason: HoldReason::OverTxLimit });
    assert_eq!(c.get_pending().len(), 1);
    assert_eq!(c.get_budget().spent_today, near(0), "held spends are not charged");
}

#[test]
fn holds_over_daily_limit_and_resets_next_day() {
    let mut c = contract(vec![]);
    as_agent();
    for _ in 0..3 {
        assert_eq!(spend(&mut c, "figma.testnet", near(1)), SpendOutcome::Paid);
    }
    let out = spend(&mut c, "figma.testnet", milli(1));
    assert_eq!(out, SpendOutcome::Pending { id: U64(0), reason: HoldReason::OverDailyLimit });

    context(AGENT, OWNER, 11);
    assert_eq!(spend(&mut c, "figma.testnet", near(1)), SpendOutcome::Paid);
    assert_eq!(c.get_budget().spent_today, near(1));
}

#[test]
fn holds_receiver_not_on_allowlist() {
    let mut c = contract(vec!["figma.testnet"]);
    as_agent();
    assert_eq!(spend(&mut c, "figma.testnet", milli(100)), SpendOutcome::Paid);
    let out = spend(&mut c, "0xscam.testnet", milli(100));
    assert_eq!(out, SpendOutcome::Pending { id: U64(0), reason: HoldReason::NotAllowlisted });
}

#[test]
fn card_approves_and_rejects() {
    let mut c = contract(vec![]);
    as_agent();
    spend(&mut c, "vendor.testnet", near(5));
    spend(&mut c, "0xscam.testnet", near(50));

    as_card();
    c.approve(U64(0));
    c.reject(U64(1));
    assert!(c.get_pending().is_empty());
    assert_eq!(c.get_budget().spent_today, near(0), "approved spends are not charged");
    let logs = get_logs();
    assert!(logs[0].contains("spend_approved") && logs[1].contains("spend_rejected"));
}

#[test]
#[should_panic(expected = "only the approver key may call this")]
fn agent_cannot_approve() {
    let mut c = contract(vec![]);
    as_agent();
    spend(&mut c, "0xscam.testnet", near(50));
    c.approve(U64(0));
}

#[test]
#[should_panic(expected = "only the approver key may call this")]
fn agent_cannot_change_policy() {
    let mut c = contract(vec![]);
    as_agent();
    c.set_policy(Policy { per_tx_max: near(1000), daily_max: near(1000), allowlist: vec![] });
}

#[test]
#[should_panic(expected = "only the agent key may call this")]
fn only_agent_key_requests_spends() {
    let mut c = contract(vec![]);
    as_card();
    spend(&mut c, "figma.testnet", milli(1));
}

#[test]
#[should_panic(expected = "must be called by this account")]
fn rejects_cross_contract_calls() {
    let mut c = contract(vec![]);
    context(AGENT, "evil.testnet", 10);
    spend(&mut c, "figma.testnet", milli(1));
}

#[test]
#[should_panic(expected = "too many pending spends")]
fn pending_queue_is_bounded() {
    let mut c = contract(vec![]);
    as_agent();
    for _ in 0..=MAX_PENDING {
        spend(&mut c, "0xscam.testnet", near(50));
    }
}

#[test]
fn bounced_payment_is_refunded_to_budget() {
    let mut c = contract(vec![]);
    as_agent();
    spend(&mut c, "nobody.testnet", near(1));
    c.on_agent_payment(near(1), 10, Err(PromiseError::Failed));
    assert_eq!(c.get_budget().spent_today, near(0));
}
