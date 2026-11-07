import test from 'node:test';
import assert from 'node:assert/strict';
import {
  analyticsAuthConfiguration, withAnalyticsAdmin,
  createLoginHandler, createCallbackHandler, createSessionHandler, createLogoutHandler,
} from './analytics-auth.mjs';

const site = 'https://www.kodi-reader.app';
const env = {
  ANALYTICS_SITE_URL: site,
  ANALYTICS_SUPABASE_URL: 'https://example.supabase.co',
  ANALYTICS_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_testing_only_1234567890',
  ANALYTICS_ADMIN_EMAIL: 'developer.olly@gmail.com',
  ANALYTICS_SESSION_SECRET: 'testing-only-session-secret-with-at-least-32-bytes',
};
const subject = '37f6acae-e80d-4d16-a4c6-500000000001';
const sessionID = '37f6acae-e80d-4d16-a4c6-500000000002';
const now = new Date();
const user = {
  id: subject, aud: 'authenticated', role: 'authenticated', email: env.ANALYTICS_ADMIN_EMAIL,
  email_confirmed_at: '2026-10-24T10:00:00Z', created_at: '2026-10-24T10:00:00Z',
  app_metadata: { provider: 'email', providers: ['email', 'google'] },
  user_metadata: { provider: 'google', email_verified: true },
  identities: [{ id: 'google-identity', provider: 'google', identity_data: { sub: 'google-owner-123' } }],
};
const token = (claims = {}) => [
  Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url'),
  Buffer.from(JSON.stringify({
    sub: subject, session_id: sessionID, exp: Math.floor(Date.now() / 1000) + 3600,
    iat: Math.floor(Date.now() / 1000), aud: 'authenticated', role: 'authenticated',
    amr: [{ method: 'oauth', timestamp: Math.floor(Date.now() / 1000) }], ...claims,
  })).toString('base64url'),
  Buffer.alloc(32, 1).toString('base64url'),
].join('.');

function applyCookies(jar, response) {
  for (const value of response.headers.getSetCookie()) {
    const pair = value.split(';')[0];
    const equal = pair.indexOf('=');
    const name = pair.slice(0, equal);
    if (/; Max-Age=0(?:;|$)/i.test(value)) jar.delete(name); else jar.set(name, pair.slice(equal + 1));
  }
}

function fixture(overrides = {}) {
  const jar = new Map();
  const calls = [];
  const currentUser = overrides.user || structuredClone(user);
  const providerToken = overrides.providerToken || 'google-provider-access-token';
  let accessToken = overrides.accessToken || token();
  const config = { ...env, ...overrides.env };
  const dependencies = {
    env: config, now: () => overrides.now || now,
    fetchImpl: async (url, options = {}) => {
      calls.push({ url: String(url), options });
      const parsed = new URL(url);
      const headers = new Headers(options.headers);
      assert.ok(options.signal instanceof AbortSignal, 'every upstream request has an abort deadline');
      if (parsed.origin === 'https://openidconnect.googleapis.com') {
        assert.equal(parsed.pathname, '/v1/userinfo');
        assert.equal(headers.get('authorization'), `Bearer ${providerToken}`);
        return Response.json(overrides.google || { sub: 'google-owner-123', email: env.ANALYTICS_ADMIN_EMAIL, email_verified: true });
      }
      assert.equal(parsed.origin, env.ANALYTICS_SUPABASE_URL);
      assert.equal(headers.get('apikey'), env.ANALYTICS_SUPABASE_PUBLISHABLE_KEY);
      if (parsed.pathname === '/auth/v1/token') {
        if (parsed.searchParams.get('grant_type') === 'pkce') {
          const body = JSON.parse(options.body);
          assert.equal(body.auth_code, 'valid-google-code');
          assert.ok(body.code_verifier.length >= 43);
        } else {
          assert.equal(parsed.searchParams.get('grant_type'), 'refresh_token');
          accessToken = token(overrides.refreshClaims);
        }
        return Response.json({
          access_token: accessToken, refresh_token: 'supabase-refresh-token',
          expires_in: 3600, token_type: 'bearer', user: currentUser,
          provider_token: providerToken, provider_refresh_token: 'google-provider-refresh-token',
        });
      }
      if (parsed.pathname === '/auth/v1/user') {
        if (overrides.userError) return Response.json({ msg: 'upstream-private-diagnostic' }, { status: overrides.userError });
        assert.equal(headers.get('authorization'), `Bearer ${accessToken}`);
        return Response.json(currentUser);
      }
      if (parsed.pathname === '/auth/v1/logout') {
        assert.equal(parsed.searchParams.get('scope'), 'local');
        return new Response(null, { status: overrides.logoutError || 204 });
      }
      throw new Error(`Unexpected request ${parsed.pathname}`);
    },
  };
  const request = (path, { method = 'GET', headers = {}, cookieJar = jar } = {}) => new Request(`${config.ANALYTICS_SITE_URL}${path}`, {
    method, headers: { cookie: [...cookieJar].map(([key, value]) => `${key}=${value}`).join('; '), ...headers },
  });
  async function login() {
    const response = await createLoginHandler(dependencies)(request('/api/analytics/auth/login'));
    applyCookies(jar, response);
    return response;
  }
  async function callback(query = '?code=valid-google-code') {
    const response = await createCallbackHandler(dependencies)(request(`/api/analytics/auth/callback${query}`, { headers: { 'sec-fetch-site': 'cross-site' } }));
    applyCookies(jar, response);
    return response;
  }
  return { jar, calls, request, dependencies, login, callback };
}

