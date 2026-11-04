// Reference values for the app's Bip39.swift, from @scure/bip39 (the library the Keyring mobile
// wallet uses). Set BIP39_REF to the directory of a package.json that has @scure/bip39 installed.
//   node ios-app/tests/bip39/vector.mjs > vector.json

import { createRequire } from 'node:module';
import path from 'node:path';

const ref = process.env.BIP39_REF ?? '/Users/kaichaosun/github/keyring-so/keyring-mobile';
const require = createRequire(path.join(ref, 'package.json'));
const { entropyToMnemonic, mnemonicToSeedSync } = require('@scure/bip39');
const { wordlist } = require('@scure/bip39/wordlists/english');

const entropies = [
  Buffer.alloc(16, 0x00),
  Buffer.alloc(16, 0x7f),
  Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex'),
  Buffer.from('ffffffffffffffffffffffffffffffff', 'hex'),
];

const vectors = entropies.map((entropy) => {
  const words = entropyToMnemonic(entropy, wordlist).split(' ');
  return {
    entropyHex: entropy.toString('hex'),
    words,
    seedHex: Buffer.from(mnemonicToSeedSync(words.join(' '), '')).toString('hex'),
  };
});

console.log(JSON.stringify({ vectors }, null, 2));
