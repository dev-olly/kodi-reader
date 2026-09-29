// Local integration harness: real Paddle sandbox + disposable local PostgreSQL.
// No Supabase credentials, AI keys, or production database are accepted.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { Environment, LogLevel, Paddle } from '@paddle/paddle-node-sdk';
import { createPaddle } from '../../../kodi-reader-ai/src/paddle.js';
import { ServiceError } from '../../../kodi-reader-ai/src/auth.js';

const root = new URL('../../', import.meta.url);
const file = name => new URL(`.build/${name}`, root);
const readJSON = async name => JSON.parse(await readFile(file(name), 'utf8'));
const saveJSON = (name, data) => writeFile(file(name), JSON.stringify(data, null, 2) + '\n', { mode: 0o600 });
const requireBackend = createRequire(new URL('../../../kodi-reader-ai/package.json', import.meta.url));
const { Client, Pool } = requireBackend('pg');
const connection = { host: '127.0.0.1', port: 55439, user: 'kodi_sandbox', database: 'postgres' };
const key = (await readFile(file('paddle-sandbox.key'), 'utf8')).trim();
if (!key.startsWith('pdl_sdbx_apikey_')) throw new Error('Only a sandbox API key is accepted.');
const sdk = new Paddle(key, { environment: Environment.sandbox, logLevel: LogLevel.none });
const catalog = await readJSON('paddle-sandbox-catalog.json');
if (!catalog.test_only || catalog.environment !== 'sandbox') throw new Error('Only the verified sandbox catalog is accepted.');
const collect = async items => { const result = []; for await (const item of items) result.push(item); return result; };

function service(pool, settings) {
  const credits = { call: async (action, user = null, id = null, data = {}) => {
    try {
      return (await pool.query('select public.kodi_credits($1,$2,$3,$4) as result', [action, user, id, data])).rows[0].result;
    } catch (error) {
      const errors = {
        insufficient_credits: [402, 'You have no test credits left. Buy a sandbox pack to continue.'],
        request_already_used: [409, 'This question was already submitted. Start a new request.'],
        idempotency_conflict: [409, 'This request ID was already used.'],
        account_deleted: [401, 'Please sign in again.'],
      };
      if (errors[error.message]) throw new ServiceError(errors[error.message][0], error.message, errors[error.message][1]);
      throw new ServiceError(503, 'credits_unavailable', 'Test credits are temporarily unavailable.');
    }
  } };
  const env = { CREDITS_ENFORCED: 'true', PADDLE_ENVIRONMENT: 'sandbox', PADDLE_SANDBOX_ENABLED: 'true',
    PADDLE_API_KEY: key, PADDLE_WEBHOOK_SECRET: settings.webhookSecret, PADDLE_PACKS_JSON: JSON.stringify(catalog.PADDLE_PACKS_JSON) };
  // Override only the checkout URL for this temporary local test site.
  const fetchTest = async (url, init) => {
    if (url === 'https://sandbox-api.paddle.com/transactions' && init?.method === 'POST') {
      const body = JSON.parse(init.body); body.checkout = { url: `${settings.origin}/checkout` };
      init = { ...init, body: JSON.stringify(body) };
    }
    const response = await fetch(url, init);
    if (!response.ok) {
      const problem = await response.clone().json().catch(() => ({}));
      console.log(JSON.stringify({ paddle_status: response.status,
        paddle_code: /^[a-z_]+$/.test(problem.error?.code || '') ? problem.error.code : 'unknown' }));
    }
    return response;
  };
  return { credits, paddle: createPaddle(env, credits, fetchTest) };
}

