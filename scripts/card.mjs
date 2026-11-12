// Terminal fallback for the human's side. The iOS app is the primary approval flow;
// this is useful when debugging the contract without the phone. Note: the card signer here
// is the dev jCardSim key, which is the user account's full-access key but not necessarily
// the hub approver. If the hub approver is your physical card, use the app to approve.
//
//   node scripts/card.mjs pending
//   node scripts/card.mjs approve <id>
//   node scripts/card.mjs reject <id>

import { actionCreators } from '@near-js/transactions';
import { ACCOUNT, card, POLICY_ACCOUNT, print, sendAt, viewAt } from './near.mjs';

if (!ACCOUNT) {
  console.error('NEAR_ACCOUNT is required (the card-controlled user account)');
  process.exit(2);
}

const [cmd, id] = process.argv.slice(2);
const TGAS = 10n ** 12n;

if (cmd === 'pending') {
  const pending = await viewAt(POLICY_ACCOUNT, 'get_pending', { account: ACCOUNT });
  if (pending.length === 0) console.log('no pending spends');
  for (const p of pending) {
    console.log(`#${p.id}  ${p.reason.padEnd(16)}  ${Number(BigInt(p.amount) / 10n ** 20n) / 1e4} NEAR → ${p.receiver_id}  "${p.memo}"`);
  }
} else if ((cmd === 'approve' || cmd === 'reject') && id !== undefined) {
  console.log(`${cmd} #${id} — tap the card to sign…`);
  print(await sendAt(ACCOUNT, card, [
    actionCreators.functionCall(cmd, { id }, 30n * TGAS, 0n),
  ], POLICY_ACCOUNT));
} else {
  console.error('usage: card.mjs pending | approve <id> | reject <id>');
  process.exitCode = 2;
}