test('Google configuration fails closed and never accepts the retired bearer token', async () => {
  for (const missing of Object.keys(env).filter(name => name !== 'ANALYTICS_SITE_URL')) {
    assert.throws(() => analyticsAuthConfiguration({ ...env, [missing]: undefined }), { status: 503, code: 'not_configured' });
  }
  for (const siteValue of ['http://example.com', `${site}/subpath`, `${site}?redirect=evil`, 'https://user:password@example.com']) {
    assert.throws(() => analyticsAuthConfiguration({ ...env, ANALYTICS_SITE_URL: siteValue }));
  }
  const f = fixture();
  const response = await withAnalyticsAdmin(f.request('/api/analytics/dashboard', { headers: { authorization: 'Bearer old-admin-token' } }), () => {
    assert.fail('no data handler may run without a Google session');
  }, f.dependencies);
  assert.equal(response.status, 401);
  assert.equal(f.calls.length, 0);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});

test('login uses Google PKCE, the fixed callback, and protected verifier cookies', async () => {
  const f = fixture();
  const response = await f.login();
  assert.equal(response.status, 303);
  const destination = new URL(response.headers.get('location'));
  assert.equal(destination.origin, env.ANALYTICS_SUPABASE_URL);
  assert.equal(destination.pathname, '/auth/v1/authorize');
  assert.equal(destination.searchParams.get('provider'), 'google');
  assert.equal(destination.searchParams.get('redirect_to'), `${site}/api/analytics/auth/callback`);
  assert.equal(destination.searchParams.get('prompt'), 'select_account');
  assert.equal(destination.searchParams.get('code_challenge_method'), 's256');
  assert.ok(destination.searchParams.get('code_challenge').length >= 43);
  const verifier = response.headers.getSetCookie().find(value => value.startsWith('__Host-kodi-analytics-session-code-verifier='));
  for (const part of ['Path=/', 'Max-Age=600', 'HttpOnly', 'Secure', 'SameSite=Lax']) assert.ok(verifier.includes(part), part);
  assert.equal(verifier.includes('Domain='), false);
  assert.equal(f.calls.length, 0);
});

test('verified Google owner gets an HttpOnly session with no provider tokens exposed or retained', async () => {
  const f = fixture();
  await f.login();
  const response = await f.callback();
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('location'), `${site}/analytics`);
  const owner = response.headers.getSetCookie().find(value => value.startsWith('__Host-kodi-analytics-owner='));
  for (const part of ['Path=/', 'Max-Age=28800', 'HttpOnly', 'Secure', 'SameSite=Lax']) assert.ok(owner.includes(part), part);
  const sessionCookie = decodeURIComponent(f.jar.get('__Host-kodi-analytics-session'));
  const savedSession = JSON.parse(Buffer.from(sessionCookie.replace(/^base64-/, ''), 'base64url').toString());
  assert.equal(savedSession.provider_token, undefined);
  assert.equal(savedSession.provider_refresh_token, undefined);
  const sessionResponse = await createSessionHandler(f.dependencies)(f.request('/api/analytics/auth/session'));
  assert.equal(sessionResponse.status, 200);
  assert.deepEqual(await sessionResponse.json(), { authenticated: true, email: env.ANALYTICS_ADMIN_EMAIL });
  const dataResponse = await withAnalyticsAdmin(f.request('/api/analytics/dashboard'), ({ user: administrator }) => {
    assert.equal(administrator.id, subject);
    return Response.json({ days: 30, summary: {} });
  }, f.dependencies);
  assert.equal(dataResponse.status, 200);
  assert.equal(dataResponse.headers.get('cache-control'), 'no-store');
});

