import { createHmac, timingSafeEqual } from 'node:crypto';
import { createServerClient } from '@supabase/ssr';

const SESSION_COOKIE = '__Host-kodi-analytics-session';
const OWNER_COOKIE = '__Host-kodi-analytics-owner';
const SESSION_SECONDS = 8 * 60 * 60;
const GOOGLE_USERINFO = 'https://openidconnect.googleapis.com/v1/userinfo';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class AnalyticsAuthError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}

function failure(status, code, message) { throw new AnalyticsAuthError(status, code, message); }

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'Pragma': 'no-cache', 'X-Content-Type-Options': 'nosniff', ...headers,
  } });
}

function authFailure(error) {
  const known = error instanceof AnalyticsAuthError;
  return json({ error: {
    code: known ? error.code : 'auth_unavailable',
    message: known ? error.message : 'Google sign-in is temporarily unavailable. Please try again.',
  } }, known ? error.status : 503);
}

export function analyticsAuthConfiguration(env = process.env) {
  let site, supabase;
  try {
    site = new URL(env.ANALYTICS_SITE_URL || 'https://www.kodi-reader.app');
    supabase = new URL(env.ANALYTICS_SUPABASE_URL);
  } catch { /* validated below */ }
  const local = site && site.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(site.hostname)
    && env.VERCEL !== '1' && env.NODE_ENV !== 'production';
  const key = env.ANALYTICS_SUPABASE_PUBLISHABLE_KEY;
  const email = env.ANALYTICS_ADMIN_EMAIL?.trim().toLowerCase();
  const secret = env.ANALYTICS_SESSION_SECRET;
  if (!site || (!local && site.protocol !== 'https:') || site.username || site.password || site.pathname !== '/' || site.search || site.hash
    || !supabase || supabase.protocol !== 'https:' || supabase.username || supabase.password || supabase.pathname !== '/' || supabase.search || supabase.hash
    || typeof key !== 'string' || !key.startsWith('sb_publishable_') || key.length < 24
    || !email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
    || typeof secret !== 'string' || Buffer.byteLength(secret) < 32) {
    failure(503, 'not_configured', 'Analytics Google sign-in is not configured.');
  }
  return {
    site: site.origin, supabase: supabase.origin, key, email, secret, secure: !local,
    sessionCookie: local ? 'kodi-analytics-session' : SESSION_COOKIE,
    ownerCookie: local ? 'kodi-analytics-owner' : OWNER_COOKIE,
  };
}

function parseCookies(request) {
  const result = [];
  const header = request.headers.get('cookie') || '';
  if (header.length > 32 * 1024) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  const names = new Set();
  for (const part of header.split(';')) {
    const position = part.indexOf('=');
    if (position < 1) continue;
    const name = part.slice(0, position).trim();
    if (names.has(name) && /^(?:__Host-)?kodi-analytics-/.test(name)) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
    names.add(name);
    try { result.push({ name, value: decodeURIComponent(part.slice(position + 1).trim()) }); } catch { /* ignore malformed unrelated cookie */ }
  }
  return result;
}

function cookie(name, value, { secure, maxAge = SESSION_SECONDS } = {}) {
  return `${name}=${encodeURIComponent(value)}; Path=/; Max-Age=${Math.max(0, Math.floor(maxAge))}; HttpOnly;${secure ? ' Secure;' : ''} SameSite=Lax`;
}

function validateOrigin(request, configuration, { callback = false, post = false } = {}) {
  if (new URL(request.url).origin !== configuration.site) failure(403, 'forbidden_origin', 'Open analytics on its configured website.');
  if (callback) return;
  const origin = request.headers.get('origin');
  if ((origin && origin !== configuration.site) || (post && origin !== configuration.site)
    || ['cross-site', 'same-site'].includes(request.headers.get('sec-fetch-site'))) {
    failure(403, 'forbidden_origin', 'Use the analytics dashboard to make this request.');
  }
}

