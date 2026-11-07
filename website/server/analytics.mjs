import { withAnalyticsAdmin } from './analytics-auth.mjs';

export const EVENT_NAMES = Object.freeze([
  'app_active', 'reading_started', 'reading_heartbeat', 'page_turned',
  'book_imported', 'highlight_created', 'note_saved', 'sketch_saved',
  'web_opened', 'ai_request_started', 'ai_request_completed', 'ai_request_failed',
  'note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session', 'ai_request_cancelled',
  'reminder_created', 'reminder_updated', 'reminder_completed', 'reminder_reopened',
  'reminder_deleted', 'reminder_restored', 'reminder_opened', 'sketch_opened', 'sketch_deleted',
  'audio_recording_started', 'audio_recording_paused', 'audio_recording_resumed',
  'audio_recording_saved', 'audio_recording_discarded', 'audio_recording_failed', 'audio_recording_heartbeat',
  'tts_listening_started', 'tts_listening_paused', 'tts_listening_resumed', 'tts_listening_stopped',
  'tts_listening_completed', 'tts_listening_failed', 'tts_listening_heartbeat',
]);
export const MAX_BODY_BYTES = 64 * 1024;
export const MAX_BATCH_SIZE = 50;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
const EVENT_KEYS = new Set(['id', 'installation_id', 'session_id', 'occurred_at', 'name', 'duration_seconds', 'properties']);
const PROPERTY_RULES = Object.freeze({
  platform: value => ['macOS', 'iOS', 'web'].includes(value),
  version: value => typeof value === 'string' && /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$/.test(value),
  build: value => typeof value === 'string' && /^(?:unknown|\d{1,10}(?:\.\d{1,10}){0,3})$/.test(value),
  content_type: value => ['epub', 'pdf', 'web'].includes(value),
  error_category: value => ['network', 'authentication', 'credits', 'service', 'rate_limit', 'provider', 'cancelled', 'unknown'].includes(value),
  request_id: value => typeof value === 'string' && UUID.test(value),
  schema_version: value => Number.isInteger(value) && [1, 2, 3].includes(value),
});
const AI_EVENTS = new Set(['ai_request_started', 'ai_request_completed', 'ai_request_failed', 'ai_request_cancelled']);
const DURATION_EVENTS = new Set(['reading_heartbeat', 'audio_recording_heartbeat', 'tts_listening_heartbeat']);
const V3_EVENTS = new Set(EVENT_NAMES.filter(name => name.startsWith('reminder_') || name.startsWith('audio_recording_') || name.startsWith('tts_listening_') || ['sketch_opened', 'sketch_deleted'].includes(name)));
// ISO 3166-1 alpha-2 codes, rather than accepting arbitrary two-letter strings.
// Country is a network-origin observation, never an event's physical location.
const COUNTRIES = new Set(('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' '));

export function requestCountry(request, env = process.env) {
  // Local headers and client JSON are never treated as trusted geolocation.
  if (env.VERCEL !== '1') return null;
  const country = request.headers.get('x-vercel-ip-country');
  return COUNTRIES.has(country) ? country : null;
}

export class AnalyticsError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function jsonResponse(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      ...extraHeaders,
    },
  });
}

export function errorResponse(error) {
  const known = error instanceof AnalyticsError;
  return jsonResponse({ error: {
    code: known ? error.code : 'storage_unavailable',
    message: known ? error.message : 'Analytics storage is temporarily unavailable.',
  } }, known ? error.status : 503, error?.status === 429 ? { 'Retry-After': '60' } : {});
}

