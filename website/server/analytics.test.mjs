import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import {
  createDashboardHandler, createEventsHandler, validateBatch,
  parseDays, getPeriod, readBoundedJSON, MAX_BODY_BYTES, storageConfiguration, requestCountry,
} from './analytics.mjs';

const now = new Date('2026-10-24T14:30:00Z');
const env = {
  ANALYTICS_SUPABASE_URL: 'https://example.supabase.co',
  ANALYTICS_SUPABASE_SERVICE_KEY: 'sb_secret_testing_only_1234567890',
  ANALYTICS_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_testing_only_1234567890',
  ANALYTICS_ADMIN_EMAIL: 'developer.olly@gmail.com',
  ANALYTICS_SESSION_SECRET: 'testing-only-session-secret-1234567890',
};
const owner = { id: '47f6acae-e80d-4d16-a4c6-500000000006', email: env.ANALYTICS_ADMIN_EMAIL, email_confirmed_at: now.toISOString(), identities: [{ provider: 'google', identity_data: { sub: 'google-owner-sub' } }] };
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
const admin = (query = '?days=30', headers = {}) => new Request(`https://www.kodi-reader.app/api/analytics/dashboard${query}`, { headers });
function ownerRequest(query = '?days=30') {
  const sid = '47f6acae-e80d-4d16-a4c6-500000000007';
  const tokenClaims = { sub: owner.id, session_id: sid, amr: [{ method: 'oauth' }], exp: Math.floor(Date.now() / 1000) + 3600 };
  const session = { access_token: `e30.${Buffer.from(JSON.stringify(tokenClaims)).toString('base64url')}.test-signature`, refresh_token: 'test-refresh', expires_at: tokenClaims.exp, expires_in: 3600, token_type: 'bearer', user: owner };
  const markerBody = Buffer.from(JSON.stringify({ v: 1, sub: owner.id, sid, email: env.ANALYTICS_ADMIN_EMAIL, exp: Math.floor(now.getTime() / 1000) + 28800 })).toString('base64url');
  const marker = `${markerBody}.${createHmac('sha256', env.ANALYTICS_SESSION_SECRET).update(markerBody).digest('base64url')}`;
  return admin(query, { Cookie: `__Host-kodi-analytics-owner=${marker}; __Host-kodi-analytics-session=base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}` });
}

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
  for (const properties of [{ request_id: requestID }, { schema_version: 5 }, { schema_version: '2' }, { country_code: 'US' }, { latitude: 1 }, { request_id: 'account@example.com' }]) {
    assert.throws(() => validateBatch({ events: [event({ properties })] }, now));
  }
  assert.throws(() => validateBatch({ events: [event()], country_code: 'US' }, now));
});

test('v4 AI timings are bounded integer milliseconds on correlated terminal events only', () => {
  const properties = { schema_version: 4, request_id: '47f6acae-e80d-4d16-a4c6-500000000005', response_time_ms: 2300, latency_ms: 300, streaming_time_ms: 2000 };
  const timed = (name = 'ai_request_completed', changes = {}) => event({ name, properties: { ...properties, ...changes } });
  for (const name of ['ai_request_completed', 'ai_request_failed', 'ai_request_cancelled']) {
    assert.deepEqual(validateBatch({ events: [timed(name)] }, now)[0].properties, properties);
    assert.doesNotThrow(() => validateBatch({ events: [timed(name, { response_time_ms: 0, latency_ms: 0, streaming_time_ms: 0 })] }, now));
    assert.doesNotThrow(() => validateBatch({ events: [timed(name, { response_time_ms: 86400000, latency_ms: 1, streaming_time_ms: 86399999 })] }, now));
    // Invalid/overlong clocks can still emit an outcome without timing samples.
    assert.doesNotThrow(() => validateBatch({ events: [event({ name, properties: { schema_version: 4, request_id: properties.request_id } })] }, now));
  }
  for (const name of ['ai_request_failed', 'ai_request_cancelled']) {
    assert.doesNotThrow(() => validateBatch({ events: [event({ name, properties: { schema_version: 4, request_id: properties.request_id, response_time_ms: 200 } })] }, now));
  }
  for (const key of ['response_time_ms', 'latency_ms', 'streaming_time_ms']) {
    for (const value of [-1, 86400001, 0.5, '100', null, Infinity, NaN]) {
      assert.throws(() => validateBatch({ events: [timed('ai_request_completed', { [key]: value })] }, now), { status: 400 });
    }
  }
  const invalid = [
    timed('app_active'), timed('ai_request_started'), timed('reading_started'),
    timed('ai_request_completed', { schema_version: 3 }), timed('ai_request_completed', { request_id: undefined }),
    timed('ai_request_completed', { response_time_ms: undefined }),
    timed('ai_request_completed', { latency_ms: undefined }),
    timed('ai_request_failed', { streaming_time_ms: undefined }),
    timed('ai_request_completed', { response_time_ms: 2400 }),
    timed('ai_request_completed', { latency_ms: undefined, streaming_time_ms: undefined }),
    timed('ai_request_completed', { prompt: 'private question' }),
  ];
  for (const value of invalid) assert.throws(() => validateBatch({ events: [value] }, now), { status: 400 });
  assert.doesNotThrow(() => validateBatch({ events: [event({ name: 'reminder_created', properties: { schema_version: 4 } })] }, now));
});

