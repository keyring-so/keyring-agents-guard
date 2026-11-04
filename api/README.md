# Keyring Agent API

Read-only chain access + unsigned transaction builder for the iOS approval app.

It never holds the card key, the agent key, or the PIN.

## Run

From the repo root (dependencies come from the root `node_modules`):

```sh
node api/server.mjs
```

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `API_PORT` | `8787` | Listen port |
| `API_HOST` | `0.0.0.0` | Bind address (LAN devices can reach it) |
| `API_TOKEN` | empty | If set, clients must send `Authorization: Bearer <token>` |
| `NEAR_ACCOUNT` | `keyring-spike-1023.testnet` | Policy contract account |
| `NEAR_RPC` | `https://test.rpc.fastnear.com` | RPC endpoint |

## Endpoints

### `GET /health`

```json
{ "ok": true, "account": "keyring-spike-1023.testnet" }
```

### `GET /api/context`

Returns the account, policy, budget, approver key, agent key, and pending count.

### `GET /api/pending`

```json
{
  "account": "keyring-spike-1023.testnet",
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

One pending request, normalized for the app.

### `GET /api/events`

Server-Sent Events. Sends a `snapshot` on connect and a `pending` event for each new id.

```sh
curl -N http://127.0.0.1:8787/api/events
```

### `POST /api/agent/notify`

The agent can hit this after a held spend. The server verifies the id on-chain before broadcasting.

```sh
curl -X POST http://127.0.0.1:8787/api/agent/notify \
  -H 'content-type: application/json' \
  -d '{"id":"3"}'
```

### `POST /api/tx/approve/:id` or `POST /api/tx/reject/:id`

Builds the unsigned transaction and returns its hash. The transaction is stored for 5 minutes.

```json
{
  "txId": "…",
  "hashHex": "…",
  "action": "approve",
  "id": "3",
  "pending": { "…": "…" },
  "expiresAt": 1793766454557,
  "signer": "secp256k1:…"
}
```

The iOS app signs `hashHex` with the card.

### `POST /api/tx/submit`

```json
{ "txId": "…", "signatureHex": "<64-byte r‖s hex>" }
```

The API recovers the recovery id from the signature and the approver key, assembles `r‖s‖v`, broadcasts, and returns:

```json
{
  "ok": true,
  "hash": "5cBH2dEP…",
  "explorer": "https://testnet.nearblocks.io/txns/5cBH2dEP…",
  "failure": null,
  "events": [{ "standard": "spend_policy", "event": "spend_rejected", "…": "…" }]
}
```

## Security notes

- The API is a **notifier and transaction builder**, not an authority. The app fetches and displays the request; the card signs.
- It has no secret keys. It reads public chain state and broadcasts the signature the app returns.
- It builds the transaction. A compromised API could try to build a different transaction; the app checks that the returned pending id/receiver/amount match what it displayed. For production, use a card-derived **function-call approval key** limited to `approve`/`reject`/`set_policy` so the network rejects anything else.
- `API_TOKEN` is a simple shared secret for the LAN demo. Use TLS and real auth for production.
