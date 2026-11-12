#!/usr/bin/env node
// keyring-agent-skills
//
//   npx keyring-agent-skills init     create the agent key, pair with the app, install the skill/MCP config
//   npx keyring-agent-skills status   show the paired account and policy
//   npx keyring-agent-skills install  install the skill/MCP config only
//
// The agent gets a spending capability (request_spend / pending / budget). The card remains the approver.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { KeyPair } from '@near-js/crypto';

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const serverPath = path.join(packageRoot, 'mcp', 'server.mjs');
const skillSource = path.join(packageRoot, 'skills', 'keyring-agent', 'SKILL.md');

const cwd = process.cwd();
const keyringDir = path.join(cwd, '.keyring');
const keyFile = path.join(keyringDir, 'agent-key.json');
const configFile = path.join(keyringDir, 'config.json');

const args = process.argv.slice(2);
const command = args.find((a) => !a.startsWith('--')) ?? 'init';
const flag = (name, fallback = null) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 && args[index + 1] && !args[index + 1].startsWith('--')
    ? args[index + 1]
    : fallback;
};
const has = (name) => args.includes(`--${name}`);

const API_URL = flag('api', process.env.API_URL ?? 'http://127.0.0.1:8787').replace(/\/$/, '');
const AGENT = flag('agent', 'opencode'); // opencode | claude | both | print

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function writeJson(file, value, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, JSON.stringify(value, null, 2), { mode });
}

function ensureAgentKey() {
  const existing = readJson(keyFile);
  if (existing?.secret_key) return KeyPair.fromString(existing.secret_key);
  fs.mkdirSync(keyringDir, { recursive: true, mode: 0o700 });
  const keyPair = KeyPair.fromRandom('ed25519');
  writeJson(keyFile, {
    secret_key: keyPair.toString(),
    public_key: keyPair.getPublicKey().toString(),
  });
  console.log(`agent key    ${keyFile}`);
  return keyPair;
}

function mcpConfig(account, contractId) {
  return {
    mcp: {
      servers: {
        keyring: {
          type: 'local',
          command: ['node', serverPath],
          cwd,
          environment: {
            NEAR_ACCOUNT: account,
            POLICY_ACCOUNT: contractId,
            HUB_AGENT_KEY_FILE: keyFile,
            API_URL,
          },
        },
      },
    },
  };
}

function claudeConfig(account, contractId) {
  return {
    mcpServers: {
      keyring: {
        command: 'node',
        args: [serverPath],
        env: {
          NEAR_ACCOUNT: account,
          POLICY_ACCOUNT: contractId,
          HUB_AGENT_KEY_FILE: keyFile,
          API_URL,
        },
      },
    },
  };
}

function installSkill(target) {
  const dir = target === 'claude'
    ? path.join(os.homedir(), '.claude', 'skills', 'keyring-agent')
    : path.join(cwd, '.opencode', 'skills', 'keyring-agent');
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(skillSource, path.join(dir, 'SKILL.md'));
  console.log(`skill        ${path.join(dir, 'SKILL.md')}`);
}

/// The agent key is a spending credential. Keep it out of git.
function ensureGitignore() {
  if (!fs.existsSync(path.join(cwd, '.git'))) return;
  const file = path.join(cwd, '.gitignore');
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (text.split(/\r?\n/).some((line) => line.trim().replace(/\/$/, '') === '.keyring')) return;
  const next = (text && !text.endsWith('\n') ? `${text}\n` : text) + '.keyring/\n';
  fs.writeFileSync(file, next);
  console.log('gitignore    added .keyring/');
}

function installMcp(account, contractId) {
  if (AGENT === 'print') return;

  if (AGENT === 'opencode' || AGENT === 'both') {
    const result = spawnSync('opencode', [
      'mcp', 'add', 'keyring',
      '--env', `NEAR_ACCOUNT=${account}`,
      '--env', `POLICY_ACCOUNT=${contractId}`,
      '--env', `HUB_AGENT_KEY_FILE=${keyFile}`,
      '--env', `API_URL=${API_URL}`,
      '--', 'node', serverPath,
    ], { cwd, encoding: 'utf8' });
    if (result.status === 0) {
      console.log('mcp          added to OpenCode (keyring)');
    } else {
      console.log('\nOpenCode CLI not found. Add this to opencode.jsonc:\n');
      console.log(JSON.stringify(mcpConfig(account, contractId), null, 2));
    }
  }

  if (AGENT === 'claude' || AGENT === 'both') {
    const file = path.join(cwd, '.mcp.json');
    const existing = readJson(file) ?? { mcpServers: {} };
    existing.mcpServers = existing.mcpServers ?? {};
    existing.mcpServers.keyring = claudeConfig(account, contractId).mcpServers.keyring;
    writeJson(file, existing, 0o644);
    console.log(`mcp          ${file}`);
  }
}