async function main() {
  const mode = process.argv[2];
  if (mode === 'serve') {
    const admin = new Client(connection); await admin.connect();
    const database = `kodi_paddle_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`create database ${database}`);
    for (const role of ['anon', 'authenticated', 'service_role'])
      await admin.query(`do $$ begin create role ${role}; exception when duplicate_object then null; end $$`);
    await admin.end();
    const pool = new Pool({ ...connection, database });
    await pool.query('create schema auth; create table auth.users(id uuid primary key)');
    await pool.query(await readFile(new URL('../../../kodi-reader-ai/migrations/001_credits.sql', import.meta.url), 'utf8'));
    const user = randomUUID(); await pool.query('insert into auth.users values($1)', [user]);
    await pool.query("select public.kodi_credits('balance',$1)", [user]);
    await saveJSON('paddle-local-test.json', { database, user, port: 55440 });
    const website = new URL('../../website/', import.meta.url);
    const staticFiles = new Map([['/checkout', 'checkout.html'], ['/checkout.js', 'checkout.js'],
      ['/privacy', 'privacy.html'], ['/purchases', 'purchases.html']]);
    const server = createServer(async (req, res) => {
      const path = new URL(req.url, 'http://localhost').pathname;
      res.setHeader('Cache-Control', 'no-store');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      try {
        if (req.method === 'GET' && path === '/checkout-config.js') {
          const settings = await readJSON('paddle-sandbox-connection.json');
          res.setHeader('Content-Type', 'application/javascript');
          res.end(`window.kodiCheckout=Object.freeze(${JSON.stringify({ enabled: true, environment: 'sandbox', clientToken: settings.clientToken })});`);
        } else if (req.method === 'GET' && staticFiles.has(path)) {
          res.setHeader('Content-Type', path.endsWith('.js') ? 'application/javascript' : 'text/html; charset=utf-8');
          res.end(await readFile(new URL(staticFiles.get(path), website)));
        } else if (req.method === 'POST' && path === '/v1/paddle/webhook') {
          const chunks = []; let size = 0;
          for await (const chunk of req) { size += chunk.length; if (size > 1000000) { res.writeHead(413).end(); return; } chunks.push(chunk); }
          const raw = Buffer.concat(chunks);
          const settings = await readJSON('paddle-sandbox-connection.json');
          const started = Date.now();
          await service(pool, settings).paddle.webhook(raw, req.headers['paddle-signature']);
          const event = JSON.parse(raw);
          const balance = (await pool.query("select public.kodi_credits('balance',$1) as result", [user])).rows[0].result;
          // Keep a signed sandbox payload privately for the duplicate-delivery check. Never log its contents.
          await writeFile(file('paddle-last-event.json'), raw, { mode: 0o600 });
          console.log(JSON.stringify({ event: event.event_type, id: event.event_id, elapsed_ms: Date.now() - started, ...balance }));
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"received":true}');
        } else { res.writeHead(404).end('Not found'); }
      } catch (error) {
        const status = Number.isInteger(error.status) ? error.status : 503;
        res.writeHead(status).end('Request could not be processed');
        console.log(JSON.stringify({ status, code: /^[a-z_]+$/.test(error.code || '') ? error.code : 'request_failed' }));
      }
    });
    server.requestTimeout = 15000;
    server.listen(55440, '127.0.0.1', () => console.log('Sandbox test server listening on 127.0.0.1:55440; local balance 25.'));
    const stop = () => server.close(async () => { await pool.end(); process.exit(0); });
    process.on('SIGTERM', stop); process.on('SIGINT', stop);
    return;
  }
  if (mode === 'connect') {
    const origin = new URL(process.argv[3]);
    if (origin.protocol !== 'https:' || !origin.hostname.endsWith('.trycloudflare.com') || origin.pathname !== '/')
      throw new Error('Expected the temporary Cloudflare HTTPS origin.');
    let token = (await collect(sdk.clientTokens.list())).find(t => t.name === 'Kodi local sandbox checkout' && t.status === 'active');
    if (!token) token = await sdk.clientTokens.create({ name: 'Kodi local sandbox checkout', description: 'Public browser token for isolated sandbox testing only' });
    const existing = (await sdk.notificationSettings.list()).filter(s => s.description === 'Kodi isolated local sandbox test');
    if (existing.length > 1) throw new Error('Multiple test destinations exist; inspect before connecting.');
    const data = { destination: `${origin.origin}/v1/paddle/webhook`, subscribedEvents: ['transaction.completed', 'adjustment.created', 'adjustment.updated'],
      includeSensitiveFields: false, trafficSource: 'all' };
    const destination = existing[0] ? await sdk.notificationSettings.update(existing[0].id, { ...data, active: true }) :
      await sdk.notificationSettings.create({ ...data, description: 'Kodi isolated local sandbox test', type: 'url' });
    if (!token.token.startsWith('test_') || !destination.endpointSecretKey) throw new Error('Sandbox connection settings incomplete.');
    await saveJSON('paddle-sandbox-connection.json', { origin: origin.origin, clientToken: token.token, clientTokenId: token.id,
      notificationId: destination.id, webhookSecret: destination.endpointSecretKey });
    console.log('Sandbox client token and signed webhook configured; credentials saved privately.');
    return;
  }
  const local = await readJSON('paddle-local-test.json');
  if (!/^kodi_paddle_[a-f0-9]{32}$/.test(local.database)) throw new Error('Invalid local test database.');
  const pool = new Pool({ ...connection, database: local.database });
  try {
    if (mode === 'checkout') {
      const settings = await readJSON('paddle-sandbox-connection.json');
      const result = await service(pool, settings).paddle.checkout(local.user, randomUUID(), process.argv[3] || 'starter');
      await saveJSON('paddle-test-checkout.json', result);
      console.log(JSON.stringify(result));
    } else if (['replay', 'refund', 'payment-status'].includes(mode)) {
      const { rows } = await pool.query('select transaction_id from kodi_private.orders where transaction_id is not null order by created_at desc limit 1');
      if (!rows[0]) throw new Error('No local test transaction exists.');
      const transactionId = rows[0].transaction_id;
      const transaction = await sdk.transactions.get(transactionId);
      if (transaction.status !== 'completed') throw new Error('Test payment is not completed.');
      if (mode === 'replay') {
        const settings = await readJSON('paddle-sandbox-connection.json');
        const notifications = await collect(sdk.notifications.list({ notificationSettingId: [settings.notificationId], perPage: 50 }));
        const notification = notifications.find(n => n.origin === 'event' && n.type === 'transaction.completed' && n.payload?.data?.id === transactionId);
        if (!notification) throw new Error('Payment notification not yet available.');
        const replay = await sdk.notifications.replay(notification.id);
        console.log(JSON.stringify({ replay_requested: true, notification_id: notification.id, replay_id: replay.notificationId }));
      } else {
        let adjustments = await collect(sdk.adjustments.list({ transactionId: [transactionId], perPage: 50 }));
        if (mode === 'refund' && adjustments.length === 0) {
          adjustments = [await sdk.adjustments.create({ transactionId, action: 'refund', type: 'full',
            reason: 'Automated Kodi sandbox integration test — no real payment' })];
        }
        console.log(JSON.stringify({ transaction: transactionId, status: transaction.status,
          adjustments: adjustments.map(a => ({ id: a.id, status: a.status, action: a.action })) }, null, 2));
      }
    } else if (mode === 'verify-refund') {
      const balance = await service(pool, await readJSON('paddle-sandbox-connection.json')).credits.call('balance', local.user);
      assert.deepEqual(balance, { balance: 25, debt: 0 }, 'Approved refund must restore only the welcome allowance.');
      const ledger = (await pool.query('select kind,delta from kodi_private.ledger where account_id=$1 order by created_at', [local.user])).rows;
      assert.equal(ledger.filter(row => row.kind === 'welcome').length, 1);
      assert.equal(ledger.filter(row => row.kind === 'payment' && row.delta === 250).length, 1);
      assert.equal(ledger.filter(row => row.kind === 'payment' && row.delta === -250).length, 1);
      assert.equal(ledger.reduce((sum, row) => sum + row.delta, 0), 25);
      const rows = (await pool.query('select applied from kodi_private.orders where transaction_id is not null')).rows;
      assert.equal(rows.length, 1); assert.equal(rows[0].applied, 0);
      console.log('PASS: one welcome grant, one 250-credit purchase, one 250-credit refund, final balance 25, no debt or duplicate grants.');
    } else if (mode === 'provider-status') {
      const transactions = await collect(sdk.transactions.list({ perPage: 30 }));
      console.log(JSON.stringify(transactions.map(t => ({ id: t.id, status: t.status, kodi_order_id: t.customData?.kodi_order_id })), null, 2));
    } else if (mode === 'status') {
      const balances = await pool.query('select balance from kodi_private.accounts');
      const orders = await pool.query('select pack,credits,amount,transaction_id,applied,needs_review from kodi_private.orders order by created_at');
      const ledger = await pool.query('select kind,delta from kodi_private.ledger order by created_at');
      console.log(JSON.stringify({ balances: balances.rows, orders: orders.rows, ledger: ledger.rows }, null, 2));
    } else if (mode === 'disconnect') {
      const settings = await readJSON('paddle-sandbox-connection.json');
      await sdk.notificationSettings.update(settings.notificationId, { active: false });
      console.log('Temporary sandbox notification destination disabled.');
    } else throw new Error('Use serve, connect <origin>, checkout [pack], status, or disconnect.');
  } finally { await pool.end(); }
}
export { service, readJSON, connection, Pool };

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(error => {
  console.error(`Sandbox integration stopped (${typeof error.code === 'string' && /^[a-zA-Z0-9_]+$/.test(error.code) ? error.code : 'request_failed'}). No production resources were used.`);
  process.exitCode = 1;
});