test('collector preserves AI milliseconds and deduplicates timing retries without credentials', async () => {
  const properties = { schema_version: 4, request_id: '47F6ACAE-E80D-4D16-A4C6-500000000005', response_time_ms: 1500, latency_ms: 250, streaming_time_ms: 1250 };
  const value = event({ name: 'ai_request_completed', properties });
  let calls = 0;
  const handler = createEventsHandler({ env, now: () => now, fetchImpl: async (_url, options) => {
    calls++;
    const body = JSON.parse(options.body);
    assert.equal(body.p_events.length, 1);
    assert.deepEqual(body.p_events[0].properties, { ...properties, request_id: properties.request_id.toLowerCase() });
    return new Response(JSON.stringify({ stored: 1, rate_limited: false }));
  } });
  const response = await handler(post({ events: [value, value] }));
  assert.equal(response.status, 202);
  assert.equal(calls, 1);
  assert.deepEqual(await response.json(), { accepted: 1, stored: 1, duplicates: 0 });
});

test('v3 feature events are closed, versioned and carry only bounded audio durations', () => {
  const names = ['reminder_created', 'reminder_updated', 'reminder_completed', 'reminder_reopened', 'reminder_deleted', 'reminder_restored', 'reminder_opened', 'sketch_opened', 'sketch_deleted',
    'audio_recording_started', 'audio_recording_paused', 'audio_recording_resumed', 'audio_recording_saved', 'audio_recording_discarded', 'audio_recording_failed',
    'tts_listening_started', 'tts_listening_paused', 'tts_listening_resumed', 'tts_listening_stopped', 'tts_listening_completed', 'tts_listening_failed'];
  for (const name of names) {
    assert.equal(validateBatch({ events: [event({ name, properties: { schema_version: 3 } })] }, now)[0].name, name);
    assert.throws(() => validateBatch({ events: [event({ name })] }, now), { status: 400 });
    assert.throws(() => validateBatch({ events: [event({ name, duration_seconds: 1, properties: { schema_version: 3 } })] }, now), { status: 400 });
  }
  for (const name of ['audio_recording_heartbeat', 'tts_listening_heartbeat']) {
    for (const seconds of [1, 15, 60]) assert.equal(validateBatch({ events: [event({ name, duration_seconds: seconds, properties: { schema_version: 3 } })] }, now)[0].duration_seconds, seconds);
    for (const seconds of [undefined, 0, -1, 61, 1.5, '15']) assert.throws(() => validateBatch({ events: [event({ name, duration_seconds: seconds, properties: { schema_version: 3 } })] }, now), { status: 400 });
  }
  for (const key of ['title', 'reminder_id', 'audio_id', 'sketch_id', 'text', 'transcript', 'voice', 'waveform', 'audio_url']) {
    assert.throws(() => validateBatch({ events: [event({ name: 'audio_recording_saved', properties: { schema_version: 3, [key]: 'private' } })] }, now), { status: 400 });
  }
  assert.throws(() => validateBatch({ events: [event({ name: 'ai_request_started', properties: { schema_version: 3 } })] }, now), { status: 400 });
  assert.equal(validateBatch({ events: [event({ name: 'ai_request_started', properties: { schema_version: 3, request_id: '47f6acae-e80d-4d16-a4c6-500000000005' } })] }, now)[0].properties.schema_version, 3);
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
    event({ properties: { platform: 'unknownOS' } }), event({ name: 'unknown' }),
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

test('dashboard rejects the retired token and missing OAuth configuration before storage', async () => {
  let called = false;
  const fetchImpl = async () => { called = true; throw new Error('Must not reach storage or Auth.'); };
  const retiredToken = 'retired-test-administrator-token-1234567890';
  const handler = createDashboardHandler({ env: { ...env, ANALYTICS_ADMIN_TOKEN: retiredToken }, fetchImpl });
  for (const value of ['', 'wrong', retiredToken]) {
    const response = await handler(admin('?days=30', { Authorization: `Bearer ${value}` }));
    assert.equal(response.status, 401);
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  assert.equal((await createDashboardHandler({ env: {}, fetchImpl })(admin())).status, 503);
  assert.equal(called, false);
});

test('date periods use UTC calendar days, equal elapsed comparison and reject invalid query values', () => {
  assert.deepEqual(getPeriod(7, now), {
    start: '2026-10-18T00:00:00.000Z', end: now.toISOString(),
    previous_start: '2026-10-11T00:00:00.000Z', previous_end: '2026-10-17T14:30:00.000Z',
  });
  assert.equal(parseDays(admin()), 30);
  for (const query of ['?days=8', '?days=7&days=30', '?days=7junk', '?days=']) {
    assert.throws(() => parseDays(admin(query)), { status: 400 });
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
  const handler = createDashboardHandler({ env, now: () => now, fetchImpl: async (url, options) => {
    if (url.endsWith('/auth/v1/user')) return Response.json(owner);
    called++;
    assert.deepEqual(JSON.parse(options.body), { p_days: 7 });
    return Response.json(aggregate);
  } });
  assert.equal((await handler(admin('?days=7'))).status, 401);
  assert.equal(called, 0);
  const response = await handler(ownerRequest('?days=7'));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), aggregate);
  assert.equal(called, 1);
  assert.equal((await handler(ownerRequest('?days=8'))).status, 400);
  assert.equal(called, 1);
  assert.equal((await handler(post({}))).status, 405);
});

test('Windows and Linux use the same content-free analytics contract', () => {
  for (const platform of ['Windows', 'Linux']) {
    const result = validateBatch({ events: [event({ properties: { platform, version: '0.1.0', build: '1' } })] }, now);
    assert.equal(result[0].properties.platform, platform);
    assert.throws(() => validateBatch({ events: [event({ properties: { platform, title: 'Private document' } })] }, now), { status: 400 });
  }
});
