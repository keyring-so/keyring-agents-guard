// Deploy the shared policy hub once, to its own testnet account.
//
//   POLICY_ACCOUNT=keyring-policy-1105.testnet node scripts/deploy-hub.mjs
//
// The account is created from the testnet faucet with the card's dev key as its only
// full-access key, then the wasm is deployed and initialized with the hub owner and the
// per-user registration fee.

import fs from 'node:fs';
import { actionCreators } from '@near-js/transactions';
import { card, POLICY_ACCOUNT, RPC, rpc, sendAt, viewAt, WASM, yocto } from './near.mjs';

const { deployContract, functionCall } = actionCreators;
const TGAS = 10n ** 12n;
const REGISTRATION_FEE = yocto('0.01');

async function accountExists(account) {
  try {
    await rpc('query', { request_type: 'view_account', finality: 'final', account_id: account });
    return true;
  } catch {
    return false;
  }
}

async function createAccount() {
  if (await accountExists(POLICY_ACCOUNT)) {
    console.log(`account      ${POLICY_ACCOUNT} already exists`);
    return;
  }
  const publicKey = card.publicKey().toString();
  console.log(`creating     ${POLICY_ACCOUNT} with ${publicKey}`);
  const res = await fetch('https://helper.nearprotocol.com/account', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ newAccountId: POLICY_ACCOUNT, newAccountPublicKey: publicKey }),
  });
  if (!res.ok) throw new Error(`faucet: ${res.status} ${await res.text()}`);
  for (let i = 0; i < 20; i++) {
    if (await accountExists(POLICY_ACCOUNT)) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error('account did not appear');
}

await createAccount();

const code = fs.readFileSync(WASM);
console.log(`wasm         ${code.length} bytes — card signs the deploy…`);
const result = await sendAt(POLICY_ACCOUNT, card, [
  deployContract(code),
  functionCall('new', { owner: POLICY_ACCOUNT, registration_fee: REGISTRATION_FEE }, 30n * TGAS, 0n),
], POLICY_ACCOUNT);

console.log(`explorer     ${result.explorer}`);
if (!result.ok) {
  console.error(JSON.stringify(result.failure, null, 2));
  process.exit(1);
}

console.log('stats        ' + JSON.stringify(await viewAt(POLICY_ACCOUNT, 'get_stats', {})));
