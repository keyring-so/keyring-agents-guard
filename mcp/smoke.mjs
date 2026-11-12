// Agent-path smoke test. Starts the MCP server over stdio and drives it like an agent would.
//
//   NEAR_ACCOUNT=<card account> node mcp/smoke.mjs
//   NEAR_ACCOUNT=<card account> node mcp/smoke.mjs <receiver> <amountNear> <memo>
//
// Defaults: 0.2 NEAR to scam-wallet-1023.testnet with a "poisoned invoice" memo.
// That should return pending / NotAllowlisted and appear in the app.

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const account = process.env.NEAR_ACCOUNT;
if (!account) {
  console.error('set NEAR_ACCOUNT to the card account');
  process.exit(2);
}

const [receiverId = 'scam-wallet-1023.testnet', amountNear = '0.2', memo = 'poisoned invoice'] =
  process.argv.slice(2);

const transport = new StdioClientTransport({
  command: 'node',
  args: [path.join(here, 'server.mjs')],
  cwd: root,
  env: {
    ...process.env,
    NEAR_ACCOUNT: account,
    POLICY_ACCOUNT: process.env.POLICY_ACCOUNT ?? 'keyring-policy-1105.testnet',
  },
});

const client = new Client({ name: 'keyring-smoke', version: '1.0.0' });
await client.connect(transport);

const tools = await client.listTools();
console.log(`tools:   ${tools.tools.map((t) => t.name).join(', ')}`);

const budget = await client.callTool({ name: 'budget', arguments: {} });
console.log(`budget:  ${budget.content[0].text.replace(/\s+/g, ' ').slice(0, 220)}`);

const spend = await client.callTool({
  name: 'request_spend',
  arguments: { receiverId, amountNear, memo },
});
console.log(`spend:   ${spend.content[0].text.replace(/\s+/g, ' ')}`);

const pending = await client.callTool({ name: 'pending', arguments: {} });
console.log(`pending: ${pending.content[0].text.replace(/\s+/g, ' ')}`);

await client.close();
