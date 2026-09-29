import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createNativeApp } from './native-adapter.mjs';
import { ServiceError } from '../../../kodi-reader-ai/src/auth.js';

test('native sandbox preserves request identity, isolates accounting, and blocks deletion', async () => {
  const forwarded = [], ledger = [], registered = [];
  const server = createNativeApp({
    baseAuth: { async authenticate(header) {
      if (!['Bearer alice', 'Bearer bob'].includes(header)) throw new ServiceError(401, 'auth_required', 'Sign in');
      return header.slice(7);
    } },
    registerUser: async user => { registered.push(user); },
    credits: { async call(action, user, id, data) {
      ledger.push({ action, user, id, data }); return { balance: 25, debt: 0 };
    } },
    paddle: { catalog: () => ({ sandbox: true, packs: [] }) },
    forward: async (url, init) => {
      forwarded.push({ url, ...init });
      return new Response('data: {"choices":[{"delta":{"content":"Test answer"}}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
    },
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(`${origin}/v1/credits`)).status, 401);
    assert.equal(forwarded.length, 0);
    const deletion = await fetch(`${origin}/v1/account`, { method: 'DELETE', headers: { authorization: 'Bearer alice' } });
    assert.equal(deletion.status, 403);
    assert.equal((await deletion.json()).error.code, 'sandbox_only');
    const ids = [randomUUID(), randomUUID()];
    await Promise.all(['alice', 'bob'].map(async (user, index) => {
      const response = await fetch(`${origin}/v1/chat/completions`, {
        method: 'POST', headers: { authorization: `Bearer ${user}`, 'content-type': 'application/json',
          'x-kodi-credit-protocol': '1', 'idempotency-key': ids[index] },
        body: JSON.stringify({ messages: [{ role: 'user', content: `Explain ${user}` }] }),
      });
      assert.equal(response.status, 200);
      assert.match(await response.text(), /\[DONE\]/);
    }));
    assert.equal(forwarded.length, 2);
    for (const item of forwarded) {
      assert.equal(item.url, 'https://kodi-reader-ai.fly.dev/v1/chat/completions');
      assert.equal(item.redirect, 'error');
      const user = item.headers.authorization.slice(7);
      assert.ok(JSON.parse(item.body).messages.some(message => message.content === `Explain ${user}`));
      assert.equal(item.headers['x-kodi-credit-protocol'], undefined);
      assert.equal(item.headers['idempotency-key'], undefined);
    }
    for (const [index, user] of ['alice', 'bob'].entries()) {
      assert.ok(registered.includes(user));
      assert.equal(ledger.filter(row => row.action === 'reserve' && row.user === user && row.id === ids[index]).length, 1);
      assert.equal(ledger.filter(row => row.action === 'settle' && row.user === user && row.id === ids[index] && row.data.charge).length, 1);
    }
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});
