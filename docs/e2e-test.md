# End-to-end test runbook

Three levels of "clean":

1. **New agent session** — same repo, app, card, and account. Tests the MCP/agent path only.
2. **New repo** — same machine, card, phone, and account. Tests reproducibility of the code.
3. **New install / first run** — a fresh app (and usually a fresh card). Tests the whole user experience.

The first two are easy. The third has one current gap: the app has no "restore an existing card"
flow, so a reinstall on a phone with an already-set-up card cannot re-link it. Use a fresh/factory-reset
card for a true first-run test, or keep the app installed.

---

## 1. New agent session (5 minutes)

Prerequisites: API running, app installed, card linked, agent paired (see 1b), MCP server configured.

```sh
cd keyring-agents-guard

# 1. confirm the agent-side capability
NEAR_ACCOUNT=<card account> POLICY_ACCOUNT=keyring-policy-1105.testnet \
  node mcp/smoke.mjs

# 2. or drive it from OpenCode
opencode mcp list          # keyring connected
```

In a **new OpenCode session** in this repo:

> Pay the invoices in `invoices/` using `keyring_request_spend`. If a payment is pending, tell me
> and wait; do not try to bypass the policy.

Expected:

- `keyring_request_spend` is called.
- The app shows the pending request within ~5 seconds.
- Reject or approve with the card.

The canonical skill is `skills/keyring-agent/SKILL.md`; `.opencode/skills/keyring-agent` is a symlink.
`AGENTS.md` and `CLAUDE.md` carry the repo-level instructions. The MCP server is host-neutral.

---

## 1b. Pair an agent (the `npx` flow, 5 minutes)

Prerequisites: API running (`POLICY_ACCOUNT` + `SPONSOR_ACCOUNT`), app installed, card linked.

In a scratch repo (or this repo with `--force`):

```sh
mkdir /tmp/keyring-pair-test && cd /tmp/keyring-pair-test
npx ./packages/keyring-agent-skills init --agent print
```

Expected output:

```
agent key    /tmp/keyring-pair-test/.keyring/agent-key.json
gitignore    added .keyring/
agent        ed25519:…
  Pairing code: 1A2B3C
  Link:         keyring-agent://pair?code=1A2B3C
  Waiting for approval…
```

1. Open the app → **Settings → Agent → Pair an agent** (or the first-run **Link account** screen,
   which has the same field).
2. Enter the code, tap **Load**.
3. Expected: the agent's public key, "Permission: request_spend only", and the policy appear.
4. Tap **Approve agent with card** → PIN → hold the card.
5. The app signs and broadcasts `AddKey` + `set_agent_key`; then completes the pairing.
6. Expected CLI output:

```
paired       u…keyring-sponsor-1105.testnet
config       /tmp/keyring-pair-test/.keyring/config.json
skill        /tmp/keyring-pair-test/.opencode/skills/keyring-agent/SKILL.md
mcp          (OpenCode config, or printed JSON with --agent print)
```

7. Check the API verified the key before completing: completing a code with an account that does
   not hold that key returns `409 the agent key is not on that account`.
8. The agent key is function-call only:

```sh
near view-state <account>              # or the hub's get_user
# expected: permission.FunctionCall receiver_id = keyring-policy-1105.testnet
#           method_names = ["request_spend"]
```

9. Use the paired key with the packaged MCP server:

```sh
NEAR_ACCOUNT=<account> \
POLICY_ACCOUNT=keyring-policy-1105.testnet \
HUB_AGENT_KEY_FILE=/tmp/keyring-pair-test/.keyring/agent-key.json \
node ./mcp/server.mjs
```

Or from an approved agent session, on the **next** session after pairing:

> init my keyring agent account

Expected: the agent calls `budget` and reports the account, per-payment cap, daily budget, and
remaining balance.

### Agent-driven pairing (`--no-wait`)

Install only the skill first (`npx keyring-agent-skills install`), start an agent session, and say
**init my keyring agent account**. For agents that cannot block for minutes, the underlying
commands are:

```sh
npx keyring-agent-skills init --no-wait --json   # { code, url, agentPublicKey }
npx keyring-agent-skills finish --code 1A2B3C    # after the app shows paired
npx keyring-agent-skills status                  # JSON: config + on-chain context
```

---

## 2. New repo (same machine, card, phone, account)

```sh
# clone/copy the repo next to the private applet repo
git clone <keyring-agents-guard-url> keyring-agents-guard
cd keyring-agents-guard

npm install
(cd contract && cargo test)          # 25 pass
(cd ios-app && xcodegen generate)
```

Check the local package path and applet path:

- `ios-app/project.yml` → `packages.KeyringCardClient.path` must point to
  `../../near-hackthon-applets/client-swift`.
- `scripts/near.mjs` → `APPLETS_DIR` (or `APPLETS_DIR` env) must point to the applet repo.
- The applet repo must have `NearSign.java` and the `nearSign` Gradle task (it is private).

Run the API with the **same hub and sponsor**, using your existing card account:

```sh
POLICY_ACCOUNT=keyring-policy-1105.testnet \
SPONSOR_ACCOUNT=keyring-sponsor-1105.testnet \
node api/server.mjs
```

The new repo needs its own agent key. The product path:

```sh
npx keyring-agent-skills init
```

Enter the code in the app and approve; the CLI writes `.keyring/config.json` and the MCP config.
That is a **new agent key on the same account**, which is fine: the old key stays valid or can be
removed with the card. Re-pairing rotates the hub's `agent_key`, so only the newest key can call
`request_spend`.

The repo-internal demo scripts also use `.secrets/agent-hub-key.json` (`.secrets/agent-key.json`
for the original spike). If you reuse those scripts against an existing account, copy the matching
key file:

```sh
cp <old-repo>/.secrets/agent-hub-key.json <new-repo>/.secrets/agent-hub-key.json
chmod 600 <new-repo>/.secrets/agent-hub-key.json
```

Otherwise the script's key is not an access key on the old account and spends fail.

Test:

```sh
NEAR_ACCOUNT=<card account> node mcp/smoke.mjs testnet 0.1 "API credits"
```

Expected: `paid`, no card. Then the scam default: `pending`, app shows.

The app needs no change; point it at the new API (same LAN address, same port).

---

## 3. New install / whole first-run UX

This is the real user experience test.

### Fresh card

1. Install the applet and personalize the card (Mac + PC/SC):
   ```sh
   cd near-hackthon-applets
   java -jar gp.jar --install build/cap/keyring.cap
   ./gradlew personalizeCard
   ```
   This leaves the card fresh: no PIN, no seed, certificate stored.
2. Install the app on the iPhone (delete any old copy first).
3. On the phone:
   - set the API server to `http://<mac-lan-ip>:8787`,
   - **Set up card**: check card → PIN → 12 words → tap to load the wallet,
   - **Link account**: optionally paste the pairing code from `npx keyring-agent-skills init`
     (the agent key is created with the account), → PIN → tap (sponsor creates it; card signs
     `register` + `deposit`).
4. Expected: home screen; **Settings → Your account** shows `u…keyring-sponsor-1105.testnet`.
5. Check the hub has one more user, the approver key is the card's public key, and the agent key is
   the one the CLI printed.
6. Finish the pairing if you used the CLI: it writes config, skill, and MCP entry. Start a new agent
   session and say **init my keyring agent account**; the agent reports the policy.
7. Run the agent (paired key):
   ```sh
   NEAR_ACCOUNT=<new account> POLICY_ACCOUNT=keyring-policy-1105.testnet \
     HUB_AGENT_KEY_FILE=<repo>/.keyring/agent-key.json \
     node mcp/smoke.mjs scam-wallet-1023.testnet 0.2 "poisoned invoice"
   ```
   Expected pending; app shows; reject with the card.
8. Run a legit large payment (`0.8` to `testnet`): pending `OverTxLimit`; approve with the card.
9. Wallet: receive address/QR; add 0.2 to spending; withdraw 0.2; each asks for PIN + card.
10. Kill and relaunch the app: it should go straight to the home screen (card record + account persisted).

### Reusing an existing card

If the card already has a wallet, do **not** reinstall the app: the app has no restore flow yet,
and the setup screen refuses a card with a seed (`seedLoaded`). Keep the app, or use a factory-reset
card and a new account.

A "Restore card" flow is the next wallet feature: enter the account ID, tap the card, verify the
PIN and that the exported public key is the hub approver, then save the card record. Without it, a
new phone cannot recover an existing card/account from the card alone.

### Existing card with a factory reset

`./gradlew personalizeCard` wipes the PIN and seed while keeping the certificate. The old 12 words
and the old account's card key are then orphaned; the new setup creates a new key and a new account.
Keep the old words if you might need the old account.

---

## Whole-UX checklist

- [ ] Fresh app opens on **Set up your card**, not the home screen.
- [ ] Card check → PIN → 12 words → tap succeeds.
- [ ] Link account → sponsor creates `u…keyring-sponsor-1105.testnet`.
- [ ] `npx keyring-agent-skills init` prints a code; the app accepts it and shows the agent key + policy.
- [ ] Approving with the card adds a **function-call** agent key and calls `set_agent_key`.
- [ ] CLI writes `.keyring/config.json`, installs the skill + MCP config, and gitignores `.keyring/`.
- [ ] Completing a pairing for an account without that key fails with `409`.
- [ ] Home shows the account; Settings copies the account ID.
- [ ] New agent session + "init my keyring agent account" → `budget` reports the policy.
- [ ] Agent `request_spend` inside policy → paid, no card.
- [ ] Agent `request_spend` to `scam-wallet-1023.testnet` → pending, app shows.
- [ ] Reject with card → pending empty; tx on explorer.
- [ ] `0.8 NEAR` → `OverTxLimit`; approve with card.
- [ ] Wallet: receive/deposit/withdraw with card.
- [ ] App relaunch → home, account persists.
- [ ] New OpenCode session → `keyring_request_spend` → app pending.
- [ ] Hub: user count, approver key = card key, agent key = `request_spend` only.
- [ ] Agent key cannot approve/withdraw (NEAR rejects).

## Common failures

| Symptom | Check |
|---|---|
| `EADDRINUSE :8787` | An old API is running: `lsof -nP -iTCP:8787 -sTCP:LISTEN`; kill it or use `API_PORT=8788` |
| App can't reach API | API on `0.0.0.0`, phone on same Wi-Fi, `http://<mac-lan-ip>:8787` |
| Sponsor fails | `keyring-sponsor-1105.testnet` balance; 2 NEAR per onboarding |
| App doesn't show agent pending | `NEAR_ACCOUNT` in the smoke/MCP equals the app's account; wait/pull to refresh |
| Setup refuses card | Card already has a seed; use a fresh/factory-reset card or the restore flow |
| Card certificate error | Card not personalized with the app's pinned test CA; run `personalizeCard` |
| MCP tool not found | `opencode mcp list`; server path/env; restart the session |
| `410/404 pairing code not found` | The API restarted (codes are in memory) or the code expired; run `init` again |
| `409 the agent key is not on that account` | The app did not broadcast `AddKey` (card/PIN/network); re-pair and watch the app status |
| Agent says NEAR_ACCOUNT is required | The MCP env was not written; run `npx keyring-agent-skills install` or check the config |