function context(request, dependencies = {}, originOptions = {}) {
  const configuration = analyticsAuthConfiguration(dependencies.env);
  validateOrigin(request, configuration, originOptions);
  const cookies = parseCookies(request);
  const pending = new Map();
  const extraHeaders = new Map();
  const clientFactory = dependencies.createClient || createServerClient;
  const client = clientFactory(configuration.supabase, configuration.key, {
    cookieOptions: { name: configuration.sessionCookie, path: '/', httpOnly: true, secure: configuration.secure, sameSite: 'lax', maxAge: SESSION_SECONDS },
    global: { fetch: (url, options = {}) => (dependencies.fetchImpl || fetch)(url, {
      ...options, signal: options.signal ? AbortSignal.any([options.signal, AbortSignal.timeout(8000)]) : AbortSignal.timeout(8000),
    }) },
    cookies: {
      getAll: () => cookies,
      setAll(updates, headers = {}) {
        for (const { name, value, options } of updates) {
          if (!name.startsWith(configuration.sessionCookie)) continue;
          pending.set(name, cookie(name, value, {
            secure: configuration.secure,
            maxAge: options?.maxAge === 0 ? 0 : name.includes('code-verifier') ? 600 : SESSION_SECONDS,
          }));
          const existing = cookies.find(item => item.name === name);
          if (existing) existing.value = value; else cookies.push({ name, value });
        }
        for (const [name, value] of Object.entries(headers)) extraHeaders.set(name, value);
      },
    },
  });
  return {
    configuration, client, cookies,
    now: () => Math.floor((dependencies.now?.() || new Date()).getTime() / 1000),
    setOwner(value, maxAge = SESSION_SECONDS) { pending.set(configuration.ownerCookie, cookie(configuration.ownerCookie, value, { secure: configuration.secure, maxAge })); },
    clear() {
      for (const { name } of cookies) if (name.startsWith(configuration.sessionCookie)) pending.set(name, cookie(name, '', { secure: configuration.secure, maxAge: 0 }));
      pending.set(configuration.sessionCookie, cookie(configuration.sessionCookie, '', { secure: configuration.secure, maxAge: 0 }));
      pending.set(configuration.ownerCookie, cookie(configuration.ownerCookie, '', { secure: configuration.secure, maxAge: 0 }));
    },
    finish(response) {
      // Preserve the route's error/status/body while always returning refreshed cookies.
      const result = new Response(response.body, { status: response.status, statusText: response.statusText, headers: response.headers });
      for (const [name, value] of extraHeaders) result.headers.set(name, value);
      result.headers.set('Cache-Control', 'no-store');
      result.headers.set('Pragma', 'no-cache');
      result.headers.set('Referrer-Policy', 'no-referrer');
      result.headers.set('X-Content-Type-Options', 'nosniff');
      for (const value of pending.values()) result.headers.append('Set-Cookie', value);
      return result;
    },
  };
}

function hmac(value, secret) { return createHmac('sha256', secret).update(value).digest('base64url'); }

function ownerMarker(session, user, ctx) {
  const claims = sessionClaims(session);
  const body = Buffer.from(JSON.stringify({ v: 1, sub: user.id, sid: claims.session_id, email: ctx.configuration.email, exp: ctx.now() + SESSION_SECONDS })).toString('base64url');
  return `${body}.${hmac(body, ctx.configuration.secret)}`;
}

function sessionClaims(session) {
  let claims;
  try { claims = JSON.parse(Buffer.from(session?.access_token?.split('.')[1], 'base64url').toString('utf8')); } catch { /* handled below */ }
  if (!claims || !UUID.test(claims.session_id) || typeof claims.sub !== 'string') failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  return claims;
}

