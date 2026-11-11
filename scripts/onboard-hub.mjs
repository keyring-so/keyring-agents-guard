// Onboard an existing user account into the shared hub.
//
//   NEAR_ACCOUNT=keyring-spike-1023.testnet \
//   POLICY_ACCOUNT=keyring-policy-1105.testnet \
//   CARD_APPROVER_KEY=<64-byte x||y hex from the app's "Card ready" screen> \
//   node scripts/onboard-hub.mjs
//
// Adds the two function-call keys to the user account (card approval key and hub agent key),
// registers the user with the hub, and deposits 1 NEAR. The user account's full-access key is
// the card's dev key, so the card signs these setup transactions.

import { actionCreators } from '@near-js/transactions';
import { PublicKey } from '@near-js/crypto';
import { baseEncode } from '@near-js/utils';
import {
  ACCOUNT, card, hubAgent, POLICY_ACCOUNT, print, sendAt, viewAt, yocto,
} from './near.mjs';

const { addKey, functionCall, functionCallAccessKey } = actionCreators;
const TGAS = 10n ** 12n;
const APPROVAL_METHODS = [
  'approve', 'reject', 'set_policy', 'set_agent_key', 'pause', 'unpause', 'withdraw', 'unregister',
];
const AGENT_METHODS = ['request_spend'];

const hex = process.env.CARD_APPROVER_KEY;
if (!hex || hex.length !== 128) {
  throw new Error('set CARD_APPROVER_KEY to the 64-byte card public key as hex (from the app)');
}
const approverKey = PublicKey.fromString(`secp256k1:${baseEncode(Buffer.from(hex, 'hex'))}`);
const agentKey = hubAgent.publicKey();

console.log(`user         ${ACCOUNT}`);
console.log(`policy hub   ${POLICY_ACCOUNT}`);
console.log(`approver     ${approverKey}`);
console.log(`agent        ${agentKey}`);

// 1. Add the card's approval key and the hub agent key to the user account.
print(await sendAt(ACCOUNT, card, [
  addKey(approverKey, functionCallAccessKey(POLICY_ACCOUNT, APPROVAL_METHODS, yocto('0.25'))),
  addKey(agentKey, functionCallAccessKey(POLICY_ACCOUNT, AGENT_METHODS, yocto('0.25'))),
]));

// 2. Register with the hub; the deposit covers the registration fee.
const policy = {
  per_tx_max: yocto('0.5'),
  daily_max: yocto('1'),
  allowlist: ['testnet'],
};
print(await sendAt(ACCOUNT, card, [
  functionCall('register', {
    approver_key: approverKey.toString(),
    agent_key: agentKey.toString(),
    policy,
  }, 30n * TGAS, yocto('0.01')),
], POLICY_ACCOUNT));

// 3. Fund the user's spending balance in the hub.
print(await sendAt(ACCOUNT, card, [
  functionCall('deposit', {}, 30n * TGAS, yocto('1')),
], POLICY_ACCOUNT));

console.log('user view    ' + JSON.stringify(await viewAt(POLICY_ACCOUNT, 'get_user', { account: ACCOUNT })));
