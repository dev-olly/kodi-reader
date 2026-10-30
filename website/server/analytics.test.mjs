import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createDashboardHandler, createEventsHandler, validateBatch, requireAdmin,
  parseDays, getPeriod, readBoundedJSON, MAX_BODY_BYTES, storageConfiguration, requestCountry,
} from './analytics.mjs';

const now = new Date('2026-10-24T14:30:00Z');
const env = {
  ANALYTICS_ADMIN_TOKEN: '12345678901234567890123456789012',
  ANALYTICS_SUPABASE_URL: 'https://example.supabase.co',
  ANALYTICS_SUPABASE_SERVICE_KEY: 'sb_secret_testing_only_1234567890',
};
function event(overrides = {}) {
  return {
    id: '47f6acae-e80d-4d16-a4c6-500000000001',
    installation_id: '47f6acae-e80d-4d16-a4c6-500000000002',
    session_id: '47f6acae-e80d-4d16-a4c6-500000000003',
    occurred_at: now.toISOString(), name: 'app_active',
    properties: { platform: 'macOS', version: '0.4.0', build: '27' },
    ...overrides,
  };
}
const post = body => new Request('https://www.kodi-reader.app/api/analytics/events', {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
});
const admin = (token = env.ANALYTICS_ADMIN_TOKEN, query = '?days=30') => new Request(`https://www.kodi-reader.app/api/analytics/dashboard${query}`, {
  headers: { Authorization: `Bearer ${token}` },
});

test('native-shaped payloads accept known feature and error enums and deduplicate UUIDs', () => {
  const value = event({ id: event().id.toUpperCase(), name: 'reading_heartbeat', duration_seconds: 60 });
  assert.equal(validateBatch({ events: [value, value] }, now).length, 1);
  assert.equal(validateBatch({ events: [value] }, now)[0].id, value.id.toLowerCase());
  for (const category of ['network', 'authentication', 'credits', 'service', 'rate_limit', 'provider', 'cancelled', 'unknown']) {
    assert.equal(validateBatch({ events: [event({ name: 'ai_request_failed', properties: { platform: 'macOS', version: '0.4.0', build: 'unknown', error_category: category } })] }, now)[0].properties.error_category, category);
  }
});

test('v2 feature and AI events keep telemetry IDs bounded and separate from other activity', () => {
  const requestID = '47F6ACAE-E80D-4D16-A4C6-500000000005';
  for (const name of ['note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session']) {
    assert.equal(validateBatch({ events: [event({ name, properties: { schema_version: 2 } })] }, now)[0].name, name);
  }
  for (const name of ['ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled']) {
    const value = event({ name, properties: { schema_version: 2, request_id: requestID } });
    assert.equal(validateBatch({ events: [value] }, now)[0].properties.request_id, requestID.toLowerCase());
    assert.throws(() => validateBatch({ events: [event({ name, properties: { schema_version: 2 } })] }, now));
    assert.doesNotThrow(() => validateBatch({ events: [event({ name })] }, now)); // Legacy clients remain valid.
  }
  for (const properties of [{ request_id: requestID }, { schema_version: 3 }, { schema_version: '2' }, { country_code: 'US' }, { latitude: 1 }, { request_id: 'account@example.com' }]) {
    assert.throws(() => validateBatch({ events: [event({ properties })] }, now));
  }
  assert.throws(() => validateBatch({ events: [event()], country_code: 'US' }, now));
});

test('country observations use only Vercel country headers and assigned ISO codes', () => {
  const request = post({ events: [event()] });
  request.headers.set('x-vercel-ip-country', 'NG');
  request.headers.set('x-forwarded-for', '203.0.113.1');
  request.headers.set('x-vercel-ip-city', 'Private city');
  assert.equal(requestCountry(request, env), null);
  assert.equal(requestCountry(request, { ...env, VERCEL: '1' }), 'NG');
  for (const invalid of ['ZZ', 'XX', 'EU', 'USA', 'ng', 'US,NG', '', 'N1', 'US\n']) {
    if (invalid.includes('\n')) continue; // Headers itself rejects embedded newlines.
    request.headers.set('x-vercel-ip-country', invalid);
    assert.equal(requestCountry(request, { ...env, VERCEL: '1' }), null);
  }
  request.headers.delete('x-vercel-ip-country');
  assert.equal(requestCountry(request, { ...env, VERCEL: '1' }), null);
});