function readMarker(ctx) {
  const value = ctx.cookies.find(item => item.name === ctx.configuration.ownerCookie)?.value || '';
  if (value.length > 2048) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  const [body, signature, extra] = value.split('.');
  const expected = hmac(body || '', ctx.configuration.secret);
  if (!body || !/^[A-Za-z0-9_-]+$/.test(body) || !/^[A-Za-z0-9_-]{43}$/.test(signature || '') || extra !== undefined || signature.length !== expected.length
    || !timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  let marker;
  try { marker = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')); } catch { /* handled below */ }
  if (!marker || marker.v !== 1 || !Number.isInteger(marker.exp) || marker.exp <= ctx.now() || marker.exp > ctx.now() + SESSION_SECONDS
    || marker.email !== ctx.configuration.email || typeof marker.sub !== 'string' || !UUID.test(marker.sid)) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  return marker;
}

async function verifiedSession(ctx, marker) {
  // getUser validates with Auth, including account deletion. Cookie contents alone
  // and mutable user_metadata never establish identity or administrator access.
  const { data, error } = await ctx.client.auth.getUser();
  if (error) {
    if (error.status && error.status < 500) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
    failure(503, 'auth_unavailable', 'Google sign-in is temporarily unavailable. Please try again.');
  }
  const user = data?.user;
  if (!user || user.is_anonymous || user.email?.toLowerCase() !== ctx.configuration.email || !user.email_confirmed_at) failure(403, 'access_denied', 'This Google account cannot access analytics.');
  const { data: sessionData, error: sessionError } = await ctx.client.auth.getSession();
  if (sessionError || !sessionData?.session) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  const session = sessionData.session;
  const claims = sessionClaims(session);
  if (claims.sub !== user.id || !Array.isArray(claims.amr) || !claims.amr.some(item => item.method === 'oauth')) failure(403, 'access_denied', 'Sign in with the authorized Google account.');
  if (marker && (marker.sub !== user.id || marker.sid !== claims.session_id)) failure(401, 'unauthorized', 'Sign in with Google to view analytics.');
  return { user, session };
}

async function requireAdministrator(ctx) {
  const marker = readMarker(ctx);
  return verifiedSession(ctx, marker);
}

export async function withAnalyticsAdmin(request, handler, dependencies = {}) {
  let ctx;
  try {
    ctx = context(request, dependencies);
    const administrator = await requireAdministrator(ctx);
    return ctx.finish(await handler(administrator));
  } catch (error) {
    const response = authFailure(error);
    return ctx ? ctx.finish(response) : response;
  }
}

function method(request, expected) {
  return request.method === expected ? null : json({ error: { code: 'method_not_allowed', message: `Use ${expected}.` } }, 405, { Allow: expected });
}

function redirect(ctx, path) {
  return ctx.finish(new Response(null, { status: 303, headers: { Location: new URL(path, ctx.configuration.site).href } }));
}

export function createLoginHandler(dependencies = {}) {
  return async request => {
    const wrongMethod = method(request, 'GET');
    if (wrongMethod) return wrongMethod;
    let ctx;
    try {
      ctx = context(request, dependencies);
      ctx.clear();
      const { data, error } = await ctx.client.auth.signInWithOAuth({ provider: 'google', options: {
        redirectTo: `${ctx.configuration.site}/api/analytics/auth/callback`,
        scopes: 'openid email profile', skipBrowserRedirect: true,
        queryParams: { prompt: 'select_account', login_hint: ctx.configuration.email },
      } });
      if (error || !data?.url) failure(503, 'auth_unavailable', 'Google sign-in is temporarily unavailable. Please try again.');
      // The SDK creates the PKCE verifier cookie. Only the project's Auth server
      // may receive that authorization request; never trust a caller redirect.
      const destination = new URL(data.url);
      if (destination.origin !== ctx.configuration.supabase || destination.pathname !== '/auth/v1/authorize' || destination.searchParams.get('provider') !== 'google') failure(503, 'auth_unavailable', 'Google sign-in is temporarily unavailable. Please try again.');
      return ctx.finish(new Response(null, { status: 303, headers: { Location: destination.href } }));
    } catch (error) { return ctx ? ctx.finish(authFailure(error)) : authFailure(error); }
  };
}

export function createCallbackHandler(dependencies = {}) {
  return async request => {
    const wrongMethod = method(request, 'GET');
    if (wrongMethod) return wrongMethod;
    let ctx;
    try {
      ctx = context(request, dependencies, { callback: true });
      // A cross-site navigation to a stale or fabricated callback must not
      // revoke an existing administrator session. Only an OAuth attempt begun
      // in this browser may consume errors or exchange a code.
      const verifier = ctx.cookies.find(item => item.name === `${ctx.configuration.sessionCookie}-code-verifier`);
      if (!verifier?.value) return redirect(ctx, '/analytics?auth_error=oauth_failed');
      const params = new URL(request.url).searchParams;
      const codes = params.getAll('code');
      if (params.has('error') || codes.length !== 1 || !codes[0] || codes[0].length > 4096) failure(400, 'oauth_failed', 'Google sign-in could not be completed.');
      const { data, error } = await ctx.client.auth.exchangeCodeForSession(codes[0]);
      if (error || !data?.session?.provider_token) failure(400, 'oauth_failed', 'Google sign-in could not be completed.');
      const { user, session } = await verifiedSession(ctx);
      const googleResponse = await (dependencies.fetchImpl || fetch)(GOOGLE_USERINFO, {
        headers: { Authorization: `Bearer ${data.session.provider_token}`, Accept: 'application/json' },
        signal: AbortSignal.timeout(8000), redirect: 'error',
      });
      if (!googleResponse.ok) failure(503, 'oauth_failed', 'Google sign-in could not be completed.');
      const google = await googleResponse.json();
      const matchingIdentity = user.identities?.find(identity => identity.provider === 'google' && identity.identity_data?.sub === google.sub);
      if (!google.sub || google.email_verified !== true || google.email?.toLowerCase() !== ctx.configuration.email || !matchingIdentity) {
        failure(403, 'access_denied', 'This Google account cannot access analytics.');
      }
      // setSession stores a fresh SDK session containing only Supabase tokens,
      // discarding Google's provider access/refresh tokens before any response.
      const { error: storageError } = await ctx.client.auth.setSession({ access_token: session.access_token, refresh_token: session.refresh_token });
      if (storageError) failure(503, 'oauth_failed', 'Google sign-in could not be completed.');
      ctx.setOwner(ownerMarker(session, user, ctx));
      return redirect(ctx, '/analytics');
    } catch (error) {
      if (!ctx) return authFailure(error);
      // A failed callback never leaves a previously authorized dashboard open.
      try { await ctx.client.auth.signOut({ scope: 'local' }); } catch { /* cookies still cleared */ }
      ctx.clear();
      const code = error instanceof AnalyticsAuthError && ['access_denied', 'not_configured'].includes(error.code) ? error.code : 'oauth_failed';
      return redirect(ctx, `/analytics?auth_error=${code}`);
    }
  };
}

export function createSessionHandler(dependencies = {}) {
  return async request => {
    const wrongMethod = method(request, 'GET');
    if (wrongMethod) return wrongMethod;
    let ctx;
    try {
      ctx = context(request, dependencies);
      const { user } = await requireAdministrator(ctx);
      return ctx.finish(json({ authenticated: true, email: user.email }));
    } catch (error) {
      if (error instanceof AnalyticsAuthError && [401, 403].includes(error.status) && ctx) {
        ctx.clear();
        return ctx.finish(json({ authenticated: false }));
      }
      return ctx ? ctx.finish(authFailure(error)) : authFailure(error);
    }
  };
}

export function createLogoutHandler(dependencies = {}) {
  return async request => {
    const wrongMethod = method(request, 'POST');
    if (wrongMethod) return wrongMethod;
    let ctx;
    try {
      ctx = context(request, dependencies, { post: true });
      const { error } = await ctx.client.auth.signOut({ scope: 'local' });
      ctx.clear();
      if (error && error.status >= 500) failure(503, 'auth_unavailable', 'Sign-out could not be completed. Please try again.');
      return ctx.finish(json({ authenticated: false }));
    } catch (error) {
      if (ctx) ctx.clear();
      return ctx ? ctx.finish(authFailure(error)) : authFailure(error);
    }
  };
}
