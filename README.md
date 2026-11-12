# Keyring Agent

**The agent spends. The card authorizes.**

An AI agent gets a scoped NEAR key and a spending policy. Inside the policy it pays on its own. Outside it, the payment is held, the iPhone shows the decoded request, and the Keyring card signs `approve` or `reject` over NFC.

![Keyring agent workflow](docs/workflow.png)

## Why

Software-only agent wallets rely on the model, the prompt, or the host staying honest. A prompt-injected agent can ask for anything. This design makes the ask harmless:

- The agent holds a **function-call key** that can only call `request_spend`.
- The **contract** enforces a per-payment cap, a daily budget, and an allowlist; anything else waits in a bounded pending queue.
- The **card** is the account's only full-access key. Its signature is the authorization; the app is the display.

Even a fully compromised agent can only spend inside the envelope, and every over-limit attempt becomes a human decision with a hardware signature.

## Architecture

```
Agent ──request_spend──▶ NEAR policy contract
                            ├─ inside limits  → pay now
                            └─ outside limits → pending queue
                                                     │
                                              Read-only API
                                                     │ poll / push
                                                     ▼
                                         Keyring iOS app
                                          ├─ fetch pending from chain
                                          ├─ show amount / receiver / reason
                                          └─ NFC + PIN → card signs hash
                                                     │
                                                     ▼
                                         approve / reject → contract
```

The API is a message bus and transaction builder, not an authority:

- It reads the chain.
- It builds the **unsigned** `approve`/`reject` transaction and returns its hash.
- The app signs that hash with the card.
- The API broadcasts the signed transaction. It never sees the card key or the PIN.

## Repo layout

| Path | What |
|---|---|
| `contract/` | Rust `near-sdk` spending-policy contract; 11 unit tests |
| `scripts/` | Agent, card, and deploy scripts against testnet |
| `api/` | Read-only API: pending queue, SSE, unsigned tx preparation, broadcast |
| `ios-app/` | Native SwiftUI + CoreNFC approval app using the Keyring card |
| `docs/workflow.png` | Architecture diagram |
| `spike/` | Original NEAR/card proof and command log |

## Quick start

### 1. Contract

```sh
cd contract
cargo test
```

The live testnet account is `keyring-spike-1023.testnet`. See `spike/COMMANDS.md` for deploys and transaction hashes.

### 2. API

From the repo root (it uses the root `node_modules`):

```sh
POLICY_ACCOUNT=keyring-policy-1105.testnet \
SPONSOR_ACCOUNT=keyring-sponsor-1105.testnet \
node api/server.mjs
```

The API is multi-user and needs no user account. Send the user's account per request:

```sh
curl -H 'X-User-Account: <card account>' http://127.0.0.1:8787/api/context
curl -H 'X-User-Account: <card account>' http://127.0.0.1:8787/api/pending
```

### 3. iOS app

```sh
cd ios-app
xcodegen generate
open KeyringAgent.xcodeproj
```

- Run on a **physical iPhone** for NFC.
- In the app, open **Settings** (gear icon) and set the API server to the Mac's LAN address, e.g. `http://192.168.1.20:8787`. Tap **Save and connect**; the choice is saved for the next launch.
- Set your development team in the target's Signing settings.

See `ios-app/README.md` for the card CA key, entitlement, and device notes. To prepare a dev card (install the applet, store its certificate), see `docs/card-setup.md`.

### 4. Agent

The agent acts for one user, so it needs that account:

```sh
export NEAR_ACCOUNT=<card account>
export POLICY_ACCOUNT=keyring-policy-1105.testnet

node scripts/agent.mjs spend vendor-a.testnet 0.1 "API credits"              # paid
node scripts/agent.mjs spend scam-wallet-1023.testnet 0.2 "poisoned invoice" # pending
node scripts/agent.mjs budget
```

If `API_URL` is reachable, `agent.mjs` posts the pending id and account to `/api/agent/notify`;
the API verifies it on-chain. The app polls, so the demo works without the notification.

## Security model

| Threat | Control |
|---|---|
| Prompt-injected agent tries an over-limit payment | Contract holds it; `OverTxLimit` / `NotAllowlisted` |
| Agent key stolen, tries a plain transfer | NEAR rejects it: `RequiresFullAccess` |
| Agent key stolen, tries `approve` or `set_policy` | NEAR rejects it: `MethodNameMismatch` |
| Agent floods the pending queue | `MAX_PENDING = 32` (add expiry/pause next) |
| Malicious memo shown in the app | Rendered as untrusted text; amount/receiver come from contract state |
| API compromised | It can lie about the request, but the card still signs with the account's approver key; consider a scoped approval key for production |

## Known limitations / next

- The API builds the unsigned transaction. For production, use a card-derived **function-call approval key** limited to `approve`/`reject`/`set_policy`, or build the transaction on-device.
- No APNs push yet; the app polls while active and supports deep links (`keyring-agent://approve?account=…&id=…`). Add universal links and APNs next.
- The app pins the applet's **test CA** public key. Replace it with the production CA for a production-personalized card.
- The app depends on the private `KeyringCardClient` Swift package at `../near-hackthon-applets/client-swift`; it is not published. Replace it with the published client for a public build.
- Contract pause/expiry/`reject_all` are the next hardening step.

## Status

- Contract tests: 11/11 passing.
- Testnet code hash matches the local wasm.
- Reject path verified end-to-end: API prepare → card-format signature → broadcast → `spend_rejected` on testnet.
