// Card-signed setup, one transaction: deploy the policy contract to ACCOUNT, initialise it, and
// give the agent a function-call key that can only call `request_spend` on it.
//
//   node scripts/deploy.mjs [--per-tx 0.5] [--daily 1] [--allow a.testnet,b.testnet]
//   node scripts/deploy.mjs --code-only      redeploy the wasm, keep state and keys

import fs from 'node:fs';
import { parseArgs } from 'node:util';
import { actionCreators } from '@near-js/transactions';
import { ACCOUNT, agent, card, print, send, WASM, yocto } from './near.mjs';

const { values: opts } = parseArgs({
  options: {
    'per-tx': { type: 'string', default: '0.5' },
    daily: { type: 'string', default: '1' },
    allow: { type: 'string', default: '' },
    'code-only': { type: 'boolean', default: false },
  },
});

const { deployContract, functionCall, addKey, functionCallAccessKey } = actionCreators;
const TGAS = 10n ** 12n;
// Covers the agent's gas fees only; it can never move the account's NEAR by itself.
const AGENT_GAS_ALLOWANCE = BigInt(yocto('0.25'));

const code = fs.readFileSync(WASM);
const actions = [deployContract(code)];

if (!opts['code-only']) {
  const policy = {
    per_tx_max: yocto(opts['per-tx']),
    daily_max: yocto(opts.daily),
    allowlist: opts.allow ? opts.allow.split(',') : [],
  };
  const approverKey = card.publicKey();
  const agentKey = agent.publicKey();
  console.log(`account      ${ACCOUNT}`);
  console.log(`approver     ${approverKey.toString()}  (Keyring card)`);
  console.log(`agent        ${agentKey.toString()}  (.secrets/agent-key.json)`);
  console.log(`policy       ${JSON.stringify(policy)}`);
  actions.push(
    functionCall('new', {
      approver_key: approverKey.toString(),
      agent_key: agentKey.toString(),
      policy,
    }, 30n * TGAS, 0n),
    addKey(agentKey, functionCallAccessKey(ACCOUNT, ['request_spend'], AGENT_GAS_ALLOWANCE)),
  );
}

console.log(`wasm         ${code.length} bytes — tap the card to sign…`);
print(await send(card, actions));
