// Spike: sign a NEAR transaction with the Keyring card's secp256k1 key (jCardSim).
//
//   node card-sign.mjs pubkey            print the card's NEAR public key (secp256k1:...)
//   node card-sign.mjs offline           build + sign + verify a transfer, no network
//   NEAR_ACCOUNT=you.testnet node card-sign.mjs send [receiver] [yocto]
//                                        sign a real transfer and broadcast it to testnet
//
// The card signs sha256(borsh(tx)); NEAR wants r‖s‖v (65 bytes) and the 64-byte key.
// Both are produced by the applet repo's `nearSign` gradle task (NearSign.java).

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PublicKey } from '@near-js/crypto';
import {
  actionCreators, createTransaction, encodeTransaction,
  Signature, SignedTransaction,
} from '@near-js/transactions';
import { baseDecode, baseEncode } from '@near-js/utils';
import { secp256k1 } from '@noble/curves/secp256k1';

const here = path.dirname(fileURLToPath(import.meta.url));
const APPLETS_DIR = process.env.APPLETS_DIR ?? path.resolve(here, '../../near-hackthon-applets');
const RPC = process.env.NEAR_RPC ?? 'https://test.rpc.fastnear.com';
const KEY_TYPE_SECP256K1 = 1;

// jCardSim chatters on stdout; the tool's answer is the last JSON line.
function card(...args) {
  const out = execFileSync('./gradlew', ['-q', 'nearSign', `-Pargs=${args.join(' ')}`], {
    cwd: APPLETS_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  });
  const line = out.trim().split('\n').reverse().find((l) => l.startsWith('{'));
  return JSON.parse(line);
}

const hex = (b) => Buffer.from(b).toString('hex');
const nearKey = (pubHex) => PublicKey.fromString(`secp256k1:${baseEncode(Buffer.from(pubHex, 'hex'))}`);

async function rpc(method, params) {
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 'spike', method, params }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`);
  return body.result;
}

function signWithCard(tx) {
  const hash = createHash('sha256').update(encodeTransaction(tx)).digest();
  const { publicKey, signature } = card('sign', hex(hash));
  const sig = Buffer.from(signature, 'hex');

  // 1. the key the card signed with is the key the tx names
  if (publicKey !== hex(tx.publicKey.data)) throw new Error('card key differs from tx key');
  // 2. NEAR JS verification (checks r‖s only)
  if (!tx.publicKey.verify(hash, sig)) throw new Error('signature does not verify');
  // 3. nearcore recovers the key from r‖s‖v, so v must recover the same key
  const recovered = secp256k1.Signature.fromCompact(sig.subarray(0, 64))
    .addRecoveryBit(sig[64]).recoverPublicKey(hash).toRawBytes(false).subarray(1);
  if (hex(recovered) !== publicKey) throw new Error(`recovery id ${sig[64]} recovers a different key`);

  const signed = new SignedTransaction({
    transaction: tx,
    signature: new Signature({ keyType: KEY_TYPE_SECP256K1, data: sig }),
  });
  // 4. the borsh encoding round-trips
  const bytes = signed.encode();
  if (hex(SignedTransaction.decode(bytes).encode()) !== hex(bytes)) throw new Error('borsh round-trip');

  console.log(`tx hash      ${baseEncode(hash)}`);
  console.log(`signature    r‖s‖v, v=${sig[64]}  (verified, key recovers)`);
  return bytes;
}

const [mode = 'offline', receiver = 'keyring-spike-sink.testnet', yocto = '1'] = process.argv.slice(2);

if (mode === 'pubkey') {
  console.log(nearKey(card('pubkey').publicKey).toString());
} else if (mode === 'offline') {
  const key = nearKey(card('pubkey').publicKey);
  console.log(`card key     ${key.toString()}`);
  const tx = createTransaction('keyring-spike.testnet', key, receiver, 1n,
    [actionCreators.transfer(BigInt(yocto))], new Uint8Array(32));
  signWithCard(tx);
  console.log('offline: ok');
} else if (mode === 'send') {
  const account = process.env.NEAR_ACCOUNT;
  if (!account) throw new Error('set NEAR_ACCOUNT to a testnet account holding the card key');
  const key = nearKey(card('pubkey').publicKey);
  console.log(`card key     ${key.toString()}`);
  const ak = await rpc('query', {
    request_type: 'view_access_key', finality: 'final', account_id: account, public_key: key.toString(),
  });
  const tx = createTransaction(account, key, receiver, BigInt(ak.nonce) + 1n,
    [actionCreators.transfer(BigInt(yocto))], baseDecode(ak.block_hash));
  const bytes = signWithCard(tx);
  const result = await rpc('broadcast_tx_commit', [Buffer.from(bytes).toString('base64')]);
  console.log(`status       ${JSON.stringify(result.status)}`);
  console.log(`explorer     https://testnet.nearblocks.io/txns/${result.transaction.hash}`);
} else {
  console.error('usage: node card-sign.mjs pubkey | offline | send [receiver] [yocto]');
  process.exit(2);
}