async function api(pathname, options = {}) {
  const response = await fetch(`${API_URL}${pathname}`, {
    ...options,
    headers: { 'content-type': 'application/json', ...(options.headers ?? {}) },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
  return body;
}

async function waitForPair(code) {
  let completed = null;
  let misses = 0;
  let lastError = null;
  for (let i = 0; i < 300; i++) {
    await sleep(2000);
    let status;
    try {
      status = await api(`/api/pair/${encodeURIComponent(code)}`);
      misses = 0;
    } catch (error) {
      lastError = error;
      misses += 1;
      // The API may be restarting; the in-memory code is gone after a restart.
      if (String(error.message).includes('not found') || misses >= 5) break;
      continue;
    }
    if (status.paired && status.account) {
      completed = status;
      break;
    }
  }
  if (!completed) {
    throw new Error(
      lastError
        ? `pairing interrupted (${lastError.message}); run init again`
        : 'pairing timed out; run init again',
    );
  }
  return completed;
}

function finalize(completed, contractId) {
  const config = {
    account: completed.account,
    contractId: completed.contractId ?? contractId ?? 'keyring-policy-1105.testnet',
    api: API_URL,
    agentKeyFile: keyFile,
    pairedAt: new Date().toISOString(),
  };
  writeJson(configFile, config);
  console.log(`paired       ${config.account}`);
  console.log(`config       ${configFile}`);

  installSkill(AGENT === 'claude' ? 'claude' : 'opencode');
  installMcp(config.account, config.contractId);

  console.log('');
  console.log('Ready. Start a new agent session in this repo and ask it to pay something.');
  console.log('The agent can call request_spend/pending/budget; the card approves over-limit payments.');
}

/// Creates the agent key and a pairing session. Prints the code the user enters in the app.
async function startPair() {
  const agent = ensureAgentKey();
  ensureGitignore();
  const publicKey = agent.getPublicKey().toString();

  const pair = await api('/api/pair', {
    method: 'POST',
    body: JSON.stringify({ agentPublicKey: publicKey }),
  });

  if (has('json')) {
    console.log(JSON.stringify({
      agentPublicKey: publicKey,
      code: pair.code,
      url: pair.url,
      contractId: pair.contractId,
      policy: pair.policy,
    }, null, 2));
    return pair;
  }

  console.log(`agent        ${publicKey}`);
  console.log('');
  console.log('  Pairing code: ' + pair.code);
  console.log('  Link:         ' + pair.url);
  console.log('');
  console.log('  Open the Keyring app → Pair agent → enter the code.');
  console.log(has('no-wait') ? '  Then run: npx keyring-agent-skills finish --code ' + pair.code : '  Waiting for approval…');
  console.log('');
  return pair;
}

async function init() {
  const existing = readJson(configFile);
  if (existing && !has('force')) {
    console.log(`already paired: ${existing.account}`);
    console.log(`config:         ${configFile}`);
    installSkill(AGENT === 'claude' ? 'claude' : 'opencode');
    installMcp(existing.account, existing.contractId);
    return;
  }

  const pair = await startPair();
  if (has('no-wait')) return;
  finalize(await waitForPair(pair.code), pair.contractId);
}

/// Completes a pairing started with `init --no-wait`.
async function finish() {
  const code = flag('code');
  if (!code) throw new Error('--code is required (the pairing code printed by init)');
  const status = await api(`/api/pair/${encodeURIComponent(code.toUpperCase())}`);
  const completed = status.paired ? status : await waitForPair(code);
  finalize(completed, completed.contractId);
}

async function status() {
  const config = readJson(configFile);
  if (!config) {
    console.log('not paired; run: npx keyring-agent-skills init');
    process.exitCode = 1;
    return;
  }
  const view = await api('/api/context', {
    headers: { 'X-User-Account': config.account },
  });
  console.log(JSON.stringify({ config, view }, null, 2));
}

/// Installs the skill. The MCP entry needs a paired account, so it is added by init/finish.
async function install() {
  const config = readJson(configFile);
  installSkill(AGENT === 'claude' ? 'claude' : 'opencode');
  if (!config) {
    console.log('');
    console.log('Skill installed. No agent account yet.');
    console.log('Start a new agent session in this repo and say: init my keyring agent account');
    console.log('(or run: npx keyring-agent-skills init).');
    return;
  }
  installMcp(config.account, config.contractId);
}

try {
  if (command === 'init') await init();
  else if (command === 'finish') await finish();
  else if (command === 'status') await status();
  else if (command === 'install') await install();
  else {
    console.error('usage: keyring-agent-skills init|finish|status|install [--api URL] [--agent opencode|claude|both|print] [--code CODE] [--no-wait] [--json] [--force]');
    process.exitCode = 2;
  }
} catch (error) {
  console.error(`keyring-agent-skills: ${error.message}`);
  process.exitCode = 1;
}
