// The agent's side: ask the shared policy hub to pay, signed with the agent's function-call key.
//
//   node scripts/agent.mjs spend <receiver> <near> [memo]
//   node scripts/agent.mjs budget

import { actionCreators } from '@near-js/transactions';
import { ACCOUNT, hubAgent, POLICY_ACCOUNT, print, sendAt, viewAt, yocto } from './near.mjs';

if (!ACCOUNT) {
  console.error('NEAR_ACCOUNT is required (the card-controlled user account)');
  process.exit(2);
}

const [cmd, ...args] = process.argv.slice(2);
const TGAS = 10n ** 12n;
const API_URL = process.env.API_URL ?? 'http://127.0.0.1:8787';

if (cmd === 'spend') {
  const [receiver_id, near, memo = ''] = args;
  if (!receiver_id || !near) throw new Error('usage: agent.mjs spend <receiver> <near> [memo]');
  const result = await sendAt(ACCOUNT, hubAgent, [
    actionCreators.functionCall('request_spend', { receiver_id, amount: yocto(near), memo }, 50n * TGAS, 0n),
  ], POLICY_ACCOUNT);
  print(result);

  // Tell the approval API about a held spend. The API verifies it on-chain before
  // notifying the iOS app, so this is only a latency optimization, not authority.
  if (result.value?.status === 'pending') {
    try {
      const res = await fetch(`${API_URL}/api/agent/notify`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id: String(result.value.id), account: ACCOUNT }),
      });
      if (res.ok) console.log(`notified     ${API_URL} (pending #${result.value.id})`);
    } catch {
      // The API may not be running; the demo still works from the chain state.
    }
  }
} else if (cmd === 'budget') {
  console.log(JSON.stringify(await viewAt(POLICY_ACCOUNT, 'get_user', { account: ACCOUNT }), null, 2));
} else {
  console.error('usage: agent.mjs spend <receiver> <near> [memo] | budget');
  process.exitCode = 2;
}
