// Keyring agent API — the message bus between the agent and the iOS app.
//
// It is read-only with respect to the chain: it reads the policy contract, builds the
// *unsigned* approve/reject transaction, and broadcasts the signed transaction the app
// returns. It never sees the card key or the PIN.
//
//   node api/server.mjs
//   API_PORT=8787 API_HOST=0.0.0.0 API_TOKEN=dev-token node api/server.mjs
//
// The agent can POST /api/agent/notify { "id": "3" } after a pending spend; the server
// verifies the id on-chain before it broadcasts anything to clients.

import http from 'node:http';
import { randomUUID, createHash } from 'node:crypto';
import {
  actionCreators,
  createTransaction,
  encodeTransaction,
  Signature,
  SignedTransaction,
} from '@near-js/transactions';
import { PublicKey } from '@near-js/crypto';
import { baseDecode } from '@near-js/utils';
import { secp256k1 } from '@noble/curves/secp256k1';
import { ACCOUNT, RPC, rpc, view } from '../scripts/near.mjs';

const PORT = Number(process.env.API_PORT ?? 8787);
const HOST = process.env.API_HOST ?? '0.0.0.0';
const TOKEN = process.env.API_TOKEN ?? '';
const TGAS = 10n ** 12n;
const TX_TTL_MS = 5 * 60 * 1000;

/** txId -> { tx, hash, action, id, expiresAt } */
const prepared = new Map();
/** pending ids already announced to SSE clients */
const announced = new Set();
/** SSE clients: { res, timer } */
const clients = new Set();

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

function cachedView(method, ttlMs, args = {}) {
  const hit = cache.get(method);
  if (hit && Date.now() - hit.at < ttlMs) return hit.promise;
  rpcCalls += 1;
  const entry = { at: Date.now(), promise: view(method, args) };
  cache.set(method, entry);
  entry.promise.catch(() => {
    if (cache.get(method) === entry) cache.delete(method);
  });
  return entry.promise;
}

function freshView(method, args = {}) {
  rpcCalls += 1;
  return view(method, args);
}

