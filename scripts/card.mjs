// The human's side: review pending spends and approve or reject them with the Keyring card.
//
//   node scripts/card.mjs pending
//   node scripts/card.mjs approve <id>
//   node scripts/card.mjs reject <id>

import { actionCreators } from '@near-js/transactions';
import { card, print, send, view } from './near.mjs';

const [cmd, id] = process.argv.slice(2);
const TGAS = 10n ** 12n;

if (cmd === 'pending') {
  const pending = await view('get_pending');
  if (pending.length === 0) console.log('no pending spends');
  for (const p of pending) {
    console.log(`#${p.id}  ${p.reason.padEnd(14)}  ${Number(BigInt(p.amount) / 10n ** 20n) / 1e4} NEAR → ${p.receiver_id}  "${p.memo}"`);
  }
} else if ((cmd === 'approve' || cmd === 'reject') && id !== undefined) {
  console.log(`${cmd} #${id} — tap the card to sign…`);
  print(await send(card, [actionCreators.functionCall(cmd, { id }, 30n * TGAS, 0n)]));
} else {
  console.error('usage: card.mjs pending | approve <id> | reject <id>');
  process.exitCode = 2;
}
