// The agent's side: ask the policy contract to pay, signed with the agent's function-call key.
//
//   node scripts/agent.mjs spend <receiver> <near> [memo]
//   node scripts/agent.mjs budget

import { actionCreators } from '@near-js/transactions';
import { agent, print, send, view, yocto } from './near.mjs';

const [cmd, ...args] = process.argv.slice(2);
const TGAS = 10n ** 12n;

if (cmd === 'spend') {
  const [receiver_id, near, memo = ''] = args;
  if (!receiver_id || !near) throw new Error('usage: agent.mjs spend <receiver> <near> [memo]');
  print(await send(agent, [
    actionCreators.functionCall('request_spend', { receiver_id, amount: yocto(near), memo }, 50n * TGAS, 0n),
  ]));
} else if (cmd === 'budget') {
  console.log(JSON.stringify({ policy: await view('get_policy'), budget: await view('get_budget') }, null, 2));
} else {
  console.error('usage: agent.mjs spend <receiver> <near> [memo] | budget');
  process.exitCode = 2;
}
