# Keyring MCP server

Gives any MCP-capable agent the **spending capability**, not the wallet keys.

| Tool | What it does |
|---|---|
| `request_spend` | Pays inside the policy, or returns `pending` for a human/card decision |
| `pending` | Lists payments waiting for the card |
| `budget` | Reads the policy, balance, keys, pending count |

There is **no** approve, reject, withdraw, or set-policy tool. Those need the Keyring card.

## Install (the normal path)

Do not wire the server by hand. Run the installer in the repo where the agent works:

```sh
npx keyring-agent-skills init
```

It creates `.keyring/agent-key.json`, prints a pairing code, and waits. Enter the code in the app
(**Pair agent**), approve with the card, and the CLI finishes:

- writes `.keyring/config.json`
- copies the skill to `.opencode/skills/keyring-agent/SKILL.md` (or `~/.claude/skills/` with `--agent claude`)
- registers the MCP server (`opencode mcp add keyring …`, or `.mcp.json`)
- adds `.keyring/` to `.gitignore`

Agents that cannot block for minutes can split it:

```sh
npx keyring-agent-skills init --no-wait --json   # prints { code, url, agentPublicKey }
npx keyring-agent-skills finish --code BFE04D    # after the app approves
npx keyring-agent-skills status                  # account, policy, balance
```

## Test the agent path

This starts the MCP server over stdio and drives it like an agent: list tools, read budget,
request a spend, read pending. It does not need OpenCode or Claude Code.

```sh
NEAR_ACCOUNT=<card account> POLICY_ACCOUNT=keyring-policy-1105.testnet \
  node mcp/smoke.mjs

# or choose the payment
NEAR_ACCOUNT=<card account> node mcp/smoke.mjs testnet 0.1 "API credits"
```

The default is `0.2 NEAR` to `scam-wallet-1023.testnet`, which should return `pending` /
`NotAllowlisted`. The app then shows the request; approve or reject with the card.

## Run

From the repo root:

```sh
NEAR_ACCOUNT=<card account> \
POLICY_ACCOUNT=keyring-policy-1105.testnet \
HUB_AGENT_KEY_FILE=.keyring/agent-key.json \
node mcp/server.mjs
```

Environment:

| Variable | Meaning |
|---|---|
| `NEAR_ACCOUNT` | The user's card-controlled NEAR account (required; no default) |
| `POLICY_ACCOUNT` | The shared hub (default `keyring-policy-1105.testnet`) |
| `HUB_AGENT_KEY_FILE` | The agent key file; defaults to `.secrets/agent-hub-key.json` (repo dev key) |
| `API_URL` | Optional; default `http://127.0.0.1:8787` for the instant pending notification |

The server signs `request_spend` with the key in `HUB_AGENT_KEY_FILE`. Pairing adds that key to the
user account with **only** the `request_spend` permission; the card can remove it.

## How pairing works

1. The CLI asks the API for a pairing code bound to the agent's public key.
2. The app loads the code, shows the agent key and policy, and the card signs:
   - `AddKey` on the user account: ed25519, function-call only, `request_spend` on the hub,
     small gas allowance.
   - `set_agent_key` on the hub: binds it as the account's agent.
3. The app completes the pairing. The API verifies on-chain that the key exists, is function-call
   limited to the hub, may call `request_spend`, and is bound as the hub's `agent_key`; only then
   does the CLI trust the account. A half-finished pairing can be resumed: the app checks which
   half is missing and signs only that step.
4. The CLI writes the config and installs the skill/MCP entry.

Pairing codes live in the API's memory. An API restart invalidates outstanding codes; run `init`
again.

## OpenCode

The installer runs this for you; by hand it is:

```sh
opencode mcp add keyring \
  --env NEAR_ACCOUNT=<card account> \
  --env POLICY_ACCOUNT=keyring-policy-1105.testnet \
  --env HUB_AGENT_KEY_FILE=<repo>/.keyring/agent-key.json \
  -- node <repo>/mcp/server.mjs
```

OpenCode exposes the tools as `keyring_request_spend`, `keyring_pending`, `keyring_budget`.

## Claude Code

The installer writes `.mcp.json` with `--agent claude`. By hand:

```json
{
  "mcpServers": {
    "keyring": {
      "command": "node",
      "args": ["<repo>/mcp/server.mjs"],
      "env": {
        "NEAR_ACCOUNT": "<card account>",
        "POLICY_ACCOUNT": "keyring-policy-1105.testnet",
        "HUB_AGENT_KEY_FILE": "<repo>/.keyring/agent-key.json",
        "API_URL": "http://127.0.0.1:8787"
      }
    }
  }
}
```

## What the agent cannot do

- Approve, reject, withdraw, or change the policy.
- Move funds outside the per-payment cap, daily budget, or allowlist.
- Bypass the limit by retrying: a held payment is held again.

The card is the only approver. The phone shows the decoded request; the card signs it over NFC.
