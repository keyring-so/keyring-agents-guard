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

Prerequisites: API running, app installed, card linked, MCP server configured.

```sh
cd /Users/kaichaosun/github/web3/near-hackthon

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

## 2. New repo (same machine, card, phone, account)

```sh
# clone/copy the repo next to the private applet repo
git clone <near-hackthon-url> near-hackthon
cd near-hackthon

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

The new repo creates a new `.secrets/agent-hub-key.json` on first use. That's fine for a **new
account**: the sponsor adds the new agent key during onboarding. Existing users keep their old
agent keys.

**If you are reusing an existing account in the new repo, copy the old key file:**

```sh
cp <old-repo>/.secrets/agent-hub-key.json <new-repo>/.secrets/agent-hub-key.json
chmod 600 <new-repo>/.secrets/agent-hub-key.json
```

Otherwise the new agent key is not an access key on the old account and spends fail. To rotate to
a new agent key you must add it to the account with the card (full access) and call `set_agent_key`
on the hub; that rotation flow is not in the app yet.

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
   - **Link account**: create account → PIN → tap (sponsor creates it; card signs `register` + `deposit`).
4. Expected: home screen; **Settings → Your account** shows `u…keyring-sponsor-1105.testnet`.
5. Check the hub has one more user and the account's approver key is the card's public key.
6. Run the agent:
   ```sh
   NEAR_ACCOUNT=<new account> POLICY_ACCOUNT=keyring-policy-1105.testnet \
     node mcp/smoke.mjs
   ```
   Expected pending; app shows; reject with the card.
7. Run a legit large payment (`0.8` to `testnet`): pending `OverTxLimit`; approve with the card.
8. Wallet: receive address/QR; add 0.2 to spending; withdraw 0.2; each asks for PIN + card.
9. Kill and relaunch the app: it should go straight to the home screen (card record + account persisted).

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
- [ ] Home shows the account; Settings copies the account ID.
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
