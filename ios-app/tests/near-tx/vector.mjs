// Golden vector: the same approve/reject transaction built by @near-js/transactions (the
// reference the API used before) and by the app's NearTx.swift. Both must match byte for byte.
//   node ios-app/tests/near-tx/vector.mjs > vector.json

import { actionCreators, createTransaction, encodeTransaction } from '@near-js/transactions';
import { PublicKey } from '@near-js/crypto';
import { baseEncode } from '@near-js/utils';
import { secp256k1 } from '@noble/curves/secp256k1';
import { createHash } from 'node:crypto';

const publicKeyHex = Buffer.from(secp256k1.getPublicKey(Buffer.alloc(32, 0x11), false).subarray(1)).toString('hex');

const inputs = {
  signerId: 'keyring-spike-1023.testnet',
  publicKeyHex,
  nonce: '274272456000004',
  receiverId: 'keyring-spike-1023.testnet',
  blockHashHex: Buffer.alloc(32, 0x22).toString('hex'),
  methodName: 'reject',
  id: '3',
  gasTGas: 30,
  depositYocto: '1000000000000000000000000',
};

const publicKey = PublicKey.fromString(`secp256k1:${baseEncode(Buffer.from(publicKeyHex, 'hex'))}`);
const tx = createTransaction(
  inputs.signerId,
  publicKey,
  inputs.receiverId,
  BigInt(inputs.nonce),
  [actionCreators.functionCall(inputs.methodName, { id: inputs.id }, BigInt(inputs.gasTGas) * 10n ** 12n, BigInt(inputs.depositYocto))],
  Buffer.from(inputs.blockHashHex, 'hex'),
);
const unsigned = encodeTransaction(tx);

console.log(JSON.stringify({
  inputs,
  expectedUnsignedHex: Buffer.from(unsigned).toString('hex'),
  expectedDigestHex: createHash('sha256').update(unsigned).digest('hex'),
}, null, 2));
