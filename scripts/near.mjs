// Shared plumbing: testnet RPC, the Keyring card signer (jCardSim via the applet repo), and the
// agent's local key.

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

export const ACCOUNT = process.env.NEAR_ACCOUNT ?? 'keyring-spike-1023.testnet';
export const RPC = process.env.NEAR_RPC ?? 'https://test.rpc.fastnear.com';
export const APPLETS_DIR = process.env.APPLETS_DIR ?? path.resolve(root, '../near-hackthon-applets');
export const AGENT_KEY_FILE = path.join(root, '.secrets', 'agent-key.json');
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

export async function view(method, args = {}) {
  const r = await rpc('query', {
    request_type: 'call_function', finality: 'final', account_id: ACCOUNT,
    method_name: method, args_base64: Buffer.from(JSON.stringify(args)).toString('base64'),
  });
  return JSON.parse(Buffer.from(r.result).toString());
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

/** The agent: an ed25519 key kept in .secrets/, created on first use. */
export const agent = {
  keyPair() {
    if (!fs.existsSync(AGENT_KEY_FILE)) {
      fs.mkdirSync(path.dirname(AGENT_KEY_FILE), { recursive: true, mode: 0o700 });
      const kp = KeyPair.fromRandom('ed25519');
      fs.writeFileSync(AGENT_KEY_FILE, JSON.stringify({ secret_key: kp.toString() }, null, 2), { mode: 0o600 });
    }
    return KeyPair.fromString(JSON.parse(fs.readFileSync(AGENT_KEY_FILE, 'utf8')).secret_key);
  },
  publicKey() {
    return this.keyPair().getPublicKey();
  },
  sign(hash) {
    return new Signature({ keyType: KEY_TYPE.ED25519, data: this.keyPair().sign(hash).signature });
  },
};

// --- transactions ----------------------------------------------------------------------------

/** Build a tx from ACCOUNT to itself (or `receiver`), sign it with `signer`, and wait for it. */
export async function send(signer, actions, receiver = ACCOUNT) {
  const publicKey = signer.publicKey();
  const ak = await rpc('query', {
    request_type: 'view_access_key', finality: 'final', account_id: ACCOUNT, public_key: publicKey.toString(),
  });
  const tx = createTransaction(ACCOUNT, publicKey, receiver, BigInt(ak.nonce) + 1n, actions, baseDecode(ak.block_hash));
  const hash = createHash('sha256').update(encodeTransaction(tx)).digest();
  const signed = new SignedTransaction({ transaction: tx, signature: signer.sign(hash, publicKey) });
  const result = await rpc('broadcast_tx_commit', [Buffer.from(signed.encode()).toString('base64')]);
  return summarize(result);
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