test('wrong, unverified, mismatched or non-Google sign-ins cannot authorize analytics', async () => {
  const cases = [
    { google: { sub: 'google-owner-123', email: 'someone-else@gmail.com', email_verified: true } },
    { google: { sub: 'google-owner-123', email: env.ANALYTICS_ADMIN_EMAIL, email_verified: false } },
    { google: { sub: 'unlinked-google-account', email: env.ANALYTICS_ADMIN_EMAIL, email_verified: true } },
    { user: { ...user, email: 'someone-else@gmail.com' } },
    { user: { ...user, email_confirmed_at: null } },
    { user: { ...user, is_anonymous: true } },
    { user: { ...user, identities: [{ provider: 'apple', identity_data: { sub: 'google-owner-123' } }] } },
    { accessToken: token({ amr: [{ method: 'otp' }] }) },
  ];
  for (const options of cases) {
    const f = fixture(options);
    await f.login();
    const response = await f.callback();
    assert.equal(response.headers.get('location'), `${site}/analytics?auth_error=access_denied`);
    assert.equal(f.jar.has('__Host-kodi-analytics-owner'), false);
    assert.equal(f.jar.has('__Host-kodi-analytics-session'), false);
    const sessionResponse = await createSessionHandler(f.dependencies)(f.request('/api/analytics/auth/session'));
    assert.deepEqual(await sessionResponse.json(), { authenticated: false });
  }
});

test('provider-token removal also deletes temporary session-cookie chunks', async () => {
  const f = fixture({ providerToken: `google-sensitive-provider-token-${'x'.repeat(8000)}` });
  await f.login();
  const response = await f.callback();
  assert.equal(response.headers.get('location'), `${site}/analytics`);
  assert.ok(f.jar.has('__Host-kodi-analytics-session'));
  assert.equal([...f.jar.keys()].some(name => /session\.\d+$/.test(name)), false);
  for (const value of response.headers.getSetCookie()) assert.equal(decodeURIComponent(value).includes('google-sensitive-provider-token'), false);
});

test('callback errors clear cookies, sanitize provider diagnostics and cannot redirect off site', async () => {
  for (const query of ['?code=', '?code=a&code=b', '?error=private-provider-error&error_description=private-diagnostic', '?next=https://attacker.test']) {
    const f = fixture();
    await f.login();
    const response = await f.callback(query);
    assert.equal(response.status, 303);
    assert.equal(response.headers.get('location'), `${site}/analytics?auth_error=oauth_failed`);
    assert.equal((await response.text()).includes('private'), false);
    assert.equal(f.jar.size, 0);
  }
});

test('unsolicited cross-site callbacks without a PKCE verifier cannot log the owner out', async () => {
  const f = fixture();
  await f.login();
  await f.callback();
  assert.equal(f.jar.has('__Host-kodi-analytics-session-code-verifier'), false);
  const savedCookies = new Map(f.jar);
  for (const query of ['', '?error=access_denied', '?code=', '?code=valid-google-code']) {
    const before = f.calls.length;
    const response = await f.callback(query);
    assert.equal(response.status, 303);
    assert.equal(response.headers.get('location'), `${site}/analytics?auth_error=oauth_failed`);
    assert.equal(response.headers.getSetCookie().length, 0);
    assert.equal(f.calls.length, before, 'unsolicited callback neither exchanges nor revokes a session');
    assert.deepEqual(f.jar, savedCookies);
    const sessionResponse = await createSessionHandler(f.dependencies)(f.request('/api/analytics/auth/session'));
    assert.deepEqual(await sessionResponse.json(), { authenticated: true, email: env.ANALYTICS_ADMIN_EMAIL });
  }
});

test('owner marker cannot be tampered with, expired, or used with a different Supabase session', async () => {
  const f = fixture();
  await f.login();
  await f.callback();
  const original = f.jar.get('__Host-kodi-analytics-owner');
  f.jar.set('__Host-kodi-analytics-owner', original.slice(0, -1) + (original.endsWith('a') ? 'b' : 'a'));
  let calls = f.calls.length;
  assert.equal((await withAnalyticsAdmin(f.request('/api/analytics/dashboard'), () => assert.fail(), f.dependencies)).status, 401);
  assert.equal(f.calls.length, calls, 'tampered marker is rejected before the Auth network call');
  f.jar.set('__Host-kodi-analytics-owner', original);
  const expired = { ...f.dependencies, now: () => new Date(now.getTime() + 8 * 60 * 60 * 1000) };
  assert.equal((await withAnalyticsAdmin(f.request('/api/analytics/dashboard'), () => assert.fail(), expired)).status, 401);
  const sessionCookie = decodeURIComponent(f.jar.get('__Host-kodi-analytics-session'));
  const session = JSON.parse(Buffer.from(sessionCookie.replace(/^base64-/, ''), 'base64url').toString());
  session.access_token = token({ session_id: '37f6acae-e80d-4d16-a4c6-500000000099' });
  f.jar.set('__Host-kodi-analytics-session', `base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`);
  const alternate = fixture({ accessToken: session.access_token });
  const response = await withAnalyticsAdmin(f.request('/api/analytics/dashboard'), () => assert.fail(), alternate.dependencies);
  assert.equal(response.status, 401);
});