test('validation rejects content, emails, unexpected metadata, oversized batches, bad IDs and timing', () => {
  const invalidEvents = [
    event({ email: 'person@example.com' }), event({ properties: { title: 'Private book' } }),
    event({ properties: { version: 'person@example.com' } }), event({ id: 'email@example.com' }),
    event({ properties: { platform: 'Windows' } }), event({ name: 'unknown' }),
    event({ name: 'reading_heartbeat', duration_seconds: 61 }),
    event({ name: 'reading_heartbeat' }), event({ duration_seconds: 20 }),
    event({ name: 'reading_heartbeat', duration_seconds: 1.5 }),
    event({ occurred_at: '2026-10-24' }), event({ occurred_at: '2026-10-24T14:36:00Z' }),
    event({ occurred_at: '2026-09-31T00:00:00Z' }),
    event({ occurred_at: '2026-01-01T00:00:00Z' }),
  ];
  for (const value of invalidEvents) assert.throws(() => validateBatch({ events: [value] }, now), { status: 400 });
  assert.throws(() => validateBatch({ events: [] }, now));
  assert.throws(() => validateBatch({ events: Array(51).fill(event()) }, now));
  assert.throws(() => validateBatch({ events: [event(), event({ installation_id: '47f6acae-e80d-4d16-a4c6-500000000004' })] }, now));
});

test('streamed request bodies are bounded even without Content-Length', async () => {
  const request = new Request('https://example.com', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(MAX_BODY_BYTES + 1)); controller.close(); } }),
    duplex: 'half',
  });
  await assert.rejects(readBoundedJSON(request), { status: 413 });
  await assert.rejects(readBoundedJSON(new Request('https://example.com', { method: 'POST', body: '{}' })), { status: 415 });
});

test('admin token fails closed for absent, short, wrong, malformed and same-prefix secrets', () => {
  assert.throws(() => requireAdmin(admin(), {}), { status: 503 });
  assert.throws(() => requireAdmin(admin(), { ANALYTICS_ADMIN_TOKEN: 'short' }), { status: 503 });
  for (const value of ['', 'x', env.ANALYTICS_ADMIN_TOKEN + 'x', env.ANALYTICS_ADMIN_TOKEN.slice(0, -1)]) {
    assert.throws(() => requireAdmin(admin(value), env), { status: 401 });
  }
  assert.doesNotThrow(() => requireAdmin(admin(), env));
});

test('date periods use UTC calendar days, equal elapsed comparison and reject invalid query values', () => {
  assert.deepEqual(getPeriod(7, now), {
    start: '2026-10-18T00:00:00.000Z', end: now.toISOString(),
    previous_start: '2026-10-11T00:00:00.000Z', previous_end: '2026-10-17T14:30:00.000Z',
  });
  assert.equal(parseDays(admin()), 30);
  for (const query of ['?days=8', '?days=7&days=30', '?days=7junk', '?days=']) {
    assert.throws(() => parseDays(admin(undefined, query)), { status: 400 });
  }
});

test('storage configuration accepts only server service credentials over HTTPS', () => {
  assert.deepEqual(storageConfiguration(env), { url: env.ANALYTICS_SUPABASE_URL, key: env.ANALYTICS_SUPABASE_SERVICE_KEY });
  for (const override of [
    { ANALYTICS_SUPABASE_SERVICE_KEY: 'sb_publishable_nope' },
    { ANALYTICS_SUPABASE_URL: 'http://example.supabase.co' },
    { ANALYTICS_SUPABASE_URL: 'https://example.supabase.co/private' },
  ]) assert.throws(() => storageConfiguration({ ...env, ...override }), { status: 503 });
  const token = role => `e30.${Buffer.from(JSON.stringify({ role })).toString('base64url')}.signature`;
  assert.throws(() => storageConfiguration({ ...env, ANALYTICS_SUPABASE_SERVICE_KEY: token('anon') }));
  assert.doesNotThrow(() => storageConfiguration({ ...env, ANALYTICS_SUPABASE_SERVICE_KEY: token('service_role') }));
});

