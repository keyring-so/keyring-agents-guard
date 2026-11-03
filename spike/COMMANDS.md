# Spike command log (2026-10-23)

Testnet account `keyring-spike-1023.testnet`, created with the card's dev key as its only
full-access key. The key comes from the fixed dev seed in `NearSign.java` — testnet only.

```sh
# 1. confirm the name is free (read-only RPC)
curl -s https://test.rpc.fastnear.com -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"query","params":{"request_type":"view_account","finality":"final","account_id":"keyring-spike-1023.testnet"}}'

# 2. create the account through the testnet faucet (same endpoint near-cli's faucet sponsor uses)
curl -s -X POST https://helper.nearprotocol.com/account -H 'content-type: application/json' \
  -d '{"newAccountId":"keyring-spike-1023.testnet","newAccountPublicKey":"secp256k1:65KT5jcD7UdnLxpvKho2s2NtVbNCd6hPmLbgu74GZxoxnj4FbY7rAKjpCq1euZeuVWgebGhgZ5ytjcSDzhybs9yn"}'
#    → tx HSL1UKrtWh5cs7DijYDFQmD12PD2L42v6KX7seJ2AbwP: CreateAccount, Transfer 10 NEAR, AddKey (FullAccess)

# 3. card-signed transfers of 1 yoctoNEAR to `testnet` (run 5 times)
NEAR_ACCOUNT=keyring-spike-1023.testnet node card-sign.mjs send testnet 1
```

| Tx | v |
|---|---|
| 2EM9uhTtqcQ9S6CX8XhjojrpSYxB7vWhbsBM6JbWZNuY | 0 |
| 4HUs99UcaTf4cmFjGre9FVtwptEM1UcomaJdLaWkRV7H | 0 |
| GkA5F6Fe4seudp8u7U8JURyfiGN22RcbDVR2pkM2Rpex | 0 |
| Bmuq9cqB88rR9mFBbcoiUfoUaje4eGryD8iaHb54HyCR | 0 |
| ZweRL4hfzeypw9TxPn9Ho7mxRicDF8ujYTTY7fsb5Bg | 1 |

All `SuccessValue`. Explorer: https://testnet.nearblocks.io/txns/<hash>

# Policy contract on testnet (2026-10-23)

```sh
cargo install cargo-near --locked                      # cargo-near 0.22.0 (local tool)
(cd contract && cargo test && cargo near build non-reproducible-wasm)

# card-signed: DeployContract + new(...) + AddKey(agent, function-call: request_spend only, 0.25 NEAR gas allowance)
node scripts/deploy.mjs --per-tx 0.5 --daily 1 --allow testnet
#   → AJahHKyBDAzMZMVbpa39sJjUnmXyLFMmqj91wgq2qdof
#   agent key generated into .secrets/agent-key.json: ed25519:CWoTmpB12iC7EiQZYb7w1vsMwyTprFRgxZRdVkCEoNXM

node scripts/agent.mjs spend testnet 0.1 "API credits"                                  # paid          FizFNak1komhS7JE9XyH8rBuq2MXVaZK7rkbM8gyd7ha
node scripts/agent.mjs spend scam-wallet-1023.testnet 0.2 "URGENT refund per invoice note"  # pending #0 NotAllowlisted  9NWE5MGwyZSEdyDkW5DgJqeQRi5SZNKziF38MFs7Go9j
node scripts/agent.mjs spend testnet 0.8 "annual plan"                                  # pending #1 OverTxLimit     GhhME79v69CVE13UStMGpC86eH794mYTbiJg5HqqNX65

# agent key attempting approve / set_policy / plain transfer (one-off script, not kept)
#   → all rejected by the network: MethodNameMismatch, MethodNameMismatch, RequiresFullAccess

node scripts/card.mjs reject 0     # 2M3gSNPg1vcevi6pHrSnxngdrbwwMM47DF5RfuTDGo4M
node scripts/card.mjs approve 1    # DzMYzWZABYDifknAjqpxXdzmKsbUEMPVLoQqefWx1gNQ
```