test('session refresh cookies survive route errors and the owner session binding survives refresh', async () => {
  const f = fixture();
  await f.login();
  await f.callback();
  const encoded = decodeURIComponent(f.jar.get('__Host-kodi-analytics-session'));
  const session = JSON.parse(Buffer.from(encoded.replace(/^base64-/, ''), 'base64url').toString());
  session.expires_at = Math.floor(Date.now() / 1000) - 60;
  session.access_token = token({ exp: session.expires_at });
  f.jar.set('__Host-kodi-analytics-session', `base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`);
  const response = await withAnalyticsAdmin(f.request('/api/analytics/dashboard'), () => Response.json({ error: 'storage-unavailable' }, { status: 503 }), f.dependencies);
  assert.equal(response.status, 503);
  assert.ok(response.headers.getSetCookie().some(value => value.startsWith('__Host-kodi-analytics-session=')));
  assert.equal(response.headers.get('cache-control'), 'no-store');
});

test('origin checks reject cross-site login, dashboard requests and sign-out before network access', async () => {
  const f = fixture();
  for (const headers of [{ 'sec-fetch-site': 'cross-site' }, { 'sec-fetch-site': 'same-site' }, { origin: 'https://attacker.test' }]) {
    assert.equal((await createLoginHandler(f.dependencies)(f.request('/api/analytics/auth/login', { headers }))).status, 403);
    assert.equal((await withAnalyticsAdmin(f.request('/api/analytics/dashboard', { headers }), () => assert.fail(), f.dependencies)).status, 403);
  }
  for (const headers of [{}, { origin: 'https://attacker.test' }, { origin: site, 'sec-fetch-site': 'cross-site' }]) {
    assert.equal((await createLogoutHandler(f.dependencies)(f.request('/api/analytics/auth/logout', { method: 'POST', headers }))).status, 403);
  }
  assert.equal((await createSessionHandler(f.dependencies)(new Request('https://preview.example.com/api/analytics/auth/session'))).status, 403);
  assert.equal(f.calls.length, 0);
});

test('local preview uses unprefixed cookies while hosted production never permits HTTP auth', async () => {
  const f = fixture({ env: { ANALYTICS_SITE_URL: 'http://127.0.0.1:4173' } });
  const response = await f.login();
  assert.equal(response.status, 303);
  const verifier = response.headers.getSetCookie().find(value => value.startsWith('kodi-analytics-session-code-verifier='));
  assert.ok(verifier);
  assert.equal(verifier.includes(' Secure;'), false);
  assert.equal(verifier.includes('HttpOnly'), true);
  assert.throws(() => analyticsAuthConfiguration({ ...env, ANALYTICS_SITE_URL: 'http://127.0.0.1:4173', VERCEL: '1' }), { status: 503 });
});

test('logout revokes only this session and clears all auth cookies, including chunks', async () => {
  const f = fixture();
  await f.login();
  await f.callback();
  f.jar.set('__Host-kodi-analytics-session.0', 'old-chunk');
  f.jar.set('__Host-kodi-analytics-session.1', 'old-chunk');
  const response = await createLogoutHandler(f.dependencies)(f.request('/api/analytics/auth/logout', { method: 'POST', headers: { origin: site } }));
  assert.equal(response.status, 200);
  applyCookies(f.jar, response);
  assert.equal(f.jar.size, 0);
  assert.deepEqual(await response.json(), { authenticated: false });
  assert.ok(f.calls.some(call => call.url.includes('/logout?scope=local')));
});

test('auth service outages remain explicit errors and never expose upstream details', async () => {
  const healthy = fixture();
  await healthy.login();
  await healthy.callback();
  const outage = fixture({ userError: 500 });
  const response = await createSessionHandler(outage.dependencies)(healthy.request('/api/analytics/auth/session'));
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.equal(body.error.code, 'auth_unavailable');
  assert.equal(JSON.stringify(body).includes('private-diagnostic'), false);
  const notConfigured = await createSessionHandler({ env: {} })(new Request(`${site}/api/analytics/auth/session`));
  assert.equal(notConfigured.status, 503);
  assert.equal((await notConfigured.json()).error.code, 'not_configured');
});
