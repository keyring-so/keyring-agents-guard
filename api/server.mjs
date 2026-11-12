// Keyring agent API — the message bus between the agent and the iOS app.
//
// It is a router. It reads the policy contract and hands the iOS app the nonce, block hash,
// and approver key. The app builds and signs the approve/reject transaction itself; the API
// checks the card's signature over those exact bytes and broadcasts. It never builds the
// transaction, never sees the card key or the PIN, and cannot change what was signed.
//
//   node api/server.mjs
//   API_PORT=8787 API_HOST=0.0.0.0 API_TOKEN=dev-token node api/server.mjs
//
// The agent can POST /api/agent/notify { "id": "3", "account": "…" } after a pending spend; the
// server verifies the id on-chain. The app polls; identities are per-request via X-User-Account.

import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { actionCreators } from '@near-js/transactions';
import { PublicKey } from '@near-js/crypto';
import { baseDecode, baseEncode } from '@near-js/utils';
import { secp256k1 } from '@noble/curves/secp256k1';
import {
  POLICY_ACCOUNT, SPONSOR_ACCOUNT, RPC,
  card, hubAgent, rpc, sendAt, viewAt, yocto,
} from '../scripts/near.mjs';

const { createAccount, addKey, fullAccessKey, functionCallAccessKey, transfer } = actionCreators;

const PORT = Number(process.env.API_PORT ?? 8787);
const HOST = process.env.API_HOST ?? '0.0.0.0';
const TOKEN = process.env.API_TOKEN ?? '';

// ---------------------------------------------------------------------------------------------
// Helpers

function formatNear(yocto) {
  const v = BigInt(yocto);
  const base = 10n ** 24n;
  const whole = v / base;
  let frac = (v % base).toString().padStart(24, '0').replace(/0+$/, '');
  if (frac.length > 4) frac = frac.slice(0, 4);
  return frac ? `${whole}.${frac}` : `${whole}`;
}

function normalizePending(p) {
  return {
    id: String(p.id),
    receiverId: p.receiver_id,
    amountYocto: String(p.amount),
    amountNear: formatNear(p.amount),
    memo: p.memo ?? '',
    reason: p.reason,
    requestedAt: Number(p.requested_at ?? 0),
  };
}

// Chain reads share a short cache, so many clients and polls cost one RPC call per TTL.
const cache = new Map();
let rpcCalls = 0;

function cachedCall(key, ttlMs, fn) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < ttlMs) return hit.promise;
  rpcCalls += 1;
  const entry = { at: Date.now(), promise: fn() };
  cache.set(key, entry);
  entry.promise.catch(() => {
    if (cache.get(key) === entry) cache.delete(key);
  });
  return entry.promise;
}

function freshCall(fn) {
  rpcCalls += 1;
  return fn();
}

/** The user account this request is for. The client sends X-User-Account. */
function accountOf(req, url) {
  const value = req.headers['x-user-account'] ?? url.searchParams.get('account');
  return value ? String(value) : null;
}

function requireAccount(account) {
  if (!account) throw httpError(400, 'X-User-Account header is required');
  return account;
}

/** A user's hub entry. */
function userEntry(account, { fresh = false } = {}) {
  const load = () => viewAt(POLICY_ACCOUNT, 'get_user', { account });
  return fresh ? freshCall(load) : cachedCall(`user:${account}`, 3000, load);
}

async function pendingList(account, { fresh = false } = {}) {
  const load = () => viewAt(POLICY_ACCOUNT, 'get_pending', { account });
  const list = fresh ? await freshCall(load) : await cachedCall(`pending:${account}`, 3000, load);
  return Array.isArray(list) ? list.map(normalizePending) : [];
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'authorization, content-type',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
  });
  res.end(data);
}

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

function authorized(req, url) {
  if (!TOKEN) return true;
  const header = req.headers.authorization ?? '';
  const bearer = header.startsWith('Bearer ') ? header.slice(7) : '';
  return bearer === TOKEN || url.searchParams.get('token') === TOKEN;
}