function invalid(message) {
  throw new AnalyticsError(400, 'invalid_events', message);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function eventTimestamp(value) {
  if (typeof value !== 'string' || !ISO_DATE.test(value)) return NaN;
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  // Date.parse rolls September 31 into October; reject nonexistent calendar dates.
  if (month < 1 || month > 12 || day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return NaN;
  return Date.parse(value);
}

export async function readBoundedJSON(request) {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type') || '')) {
    throw new AnalyticsError(415, 'unsupported_media_type', 'Use application/json.');
  }
  const size = Number(request.headers.get('content-length'));
  if (size > MAX_BODY_BYTES) throw new AnalyticsError(413, 'payload_too_large', 'The event batch is too large.');
  const reader = request.body?.getReader();
  if (!reader) invalid('An event batch is required.');
  const chunks = [];
  let received = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > MAX_BODY_BYTES) {
        await reader.cancel();
        throw new AnalyticsError(413, 'payload_too_large', 'The event batch is too large.');
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(received);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (error) {
    if (error instanceof AnalyticsError) throw error;
    invalid('The event batch must contain valid JSON.');
  } finally {
    reader.releaseLock();
  }
}

export function validateBatch(body, now = new Date()) {
  if (!isRecord(body) || Object.keys(body).some(key => key !== 'events') || !Array.isArray(body.events)) {
    invalid('Send an object containing an events array.');
  }
  if (body.events.length < 1 || body.events.length > MAX_BATCH_SIZE) {
    invalid(`Send between 1 and ${MAX_BATCH_SIZE} events.`);
  }
  const seen = new Set();
  let installation;
  return body.events.flatMap(event => {
    if (!isRecord(event) || Object.keys(event).some(key => !EVENT_KEYS.has(key))) invalid('Unexpected event fields.');
    for (const key of ['id', 'installation_id', 'session_id']) {
      if (typeof event[key] !== 'string' || !UUID.test(event[key])) invalid(`${key} must be a UUID.`);
    }
    if (!EVENT_NAMES.includes(event.name)) invalid('Unknown event name.');
    const occurred = eventTimestamp(event.occurred_at);
    if (!Number.isFinite(occurred) || occurred < now.getTime() - 90 * 86400000 || occurred > now.getTime() + 5 * 60000) {
      invalid('Events must have an ISO timestamp within the past 90 days and no more than 5 minutes ahead.');
    }
    if (DURATION_EVENTS.has(event.name)) {
      if (!Number.isInteger(event.duration_seconds) || event.duration_seconds < 1 || event.duration_seconds > 60) {
        invalid('Activity heartbeats require 1–60 whole duration_seconds.');
      }
    } else if (event.duration_seconds !== undefined) {
      invalid('Only activity heartbeats may include duration_seconds.');
    }
    const properties = event.properties === undefined ? {} : event.properties;
    if (!isRecord(properties) || Object.keys(properties).some(key => !Object.hasOwn(PROPERTY_RULES, key))) {
      invalid('Unexpected event properties.');
    }
    for (const [key, value] of Object.entries(properties)) {
      if (!PROPERTY_RULES[key](value)) invalid(`Invalid ${key} property.`);
    }
    if (properties.request_id !== undefined && !AI_EVENTS.has(event.name)) invalid('Request IDs belong only to AI lifecycle events.');
    if (AI_EVENTS.has(event.name) && properties.schema_version >= 2 && !properties.request_id) invalid('AI lifecycle events require a telemetry request ID.');
    if (V3_EVENTS.has(event.name) && properties.schema_version !== 3) invalid('These feature events require schema version 3.');
    const normalized = {
      id: event.id.toLowerCase(),
      installation_id: event.installation_id.toLowerCase(),
      session_id: event.session_id.toLowerCase(),
      occurred_at: new Date(occurred).toISOString(),
      name: event.name,
      ...(DURATION_EVENTS.has(event.name) ? { duration_seconds: event.duration_seconds } : {}),
      properties: { ...properties, ...(properties.request_id ? { request_id: properties.request_id.toLowerCase() } : {}) },
    };
    installation ||= normalized.installation_id;
    if (installation !== normalized.installation_id) invalid('A batch must belong to one installation.');
    if (seen.has(normalized.id)) return [];
    seen.add(normalized.id);
    return [normalized];
  });
}

export function parseDays(request) {
  const values = new URL(request.url).searchParams.getAll('days');
  if (!values.length) return 30;
  if (values.length !== 1 || !['7', '30', '90'].includes(values[0])) {
    throw new AnalyticsError(400, 'invalid_period', 'Choose a 7, 30, or 90 day period.');
  }
  return Number(values[0]);
}

export function getPeriod(days, now) {
  const day = 86400000;
  const start = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - (days - 1) * day;
  return {
    start: new Date(start).toISOString(), end: now.toISOString(),
    previous_start: new Date(start - days * day).toISOString(),
    previous_end: new Date(now.getTime() - days * day).toISOString(),
  };
}

export function storageConfiguration(env = process.env) {
  const key = env.ANALYTICS_SUPABASE_SERVICE_KEY;
  let url;
  try { url = new URL(env.ANALYTICS_SUPABASE_URL); } catch { /* handled below */ }
  let serviceKey = typeof key === 'string' && key.startsWith('sb_secret_') && key.length > 20;
  if (typeof key === 'string' && key.split('.').length === 3) {
    try { serviceKey = JSON.parse(Buffer.from(key.split('.')[1], 'base64url')).role === 'service_role'; } catch { /* invalid */ }
  }
  if (!url || url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/' || !serviceKey) {
    throw new AnalyticsError(503, 'not_configured', 'Analytics storage is not configured.');
  }
  return { url: url.origin, key };
}

export async function callAnalyticsRPC(name, parameters, { env = process.env, fetchImpl = fetch } = {}) {
  const { url, key } = storageConfiguration(env);
  const headers = { apikey: key, 'Content-Type': 'application/json' };
  // New Supabase secret keys belong in apikey, not in the JWT Authorization header.
  if (!key.startsWith('sb_secret_')) headers.Authorization = `Bearer ${key}`;
  const response = await fetchImpl(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST', headers, body: JSON.stringify(parameters), signal: AbortSignal.timeout(8000),
  });
  if (!response.ok) throw new AnalyticsError(503, 'storage_unavailable', 'Analytics storage is temporarily unavailable.');
  return response.json();
}

export function createEventsHandler(dependencies = {}) {
  return async request => {
    if (request.method !== 'POST') return jsonResponse({ error: { code: 'method_not_allowed', message: 'Use POST.' } }, 405, { Allow: 'POST' });
    try {
      const events = validateBatch(await readBoundedJSON(request), dependencies.now?.() || new Date());
      const result = await callAnalyticsRPC('analytics_ingest', { p_events: events, p_country_code: requestCountry(request, dependencies.env) }, dependencies);
      if (result.rate_limited) throw new AnalyticsError(429, 'rate_limited', 'Too many events; retry in a minute.');
      if (!Number.isInteger(result.stored) || result.stored < 0 || result.stored > events.length) {
        throw new AnalyticsError(503, 'storage_unavailable', 'Analytics storage is temporarily unavailable.');
      }
      return jsonResponse({ accepted: events.length, stored: result.stored, duplicates: events.length - result.stored }, 202);
    } catch (error) { return errorResponse(error); }
  };
}

export function createDashboardHandler(dependencies = {}) {
  return async request => {
    if (request.method !== 'GET') return jsonResponse({ error: { code: 'method_not_allowed', message: 'Use GET.' } }, 405, { Allow: 'GET' });
    return withAnalyticsAdmin(request, async () => {
      try {
        const days = parseDays(request);
        const result = await callAnalyticsRPC('analytics_dashboard', { p_days: days }, dependencies);
        return jsonResponse(result);
      } catch (error) { return errorResponse(error); }
    }, dependencies);
  };
}
