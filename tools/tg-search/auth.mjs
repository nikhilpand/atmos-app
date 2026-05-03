/**
 * tg-search: One-time Telegram authentication
 * 
 * Run once: node auth.mjs
 * Creates a session file that persists across runs.
 * 
 * Get API credentials from: https://my.telegram.org/apps
 */

import { TelegramClient } from 'telegram';
import { StringSession } from 'telegram/sessions/index.js';
import { createInterface } from 'readline';
import { writeFileSync, readFileSync, existsSync } from 'fs';

const SESSION_FILE = new URL('./session.txt', import.meta.url).pathname;
const CONFIG_FILE = new URL('./config.json', import.meta.url).pathname;

function ask(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => rl.question(question, ans => { rl.close(); resolve(ans.trim()); }));
}

async function main() {
  console.log('╔══════════════════════════════════════════╗');
  console.log('║   Telegram Auth — One-time Setup         ║');
  console.log('║   Get credentials: my.telegram.org/apps  ║');
  console.log('╚══════════════════════════════════════════╝');
  console.log('');

  let config = {};
  if (existsSync(CONFIG_FILE)) {
    config = JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
    console.log(`Loaded existing config (API ID: ${config.apiId})`);
  }

  const apiId = config.apiId || parseInt(await ask('API ID: '));
  const apiHash = config.apiHash || await ask('API Hash: ');

  // Save config
  writeFileSync(CONFIG_FILE, JSON.stringify({ apiId, apiHash }, null, 2));
  console.log('Config saved.\n');

  // Load existing session or create new
  const savedSession = existsSync(SESSION_FILE) ? readFileSync(SESSION_FILE, 'utf-8').trim() : '';
  const session = new StringSession(savedSession);

  const client = new TelegramClient(session, apiId, apiHash, {
    connectionRetries: 5,
  });

  await client.start({
    phoneNumber: async () => await ask('Phone (with country code, e.g. +91...): '),
    password: async () => await ask('2FA Password (if enabled): '),
    phoneCode: async () => await ask('Code from Telegram: '),
    onError: (err) => console.error('Auth error:', err.message),
  });

  // Save session string
  const sessionString = client.session.save();
  writeFileSync(SESSION_FILE, sessionString);

  const me = await client.getMe();
  console.log(`\n✅ Logged in as ${me.firstName} (@${me.username || 'no-username'})`);
  console.log(`Session saved to ${SESSION_FILE}`);
  console.log('\nYou can now use: node search.mjs "Game of Thrones S01"');

  await client.disconnect();
}

main().catch(console.error);