function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > limit) {
        reject(httpError(413, 'body too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!body) return resolve({});
      try {
        resolve(JSON.parse(body));
      } catch {
        reject(httpError(400, 'invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------------------------
// Chain reads

async function context(account) {
  let user;
  try {
    user = await userEntry(account);
  } catch (err) {
    if (String(err.message).includes('not registered')) {
      throw httpError(409, 'This card is not linked to the shared policy contract yet.');
    }
    throw err;
  }
  const pending = await pendingList(account);
  const accountState = await cachedCall(`account:${account}`, 3000, () => rpc('query', {
    request_type: 'view_account', finality: 'final', account_id: account,
  }));
  const approver = PublicKey.fromString(user.keys.approver_key);
  return {
    account,
    contractId: POLICY_ACCOUNT,
    rpc: RPC,
    policy: {
      perTxMaxNear: formatNear(user.policy.per_tx_max),
      dailyMaxNear: formatNear(user.policy.daily_max),
      allowlist: user.policy.allowlist ?? [],
    },
    budget: {
      spentTodayNear: formatNear(user.budget.spent_today),
      remainingTodayNear: formatNear(user.budget.remaining_today),
    },
    balanceNear: formatNear(user.balance),
    accountBalanceNear: formatNear(accountState.amount),
    paused: user.paused,
    approverKey: user.keys.approver_key,
    approverKeyHex: Buffer.from(approver.data).toString('hex'),
    agentKey: user.keys.agent_key,
    pendingCount: pending.length,
  };
}

async function prepareTx(account, action, id) {
  if (action !== 'approve' && action !== 'reject') {
    throw httpError(400, 'action must be approve or reject');
  }
  // Read fresh: the human is about to sign this exact request.
  const pending = await pendingList(account, { fresh: true });
  const item = pending.find((p) => p.id === String(id));
  if (!item) throw httpError(404, `pending spend ${id} not found`);

  const user = await userEntry(account);
  const approverKey = user.keys.approver_key;
  const ak = await rpc('query', {
    request_type: 'view_access_key',
    finality: 'final',
    account_id: account,
    public_key: approverKey,
  });

  // Routing data only. The app builds and signs the transaction itself from these fields.
  return {
    action,
    id: String(id),
    pending: item,
    signerId: account,
    receiverId: POLICY_ACCOUNT,
    publicKey: approverKey,
    nonce: (BigInt(ak.nonce) + 1n).toString(),
    blockHashHex: Buffer.from(baseDecode(ak.block_hash)).toString('hex'),
  };
}

// Routing only. The app sends the unsigned bytes it built plus the card's 64-byte signature.
// The API checks that the signature recovers the approver key over those exact bytes, appends
// the recovery byte, and broadcasts. It cannot change what was signed.
async function submitTx(account, unsignedTxBase64, signatureHex) {
  const txBytes = Buffer.from(String(unsignedTxBase64 ?? ''), 'base64');
  if (txBytes.length === 0) throw httpError(400, 'unsignedTxBase64 is required');
  const sig = Buffer.from(String(signatureHex ?? ''), 'hex');
  if (sig.length !== 64) throw httpError(400, 'signature must be 64 bytes (r‖s)');

  const hash = createHash('sha256').update(txBytes).digest();
  const user = await userEntry(account);
  const pub = Buffer.from(PublicKey.fromString(user.keys.approver_key).data);
  let v = null;
  for (let candidate = 0; candidate < 2; candidate++) {
    const recovered = secp256k1.Signature.fromCompact(sig)
      .addRecoveryBit(candidate)
      .recoverPublicKey(hash)
      .toRawBytes(false)
      .subarray(1);
    if (Buffer.from(recovered).equals(pub)) {
      v = candidate;
      break;
    }
  }
  if (v === null) throw httpError(400, 'signature does not match the approver key for these bytes');

  // SignedTransaction = transaction bytes ‖ key type (1 = secp256k1) ‖ r‖s‖v
  const signed = Buffer.concat([txBytes, Buffer.from([1]), sig, Buffer.from([v])]);
  const result = await rpc('broadcast_tx_commit', [signed.toString('base64')]);
  cache.clear();

  const failure =
    result.status?.Failure ??
    result.receipts_outcome?.map((r) => r.outcome?.status?.Failure).find(Boolean) ??
    null;

  return {
    ok: !failure,
    hash: result.transaction.hash,
    explorer: `https://testnet.nearblocks.io/txns/${result.transaction.hash}`,
    failure,
    events: result.receipts_outcome
      ?.flatMap((r) => r.outcome?.logs ?? [])
      .filter((l) => l.startsWith('EVENT_JSON:'))
      .map((l) => JSON.parse(l.slice('EVENT_JSON:'.length))) ?? [],
  };
}


// ---------------------------------------------------------------------------------------------
// Onboarding and generic broadcast

function cardKeyFromHex(hex) {
  return PublicKey.fromString(`secp256k1:${baseEncode(Buffer.from(hex, 'hex'))}`);
}

function defaultPolicy() {
  return { per_tx_max: yocto('0.5'), daily_max: yocto('1'), allowlist: ['testnet'] };
}

/** Pairing sessions: an agent asks to be attached to a card account. */
const pairs = new Map();

function createPair(agentPublicKey) {
  let parsed;
  try {
    parsed = PublicKey.fromString(agentPublicKey);
  } catch {
    throw httpError(400, 'agentPublicKey is invalid');
  }
  const code = randomBytes(3).toString('hex').toUpperCase();
  const pair = {
    code,
    agentPublicKey,
    agentKeyHex: Buffer.from(parsed.data).toString('hex'),
    agentKeyType: agentPublicKey.startsWith('ed25519:') ? 0 : 1,
    // Display-only: the hub's default policy for a new account. A paired agent cannot choose
    // its own limits; the app shows what the account will actually have.
    policy: defaultPolicy(),
    createdAt: Date.now(),
    account: null,
    paired: false,
  };
  pairs.set(code, pair);
  return { ...pair, url: `keyring-agent://pair?code=${code}`, contractId: POLICY_ACCOUNT };
}

function getPair(code) {
  const pair = pairs.get(String(code).toUpperCase());
  if (!pair) throw httpError(404, 'pairing code not found');
  return pair;
}

/** True when an access key is a function-call key on the hub that may call request_spend. */
function isSpendKey(accessKey) {
  const permission = accessKey?.permission;
  const functionCall = permission && typeof permission === 'object' ? permission.FunctionCall : null;
  if (!functionCall || functionCall.receiver_id !== POLICY_ACCOUNT) return false;
  return Array.isArray(functionCall.method_names) && functionCall.method_names.includes('request_spend');
}

async function readAccessKey(account, publicKey) {
  try {
    return await freshCall(() => rpc('query', {
      request_type: 'view_access_key',
      finality: 'optimistic',
      account_id: account,
      public_key: publicKey,
    }));
  } catch {
    return null;
  }
}

/** What the app still has to do: add the account key, set the hub agent key, or nothing. */
async function pairKeyStatus(account, agentPublicKey) {
  const accessKey = await readAccessKey(account, agentPublicKey);
  const accountKey = Boolean(accessKey?.nonce) && isSpendKey(accessKey);
  let agentKey = false;
  try {
    const user = await viewAt(POLICY_ACCOUNT, 'get_user', { account });
    agentKey = user?.keys?.agent_key === agentPublicKey;
  } catch {
    agentKey = false;
  }
  return { account, accountKey, agentKey, ready: accountKey && agentKey };
}

async function completePair(code, account) {
  if (!account) throw httpError(400, 'account is required');
  const pair = getPair(code);
  account = String(account);
  if (pair.paired && pair.account === account) return pair;

  // The app must have actually added this agent key to the account before the agent trusts
  // the pairing. Otherwise a guessed code could point an agent at someone else's account.
  let accessKey = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    accessKey = await readAccessKey(account, pair.agentPublicKey);
    if (accessKey?.nonce) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  if (!accessKey?.nonce) {
    throw httpError(409, 'the agent key is not on that account; add it with the card first');
  }
  if (!isSpendKey(accessKey)) {
    throw httpError(409, `the agent key must be a function-call key on ${POLICY_ACCOUNT} allowed to call request_spend`);
  }

  // The account key alone is not enough: the hub must also bind it as the agent key.
  const status = await pairKeyStatus(account, pair.agentPublicKey);
  if (!status.agentKey) {
    throw httpError(409, 'the hub has not authorized this agent key yet; run set_agent_key');
  }

  pair.account = account;
  pair.paired = true;
  pair.completedAt = Date.now();
  return pair;
}

/** What the app needs to sign register/deposit for a new user account. */
async function prepareOnboarding(account, cardPublicKeyHex) {
  const publicKey = cardKeyFromHex(cardPublicKeyHex);
  let ak;
  for (let attempt = 0; attempt < 12; attempt++) {
    try {
      ak = await rpc('query', {
        request_type: 'view_access_key',
        finality: 'optimistic',
        account_id: account,
        public_key: publicKey.toString(),
      });
      if (ak?.nonce) break;
    } catch {
      // The account or key may not be visible yet; retry briefly.
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  if (!ak?.nonce) throw httpError(502, 'the new account is not ready yet; try again');
  const agent = hubAgent.publicKey();
  return {
    account,
    publicKey: publicKey.toString(),
    signerId: account,
    receiverId: POLICY_ACCOUNT,
    nonce: (BigInt(ak.nonce) + 1n).toString(),
    blockHashHex: Buffer.from(baseDecode(ak.block_hash)).toString('hex'),
    agentKey: agent.toString(),
    agentKeyHex: Buffer.from(agent.data).toString('hex'),
    agentKeyType: 0,
    registrationFeeYocto: yocto('0.01'),
    depositYocto: yocto('1'),
    policy: defaultPolicy(),
  };
}

/** Create a fresh sub-account with the card key (full access) and the agent key (function call). */
async function sponsorAccount(cardPublicKeyHex, agentPublicKey) {
  if (!/^[0-9a-fA-F]{128}$/.test(String(cardPublicKeyHex ?? ''))) {
    throw httpError(400, 'cardPublicKeyHex must be 64 bytes of hex');
  }
  const publicKey = cardKeyFromHex(cardPublicKeyHex);
  let agent;
  try {
    agent = agentPublicKey ? PublicKey.fromString(agentPublicKey) : hubAgent.publicKey();
  } catch {
    throw httpError(400, 'agentPublicKey is invalid');
  }
  const account = `u${randomBytes(5).toString('hex')}.${SPONSOR_ACCOUNT}`;

  const result = await sendAt(SPONSOR_ACCOUNT, card, [
    createAccount(),
    addKey(publicKey, fullAccessKey()),
    addKey(agent, functionCallAccessKey(POLICY_ACCOUNT, ['request_spend'], BigInt(yocto('0.25')))),
    transfer(BigInt(yocto('2'))),
  ], account);
  if (!result.ok) throw httpError(502, `sponsor failed: ${JSON.stringify(result.failure)}`);

  const prepared = await prepareOnboarding(account, cardPublicKeyHex);
  return {
    ...prepared,
    agentKey: agent.toString(),
    agentKeyHex: Buffer.from(agent.data).toString('hex'),
  };
}

/** Assemble a signed transaction from the app's bytes and the card's r||s signature. */
function signedBytes(unsigned, signature, publicKeyString) {
  const hash = createHash('sha256').update(unsigned).digest();
  const keyType = publicKeyString.startsWith('ed25519:') ? 0 : 1;
  if (keyType === 0) return Buffer.concat([unsigned, Buffer.from([0]), signature]);

  const pub = Buffer.from(PublicKey.fromString(publicKeyString).data);
  let v = null;
  for (let candidate = 0; candidate < 2; candidate++) {
    const recovered = secp256k1.Signature.fromCompact(signature)
      .addRecoveryBit(candidate)
      .recoverPublicKey(hash)
      .toRawBytes(false)
      .subarray(1);
    if (Buffer.from(recovered).equals(pub)) {
      v = candidate;
      break;
    }
  }
  if (v === null) throw httpError(400, 'signature does not match the public key');
  return Buffer.concat([unsigned, Buffer.from([1]), signature, Buffer.from([v])]);
}

async function broadcastSigned(unsignedBase64, signatureHex, publicKeyString) {
  const unsigned = Buffer.from(String(unsignedBase64 ?? ''), 'base64');
  const sig = Buffer.from(String(signatureHex ?? ''), 'hex');
  if (unsigned.length === 0) throw httpError(400, 'unsignedTxBase64 is required');
  if (sig.length !== 64) throw httpError(400, 'signature must be 64 bytes');
  if (!publicKeyString) throw httpError(400, 'publicKey is required');

  const signed = signedBytes(unsigned, sig, publicKeyString);
  const result = await rpc('broadcast_tx_commit', [signed.toString('base64')]);
  const failure =
    result.status?.Failure ??
    result.receipts_outcome?.map((r) => r.outcome?.status?.Failure).find(Boolean) ??
    null;
  return {
    ok: !failure,
    hash: result.transaction.hash,
    explorer: `https://testnet.nearblocks.io/txns/${result.transaction.hash}`,
    failure,
  };
}

/** Testnet sponsor account; production uses a sponsor service instead. */
async function ensureSponsor() {
  try {
    await rpc('query', { request_type: 'view_account', finality: 'final', account_id: SPONSOR_ACCOUNT });
    return;
  } catch {
    // create it below
  }
  try {
    const publicKey = card.publicKey().toString();
    console.log(`[api] creating sponsor ${SPONSOR_ACCOUNT}`);
    const res = await fetch('https://helper.nearprotocol.com/account', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ newAccountId: SPONSOR_ACCOUNT, newAccountPublicKey: publicKey }),
    });
    if (!res.ok) throw new Error(await res.text());
    for (let i = 0; i < 20; i++) {
      try {
        await rpc('query', { request_type: 'view_account', finality: 'final', account_id: SPONSOR_ACCOUNT });
        return;
      } catch {
        await new Promise((r) => setTimeout(r, 500));
      }
    }
  } catch (err) {
    console.warn(`[api] sponsor setup failed: ${err.message}`);
  }
}

// ---------------------------------------------------------------------------------------------
// Routes

async function route(req, res, url) {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'authorization, content-type',
      'access-control-allow-methods': 'GET, POST, OPTIONS',
    });
    return res.end();
  }

  if (url.pathname === '/health') {
    return sendJson(res, 200, { ok: true, contract: POLICY_ACCOUNT, sponsor: SPONSOR_ACCOUNT, rpc: RPC, rpcCalls });
  }

  if (!authorized(req, url)) {
    return sendJson(res, 401, { error: 'unauthorized' });
  }

  const account = accountOf(req, url);

  if (req.method === 'GET' && url.pathname === '/api/context') {
    return sendJson(res, 200, await context(requireAccount(account)));
  }

  if (req.method === 'GET' && url.pathname === '/api/pending') {
    const user = requireAccount(account);
    return sendJson(res, 200, { account: user, contract: POLICY_ACCOUNT, pending: await pendingList(user) });
  }

  if (req.method === 'GET' && url.pathname.startsWith('/api/pending/')) {
    const id = decodeURIComponent(url.pathname.slice('/api/pending/'.length));
    const item = (await pendingList(requireAccount(account))).find((p) => p.id === id);
    if (!item) return sendJson(res, 404, { error: `pending spend ${id} not found` });
    return sendJson(res, 200, item);
  }

  // The agent's hint. The server verifies against the chain before broadcasting.
  if (req.method === 'POST' && url.pathname === '/api/agent/notify') {
    const body = await readBody(req);
    if (body.id === undefined) return sendJson(res, 400, { error: 'id is required' });
    if (!body.account) return sendJson(res, 400, { error: 'account is required' });
    const item = (await pendingList(String(body.account), { fresh: true })).find((p) => p.id === String(body.id));
    if (!item) return sendJson(res, 404, { error: `pending spend ${body.id} not found` });
    return sendJson(res, 200, { ok: true, pending: item });
  }

  // Routing: nonce, block hash, and approver key. The app builds and signs the transaction.
  if (req.method === 'POST' && url.pathname.startsWith('/api/tx/prepare/')) {
    const [action, id] = url.pathname.slice('/api/tx/prepare/'.length).split('/');
    if (!action || id === undefined) return sendJson(res, 404, { error: 'not found' });
    return sendJson(res, 200, await prepareTx(requireAccount(account), action, id));
  }

  // Routing: relays the app's signed transaction to the network.
  if (req.method === 'POST' && url.pathname === '/api/tx/submit') {
    const body = await readBody(req);
    if (!body.unsignedTxBase64 || !body.signatureHex) {
      return sendJson(res, 400, { error: 'unsignedTxBase64 and signatureHex are required' });
    }
    return sendJson(res, 200, await submitTx(requireAccount(account), body.unsignedTxBase64, body.signatureHex));
  }


  // Sponsor onboarding: create a fresh account with the card key and the agent key.
  if (req.method === 'POST' && url.pathname === '/api/onboard/sponsor') {
    const body = await readBody(req);
    return sendJson(res, 200, await sponsorAccount(body.cardPublicKeyHex, body.agentPublicKey));
  }

  // Pairing: the agent asks for a code; the app completes it with the card account.
  if (req.method === 'POST' && url.pathname === '/api/pair') {
    const body = await readBody(req);
    return sendJson(res, 200, createPair(String(body.agentPublicKey ?? '')));
  }

  if (req.method === 'GET' && url.pathname.startsWith('/api/pair/') && url.pathname.endsWith('/status')) {
    const code = url.pathname.slice('/api/pair/'.length, -'/status'.length);
    const pair = getPair(code);
    const account = requireAccount(accountOf(req, url));
    return sendJson(res, 200, await pairKeyStatus(account, pair.agentPublicKey));
  }

  if (req.method === 'POST' && url.pathname.startsWith('/api/pair/') && url.pathname.endsWith('/complete')) {
    const code = url.pathname.slice('/api/pair/'.length, -'/complete'.length);
    const body = await readBody(req);
    return sendJson(res, 200, await completePair(code, body.account));
  }

  if (req.method === 'GET' && url.pathname.startsWith('/api/pair/')) {
    const code = url.pathname.slice('/api/pair/'.length);
    return sendJson(res, 200, getPair(code));
  }

  // What the app needs to sign register and deposit for a new account.
  if (req.method === 'POST' && url.pathname === '/api/onboard/prepare') {
    const body = await readBody(req);
    if (!body.account || !body.cardPublicKeyHex) {
      return sendJson(res, 400, { error: 'account and cardPublicKeyHex are required' });
    }
    return sendJson(res, 200, await prepareOnboarding(String(body.account), body.cardPublicKeyHex));
  }

  // Generic relay for card-signed onboarding transactions.
  if (req.method === 'POST' && url.pathname === '/api/broadcast') {
    const body = await readBody(req);
    if (!body.unsignedTxBase64 || !body.signatureHex || !body.publicKey) {
      return sendJson(res, 400, { error: 'unsignedTxBase64, signatureHex and publicKey are required' });
    }
    return sendJson(res, 200, await broadcastSigned(body.unsignedTxBase64, body.signatureHex, body.publicKey));
  }

  return sendJson(res, 404, { error: 'not found' });
}

// Boot

const server = http.createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
  route(req, res, url).catch((err) => {
    const status = err.status ?? 500;
    if (status >= 500) console.error(err);
    if (!res.headersSent) sendJson(res, status, { error: err.message ?? String(err) });
    else res.end();
  });
});

await ensureSponsor();
server.listen(PORT, HOST, () => {
  console.log(`[api] listening on http://${HOST}:${PORT}`);
  console.log(`[api] hub ${POLICY_ACCOUNT}, sponsor ${SPONSOR_ACCOUNT}`);
  if (TOKEN) console.log('[api] API_TOKEN is set; clients must send Authorization: Bearer <token>');
});