async function pendingList({ fresh = false } = {}) {
  const list = fresh ? await freshView('get_pending') : await cachedView('get_pending', 3000);
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

function broadcast(event, data) {
  const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const client of clients) {
    try {
      client.res.write(frame);
    } catch {
      clients.delete(client);
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Chain reads

async function context() {
  const [policy, budget, keys, pending] = await Promise.all([
    cachedView('get_policy', 60_000),
    cachedView('get_budget', 3000),
    cachedView('get_keys', 60_000),
    pendingList(),
  ]);
  const approver = PublicKey.fromString(keys.approver_key);
  return {
    account: ACCOUNT,
    rpc: RPC,
    policy: {
      perTxMaxNear: formatNear(policy.per_tx_max),
      dailyMaxNear: formatNear(policy.daily_max),
      allowlist: policy.allowlist ?? [],
    },
    budget: {
      spentTodayNear: formatNear(budget.spent_today),
      remainingTodayNear: formatNear(budget.remaining_today),
    },
    approverKey: keys.approver_key,
    approverKeyHex: Buffer.from(approver.data).toString('hex'),
    agentKey: keys.agent_key,
    pendingCount: pending.length,
  };
}

async function prepareTx(action, id) {
  if (action !== 'approve' && action !== 'reject') {
    throw httpError(400, 'action must be approve or reject');
  }
  // Read fresh: the human is about to sign this exact request.
  const pending = await pendingList({ fresh: true });
  const item = pending.find((p) => p.id === String(id));
  if (!item) throw httpError(404, `pending spend ${id} not found`);

  const keys = await cachedView('get_keys', 60_000);
  const publicKey = PublicKey.fromString(keys.approver_key);
  const ak = await rpc('query', {
    request_type: 'view_access_key',
    finality: 'final',
    account_id: ACCOUNT,
    public_key: publicKey.toString(),
  });

  const tx = createTransaction(
    ACCOUNT,
    publicKey,
    ACCOUNT,
    BigInt(ak.nonce) + 1n,
    [actionCreators.functionCall(action, { id: String(id) }, 30n * TGAS, 0n)],
    baseDecode(ak.block_hash),
  );
  const hash = createHash('sha256').update(encodeTransaction(tx)).digest();
  const txId = randomUUID();
  prepared.set(txId, {
    tx,
    hash,
    action,
    id: String(id),
    expiresAt: Date.now() + TX_TTL_MS,
  });

  return {
    txId,
    hashHex: hash.toString('hex'),
    action,
    id: String(id),
    pending: item,
    expiresAt: Date.now() + TX_TTL_MS,
    // The app only needs the hash to sign. It should show `pending` as the intent.
    signer: keys.approver_key,
  };
}

async function submitTx(txId, signatureHex) {
  const entry = prepared.get(txId);
  if (!entry) throw httpError(410, 'prepared transaction not found or already used');
  if (Date.now() > entry.expiresAt) {
    prepared.delete(txId);
    throw httpError(410, 'prepared transaction expired');
  }

  const sig = Buffer.from(String(signatureHex ?? ''), 'hex');
  if (sig.length !== 64) throw httpError(400, 'signature must be 64 bytes (r‖s)');

  const pub = Buffer.from(entry.tx.publicKey.data);
  let v = null;
  for (let candidate = 0; candidate < 2; candidate++) {
    const recovered = secp256k1.Signature.fromCompact(sig)
      .addRecoveryBit(candidate)
      .recoverPublicKey(entry.hash)
      .toRawBytes(false)
      .subarray(1);
    if (Buffer.from(recovered).equals(pub)) {
      v = candidate;
      break;
    }
  }
  if (v === null) throw httpError(400, 'signature does not recover the approver key');

  const signed = new SignedTransaction({
    transaction: entry.tx,
    signature: new Signature({ keyType: 1, data: Buffer.concat([sig, Buffer.from([v])]) }),
  });

  const result = await rpc('broadcast_tx_commit', [
    Buffer.from(signed.encode()).toString('base64'),
  ]);
  prepared.delete(txId);
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
    return sendJson(res, 200, { ok: true, account: ACCOUNT, rpc: RPC, rpcCalls });
  }

  if (!authorized(req, url)) {
    return sendJson(res, 401, { error: 'unauthorized' });
  }

  if (req.method === 'GET' && url.pathname === '/api/context') {
    return sendJson(res, 200, await context());
  }

  if (req.method === 'GET' && url.pathname === '/api/pending') {
    return sendJson(res, 200, { account: ACCOUNT, pending: await pendingList() });
  }

  if (req.method === 'GET' && url.pathname.startsWith('/api/pending/')) {
    const id = decodeURIComponent(url.pathname.slice('/api/pending/'.length));
    const item = (await pendingList()).find((p) => p.id === id);
    if (!item) return sendJson(res, 404, { error: `pending spend ${id} not found` });
    return sendJson(res, 200, item);
  }

  // Server-Sent Events: a new pending spend, or a snapshot on connect.
  if (req.method === 'GET' && url.pathname === '/api/events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-store',
      connection: 'keep-alive',
      'access-control-allow-origin': '*',
    });
    res.write(`event: snapshot\ndata: ${JSON.stringify(await pendingList())}\n\n`);
    const client = { res };
    clients.add(client);
    req.on('close', () => clients.delete(client));
    return;
  }

  // The agent's hint. The server verifies against the chain before broadcasting.
  if (req.method === 'POST' && url.pathname === '/api/agent/notify') {
    const body = await readBody(req);
    if (body.id === undefined) return sendJson(res, 400, { error: 'id is required' });
    const item = (await pendingList({ fresh: true })).find((p) => p.id === String(body.id));
    if (!item) return sendJson(res, 404, { error: `pending spend ${body.id} not found` });
    announced.add(item.id);
    broadcast('pending', item);
    return sendJson(res, 200, { ok: true, pending: item });
  }

  // Prepare an unsigned approve/reject transaction; the app signs the returned hash.
  if (req.method === 'POST' && url.pathname.startsWith('/api/tx/')) {
    const parts = url.pathname.split('/').filter(Boolean); // api, tx, ...
    if (parts[2] === 'submit') {
      const body = await readBody(req);
      if (!body.txId || !body.signatureHex) {
        return sendJson(res, 400, { error: 'txId and signatureHex are required' });
      }
      return sendJson(res, 200, await submitTx(body.txId, body.signatureHex));
    }
    const action = parts[2];
    const id = parts[3];
    if (!action || id === undefined) return sendJson(res, 404, { error: 'not found' });
    return sendJson(res, 200, await prepareTx(action, id));
  }

  return sendJson(res, 404, { error: 'not found' });
}

// ---------------------------------------------------------------------------------------------
// One poller for every connected client: at most one chain read per tick, none while idle.
setInterval(async () => {
  if (clients.size === 0) return;
  try {
    for (const item of await pendingList()) {
      if (!announced.has(item.id)) {
        announced.add(item.id);
        broadcast('pending', item);
      }
    }
  } catch {
    // Keep serving; the next tick retries.
  }
}, 5000);

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

async function seed() {
  try {
    const list = await pendingList();
    for (const item of list) announced.add(item.id);
  } catch (err) {
    console.warn(`[api] could not seed pending list: ${err.message}`);
  }
}

await seed();
server.listen(PORT, HOST, () => {
  console.log(`[api] listening on http://${HOST}:${PORT}`);
  console.log(`[api] account ${ACCOUNT} via ${RPC}`);
  if (TOKEN) console.log('[api] API_TOKEN is set; clients must send Authorization: Bearer <token>');
});
