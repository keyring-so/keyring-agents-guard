// Shared plumbing: testnet RPC, the Keyring card signer (jCardSim via the applet repo), and the
// agent keys. The user account signs; the policy hub is the receiver.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { KeyPair, PublicKey } from '@near-js/crypto';
import { createTransaction, encodeTransaction, Signature, SignedTransaction } from '@near-js/transactions';
import { baseDecode, baseEncode } from '@near-js/utils';
import { secp256k1 } from '@noble/curves/secp256k1';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** The user account: holds the keys, pays gas, owns the policy entry. */
export const ACCOUNT = process.env.NEAR_ACCOUNT ?? 'keyring-spike-1023.testnet';
/** The shared policy contract: one deployment for every user. */
export const POLICY_ACCOUNT = process.env.POLICY_ACCOUNT ?? ACCOUNT;
/** The account that creates and funds new user accounts (testnet sponsor). */
export const SPONSOR_ACCOUNT = process.env.SPONSOR_ACCOUNT ?? 'keyring-sponsor-1105.testnet';
export const RPC = process.env.NEAR_RPC ?? 'https://test.rpc.fastnear.com';
export const APPLETS_DIR = process.env.APPLETS_DIR ?? path.resolve(root, '../near-hackthon-applets');
export const AGENT_KEY_FILE = path.join(root, '.secrets', 'agent-key.json');
export const HUB_AGENT_KEY_FILE = path.join(root, '.secrets', 'agent-hub-key.json');
export const WASM = path.join(root, 'contract/target/near/spend_policy.wasm');

const KEY_TYPE = { ED25519: 0, SECP256K1: 1 };
const hex = (b) => Buffer.from(b).toString('hex');

export async function rpc(method, params) {
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 'near-hackthon', method, params }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error.data ?? body.error)}`);
  return body.result;
}

export async function viewAt(contract, method, args = {}) {
  const r = await rpc('query', {
    request_type: 'call_function', finality: 'final', account_id: contract,
    method_name: method, args_base64: Buffer.from(JSON.stringify(args)).toString('base64'),
  });
  if (r.error) throw new Error(`${contract}.${method}: ${r.error}`);
  return JSON.parse(Buffer.from(r.result).toString());
}

/** View the shared policy contract. */
export async function view(method, args = {}) {
  return viewAt(POLICY_ACCOUNT, method, args);
}

// --- signers ---------------------------------------------------------------------------------

// jCardSim chatters on stdout; the tool's answer is the last JSON line.
function cardTool(...args) {
  const out = execFileSync('./gradlew', ['-q', 'nearSign', `-Pargs=${args.join(' ')}`], {
    cwd: APPLETS_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  });
  return JSON.parse(out.trim().split('\n').reverse().find((l) => l.startsWith('{')));
}

/** The Keyring card: secp256k1, r‖s‖v signatures over the tx hash. */
export const card = {
  publicKey() {
    return PublicKey.fromString(`secp256k1:${baseEncode(Buffer.from(cardTool('pubkey').publicKey, 'hex'))}`);
  },
  sign(hash, publicKey) {
    const { publicKey: pub, signature } = cardTool('sign', hex(hash));
    if (pub !== hex(publicKey.data)) throw new Error('card key differs from tx key');
    const sig = Buffer.from(signature, 'hex');
    // nearcore recovers the key from r‖s‖v, so check v recovers the card's key
    const recovered = secp256k1.Signature.fromCompact(sig.subarray(0, 64))
      .addRecoveryBit(sig[64]).recoverPublicKey(hash).toRawBytes(false).subarray(1);
    if (hex(recovered) !== pub) throw new Error('card signature does not recover its key');
    return new Signature({ keyType: KEY_TYPE.SECP256K1, data: sig });
  },
};

function makeAgent(file) {
  return {
    keyPair() {
      if (!fs.existsSync(file)) {
        fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
        const kp = KeyPair.fromRandom('ed25519');
        fs.writeFileSync(file, JSON.stringify({ secret_key: kp.toString() }, null, 2), { mode: 0o600 });
      }
      return KeyPair.fromString(JSON.parse(fs.readFileSync(file, 'utf8')).secret_key);
    },
    publicKey() {
      return this.keyPair().getPublicKey();
    },
    sign(hash) {
      return new Signature({ keyType: KEY_TYPE.ED25519, data: this.keyPair().sign(hash).signature });
    },
  };
}

/** The original single-account agent. */
export const agent = makeAgent(AGENT_KEY_FILE);
/** The agent for the shared policy hub; its key is added to the user account. */
export const hubAgent = makeAgent(HUB_AGENT_KEY_FILE);

// --- transactions ----------------------------------------------------------------------------

/** Sign a tx as `account` and send it to `receiver` (defaults to `account` itself). */
export async function sendAt(account, signer, actions, receiver = account) {
  const publicKey = signer.publicKey();
  const ak = await rpc('query', {
    request_type: 'view_access_key', finality: 'final', account_id: account, public_key: publicKey.toString(),
  });
  const tx = createTransaction(account, publicKey, receiver, BigInt(ak.nonce) + 1n, actions, baseDecode(ak.block_hash));
  const hash = createHash('sha256').update(encodeTransaction(tx)).digest();
  const signed = new SignedTransaction({ transaction: tx, signature: signer.sign(hash, publicKey) });
  const result = await rpc('broadcast_tx_commit', [Buffer.from(signed.encode()).toString('base64')]);
  return summarize(result);
}

/** The common case: the user account. */
export async function send(signer, actions, receiver = ACCOUNT) {
  return sendAt(ACCOUNT, signer, actions, receiver);
}

function summarize(result) {
  const events = result.receipts_outcome
    .flatMap((r) => r.outcome.logs)
    .filter((l) => l.startsWith('EVENT_JSON:'))
    .map((l) => JSON.parse(l.slice('EVENT_JSON:'.length)));
  const failure = result.status.Failure ?? result.receipts_outcome.map((r) => r.outcome.status.Failure).find(Boolean);
  const value = result.status.SuccessValue;
  return {
    hash: result.transaction.hash,
    explorer: `https://testnet.nearblocks.io/txns/${result.transaction.hash}`,
    ok: !failure,
    failure,
    value: value ? JSON.parse(Buffer.from(value, 'base64').toString() || 'null') : null,
    events,
  };
}

export function print(summary) {
  for (const e of summary.events) console.log(`event        ${e.event} ${JSON.stringify(e.data[0])}`);
  if (summary.value !== null) console.log(`result       ${JSON.stringify(summary.value)}`);
  if (!summary.ok) console.log(`failed       ${JSON.stringify(summary.failure)}`);
  console.log(`explorer     ${summary.explorer}`);
  if (!summary.ok) process.exitCode = 1;
}

export const yocto = (near) => {
  const [whole, frac = ''] = String(near).split('.');
  return (BigInt(whole) * 10n ** 24n + BigInt(frac.padEnd(24, '0').slice(0, 24))).toString();
};
