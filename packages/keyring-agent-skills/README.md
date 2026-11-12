# keyring-agent-skills

Install the Keyring spending capability into an MCP agent (OpenCode, Claude Code, Cursor, …) and
pair a card-controlled NEAR account.

The agent gets three narrow tools — `request_spend`, `pending`, `budget`. It never gets the ability
to approve its own payment. Over-limit payments wait for the Keyring card (NFC + PIN).

## Quick start

```sh
npx keyring-agent-skills init
```

It creates the agent key, prints a pairing code, and waits:

```
  Pairing code: BFE04D
  Link:         keyring-agent://pair?code=BFE04D
```

Open the Keyring app → **Pair agent** → enter the code → approve with the card. The card signs:

1. `AddKey` on your account — the agent key is function-call only, limited to `request_spend`
   on the hub.
2. `set_agent_key` on the hub.

Then the CLI writes `.keyring/config.json`, installs the skill, registers the MCP server, and adds
`.keyring/` to `.gitignore`. Start a new agent session and ask it to pay something.

## Commands

| Command | What it does |
|---|---|
| `init` | Create the agent key, pair, install the skill + MCP config |
| `init --no-wait --json` | Create the key and a pairing code, print JSON, exit |
| `finish --code CODE` | Complete a pairing started with `--no-wait` |
| `install` | Install the skill only (the agent can drive the pairing) |
| `status` | Show the paired account, policy, and balance |

Flags: `--api URL`, `--agent opencode\|claude\|both\|print`, `--force`, `--json`, `--no-wait`.

## Agent-driven setup

```sh
npx keyring-agent-skills install
```

Then open an agent session and say **init my keyring agent account**. The skill tells the agent to
run `init --no-wait --json`, show you the code, wait while you approve, and run `finish --code`.

## Files

- `.keyring/agent-key.json` — the agent's ed25519 key (mode 600, gitignored)
- `.keyring/config.json` — account, hub, API URL
- `.opencode/skills/keyring-agent/SKILL.md` — the skill (or `~/.claude/skills/` with `--agent claude`)
- `opencode.json` / `.mcp.json` — the MCP server entry

## Security

- The card key never leaves the card.
- The agent key can only call `request_spend`; the contract enforces the cap, daily budget, and
  allowlist.
- Pairing completes only after the API verifies on-chain that the key is a function-call key on the
  hub, allowed to call `request_spend`.

## Requirements

Node 18+, a Keyring card, and the Keyring iOS app on a physical iPhone (NFC).