test('ingestion stores once via RPC without IP, arbitrary request headers or content', async () => {
  let called = 0;
  const handler = createEventsHandler({ env, now: () => now, fetchImpl: async (url, options) => {
    called++;
    assert.equal(url, `${env.ANALYTICS_SUPABASE_URL}/rest/v1/rpc/analytics_ingest`);
    assert.equal(options.headers.apikey, env.ANALYTICS_SUPABASE_SERVICE_KEY);
    assert.equal(options.headers.Authorization, undefined);
    const payload = JSON.parse(options.body);
    assert.equal(payload.p_events.length, 1);
    assert.equal(payload.p_country_code, null);
    assert.equal(options.body.includes('127.0.0.1'), false);
    return Response.json({ stored: 1, rate_limited: false });
  } });
  const request = post({ events: [event(), event()] });
  request.headers.set('X-Forwarded-For', '127.0.0.1');
  const response = await handler(request);
  assert.equal(response.status, 202);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { accepted: 1, stored: 1, duplicates: 0 });
  assert.equal(called, 1);
});

test('hosted ingestion forwards only the country observation alongside the validated event batch', async () => {
  let payload;
  const handler = createEventsHandler({ env: { ...env, VERCEL: '1' }, now: () => now, fetchImpl: async (_url, options) => {
    payload = JSON.parse(options.body);
    return Response.json({ stored: 1, rate_limited: false });
  } });
  const request = post({ events: [event()] });
  request.headers.set('x-vercel-ip-country', 'DE');
  request.headers.set('x-vercel-ip-city', 'Berlin');
  request.headers.set('x-vercel-ip-latitude', '52.5');
  request.headers.set('x-forwarded-for', '203.0.113.1');
  assert.equal((await handler(request)).status, 202);
  assert.deepEqual(Object.keys(payload).sort(), ['p_country_code', 'p_events']);
  assert.equal(payload.p_country_code, 'DE');
  for (const sensitive of ['Berlin', '52.5', '203.0.113.1', 'x-forwarded-for', 'x-vercel-ip']) assert.equal(JSON.stringify(payload).includes(sensitive), false);
});

test('rate limits are retryable and storage outages never expose upstream content', async () => {
  const rateLimited = createEventsHandler({ env, now: () => now, fetchImpl: async () => Response.json({ stored: 0, rate_limited: true }) });
  const response = await rateLimited(post({ events: [event()] }));
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('retry-after'), '60');
  const unavailable = createEventsHandler({ env, now: () => now, fetchImpl: async () => new Response('secret upstream SQL detail', { status: 500 }) });
  const failure = await unavailable(post({ events: [event()] }));
  assert.equal(failure.status, 503);
  assert.equal((await failure.text()).includes('secret'), false);
  const malformed = createEventsHandler({ env, now: () => now, fetchImpl: async () => Response.json({}) });
  assert.equal((await malformed(post({ events: [event()] }))).status, 503);
});

test('dashboard checks authorization before storage and returns aggregate JSON without caching', async () => {
  let called = 0;
  const aggregate = { days: 7, daily: [], summary: { active_users: { value: 0, previous: 0 } } };
  const handler = createDashboardHandler({ env, fetchImpl: async (_url, options) => {
    called++;
    assert.deepEqual(JSON.parse(options.body), { p_days: 7 });
    return Response.json(aggregate);
  } });
  assert.equal((await handler(admin('wrong', '?days=7'))).status, 401);
  assert.equal(called, 0);
  const response = await handler(admin(undefined, '?days=7'));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), aggregate);
  assert.equal(called, 1);
  assert.equal((await handler(post({}))).status, 405);
});
