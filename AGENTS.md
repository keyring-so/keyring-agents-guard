# Agent integration

This repo exposes a **Keyring MCP server** (`mcp/server.mjs`) that gives any MCP-capable agent a
spending capability, not the wallet keys.

| Tool | Purpose |
|---|---|
| `request_spend` | Pays inside the policy, or returns `pending` for a card decision |
| `pending` | Lists payments waiting for the card |
| `budget` | Reads the policy, balance, keys, pending count |

There is **no** approve, reject, withdraw, or set-policy tool. The Keyring card is the approver;
the phone app displays the decoded request. The contract enforces the same limits on-chain.

- Setup and host configs: `mcp/README.md`
- Portable skill: `skills/keyring-agent/SKILL.md`
- Smoke test: `NEAR_ACCOUNT=<card account> node mcp/smoke.mjs`
- Approval UI: `ios-app/` (native iPhone + NFC card)

Hosts prefix MCP tool names: `keyring_request_spend` in OpenCode, `mcp__keyring__request_spend` in
Claude Code. The skill is written against the unprefixed capability.
