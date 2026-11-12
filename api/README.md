# Keyring Agent API

Shared backend for the iOS approval app and the agent/MCP path. It reads the shared policy hub and
routes card-signed transactions. It never holds a card key, the agent key, or the PIN.

**The API is multi-user.** It does not have a global user account. Every user request carries the
user's account in the `X-User-Account` header (or `?account=`). The agent/MCP process has its own
`NEAR_ACCOUNT` because the agent signs for that specific user; the API does not.

## Run

From the repo root (dependencies come from the root `node_modules`):

```sh
POLICY_ACCOUNT=keyring-policy-1105.testnet \
SPONSOR_ACCOUNT=keyring-sponsor-1105.testnet \
node api/server.mjs
```

No `NEAR_ACCOUNT` is needed for the API itself.

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `API_PORT` | `8787` | Listen port |
| `API_HOST` | `0.0.0.0` | Bind address (LAN devices can reach it) |
| `API_TOKEN` | empty | If set, clients must send `Authorization: Bearer <token>` |
| `POLICY_ACCOUNT` | `keyring-policy-1105.testnet` in practice | Shared policy hub |
| `SPONSOR_ACCOUNT` | `keyring-sponsor-1105.testnet` in practice | Account that creates user accounts |
| `NEAR_RPC` | `https://test.rpc.fastnear.com` | RPC endpoint |

## User identity

```http
X-User-Account: u1a2b3c4d5.keyring-sponsor-1105.testnet
```

Every user endpoint below requires it. Missing → `400 X-User-Account header is required`.
This is why the app can point at one API and different cards/users can coexist.

## Endpoints

### `GET /health`

```json
{ "ok": true, "contract": "keyring-policy-1105.testnet", "sponsor": "keyring-sponsor-1105.testnet" }
```

### `GET /api/context`

Requires `X-User-Account`. Returns the user's policy, budget, hub balance, account balance, approver
key, agent key, and pending count.

### `GET /api/pending`

Requires `X-User-Account`.

```json
{
  "account": "u1a2b3c4d5.keyring-sponsor-1105.testnet",
  "contract": "keyring-policy-1105.testnet",
  "pending": [
    {
      "id": "3",
      "receiverId": "scam-wallet-1023.testnet",
      "amountYocto": "200000000000000000000000",
      "amountNear": "0.2",
      "memo": "poisoned invoice",
      "reason": "NotAllowlisted",
      "requestedAt": 1793766139944574200
    }
  ]
}
```

### `GET /api/pending/:id`

Requires `X-User-Account`. One normalized pending request.

### `POST /api/agent/notify`

The agent's latency hint. It verifies the id on-chain for that user; it does not broadcast to other
users. The app polls.

```sh
curl -X POST http://127.0.0.1:8787/api/agent/notify \
  -H 'content-type: application/json' \
  -d '{"id":"3","account":"u1a2b3c4d5.keyring-sponsor-1105.testnet"}'
```

### `POST /api/tx/prepare/:action/:id`

Requires `X-User-Account`. `action` is `approve` or `reject`. Returns the nonce, block hash, hub, and
approver key. The app builds the transaction itself.

### `POST /api/tx/submit`

Requires `X-User-Account`.

```json
{ "unsignedTxBase64": "…", "signatureHex": "<64-byte r‖s hex>" }
```

The API checks the signature against that user's hub approver key, assembles `r‖s‖v`, and broadcasts.

### `POST /api/onboard/sponsor`

```json
{ "cardPublicKeyHex": "<64-byte card public key hex>" }
```

The sponsor creates a fresh sub-account with the card key as full access, the agent key as
function-call, and 2 testnet NEAR. Returns the onboarding data.

### `POST /api/onboard/prepare`

```json
{ "account": "u…keyring-sponsor-1105.testnet", "cardPublicKeyHex": "…" }
```

Returns the nonce, block hash, agent key, registration fee, and default policy for the card to sign
`register` and `deposit`.

### `POST /api/broadcast`

Relays a card-signed onboarding/wallet transaction from the app.

```json
{ "unsignedTxBase64": "…", "signatureHex": "…", "publicKey": "secp256k1:…" }
```

## Security notes

- The API has **no global user account**. It cannot serve user A's data to user B unless the header
  says so; the hub contract also keys everything by the user's account.
- The shared SSE stream was removed: it could broadcast one user's pending to another. The app polls;
  for push, add a per-account stream or a notification service.
- The API is a router. It builds no transactions for approvals; the app builds and signs them, and the
  API only checks the signature against the user's approver key.
- The agent key signs `request_spend` only. The API cannot approve, reject, withdraw, or change policy.
- `API_TOKEN` is a simple shared secret for the LAN demo. Use TLS and real auth for production.
