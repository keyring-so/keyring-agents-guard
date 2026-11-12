# Keyring MCP server

Gives any MCP-capable agent the **spending capability**, not the wallet keys.

| Tool | What it does |
|---|---|
| `request_spend` | Pays inside the policy, or returns `pending` for a human/card decision |
| `pending` | Lists payments waiting for the card |
| `budget` | Reads the policy, balance, keys, pending count |

There is **no** approve, reject, withdraw, or set-policy tool. Those need the Keyring card.

## Run

From the repo root:

```sh
NEAR_ACCOUNT=<card account> \
POLICY_ACCOUNT=keyring-policy-1105.testnet \
node mcp/server.mjs
```

Environment:

| Variable | Meaning |
|---|---|
| `NEAR_ACCOUNT` | The user's card-controlled NEAR account |
| `POLICY_ACCOUNT` | The shared hub (default `keyring-policy-1105.testnet`) |
| `API_URL` | Optional; default `http://127.0.0.1:8787` for the instant pending notification |

The server signs `request_spend` with `.secrets/agent-hub-key.json`. That key is added to the
user account by the sponsor with **only** the `request_spend` permission.

## OpenCode

Add the server to `opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "keyring": {
        "type": "local",
        "command": ["node", "/Users/kaichaosun/github/web3/near-hackthon/mcp/server.mjs"],
        "cwd": "/Users/kaichaosun/github/web3/near-hackthon",
        "environment": {
          "NEAR_ACCOUNT": "<card account>",
          "POLICY_ACCOUNT": "keyring-policy-1105.testnet",
          "API_URL": "http://127.0.0.1:8787"
        }
      }
    }
  }
}
```

Or from the CLI:

```sh
opencode mcp add keyring \
  --env NEAR_ACCOUNT=<card account> \
  --env POLICY_ACCOUNT=keyring-policy-1105.testnet \
  -- node /Users/kaichaosun/github/web3/near-hackthon/mcp/server.mjs
```

OpenCode exposes the tools as `keyring_request_spend`, `keyring_pending`, `keyring_budget`.

The project skill in `.opencode/skills/keyring-agent/SKILL.md` tells the agent when and how to use
them. The skill is guidance; the contract is the enforcement.

## Claude Code

`.mcp.json` in the project:

```json
{
  "mcpServers": {
    "keyring": {
      "command": "node",
      "args": ["/Users/kaichaosun/github/web3/near-hackthon/mcp/server.mjs"],
      "env": {
        "NEAR_ACCOUNT": "<card account>",
        "POLICY_ACCOUNT": "keyring-policy-1105.testnet",
        "API_URL": "http://127.0.0.1:8787"
      }
    }
  }
}
```

Copy `.opencode/skills/keyring-agent/SKILL.md` to `~/.claude/skills/keyring-agent/SKILL.md` if you
want Claude Code to discover the guidance as a skill.

## What the agent cannot do

- Approve, reject, withdraw, or change the policy.
- Move funds outside the per-payment cap, daily budget, or allowlist.
- Bypass the limit by retrying: a held payment is held again.

The card is the only approver. The phone shows the decoded request; the card signs it over NFC.
