const $ = (id) => document.getElementById(id);
const number = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
const shortDate = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
const longDate = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });
const time = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', timeZone: 'UTC', hour12: false });
const SVG_NS = 'http://www.w3.org/2000/svg';
const COLORS = { active_users: '#416f4d', readers: '#a8bb84', ai_users: '#c3a368', new_accounts: '#416f4d', ai_requests: '#a8bb84', ai_accounts: '#c3a368' };
const SERIES_NAMES = { active_users: 'Active devices', readers: 'Reader devices', ai_users: 'AI devices', new_accounts: 'New registrations', ai_requests: 'AI requests', ai_accounts: 'AI accounts' };
const DEVICE_SERIES = ['active_users', 'readers', 'ai_users'];
const SERVER_SERIES = ['new_accounts', 'ai_requests', 'ai_accounts'];
const LOCAL_HOST = location.hostname === '127.0.0.1' || location.hostname === 'localhost';
const EVENT_NAMES = {
  app_active: 'App opened', reading_started: 'Reader engagement started', reading_heartbeat: 'Reader engagement',
  page_turned: 'Page turns', book_imported: 'Book imports', highlight_created: 'Highlights',
  note_created: 'New notes', note_edit_session: 'Note editing sessions', sketch_created: 'New drawings', sketch_edit_session: 'Drawing editing sessions', note_saved: 'Legacy note autosaves', sketch_saved: 'Legacy drawing autosaves', web_opened: 'Web reader opens',
  reminder_created: 'Reminders created', reminder_updated: 'Reminders edited', reminder_completed: 'Reminders completed', reminder_reopened: 'Reminders reopened', reminder_deleted: 'Reminders deleted', reminder_restored: 'Reminders restored', reminder_opened: 'Reminder sources opened',
  sketch_opened: 'Drawings opened', sketch_deleted: 'Drawings deleted',
  audio_recording_started: 'Recordings started', audio_recording_saved: 'Recordings saved', audio_recording_discarded: 'Recordings discarded', audio_recording_paused: 'Recording pauses', audio_recording_resumed: 'Recording resumes', audio_recording_failed: 'Recording errors', audio_recording_heartbeat: 'Active recording intervals',
  tts_listening_started: 'Read-aloud sessions started', tts_listening_paused: 'Read-aloud pauses', tts_listening_resumed: 'Read-aloud resumes', tts_listening_stopped: 'Read-aloud sessions stopped', tts_listening_completed: 'Read-aloud sessions completed', tts_listening_failed: 'Read-aloud errors', tts_listening_heartbeat: 'Read-aloud playback intervals',
  account_created: 'Account registered', ai_request_charged: 'AI requests charged', ai_request_released: 'AI requests refunded', new_accounts: 'New registrations', new_account: 'New registration', ai_requests: 'AI requests', ai_request_reserved: 'AI requests reserved', ai_charged: 'Charged AI requests', ai_released: 'Refunded AI requests', ai_request_started: 'AI requests started', ai_request_completed: 'AI requests completed', ai_request_failed: 'AI requests failed', ai_request_cancelled: 'AI requests stopped',
};
const FEATURE_NAMES = ['book_imported', 'page_turned', 'highlight_created', 'note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session', 'web_opened'];
const SEMANTIC_FEATURES = new Set(['note_created', 'note_edit_session', 'sketch_created', 'sketch_edit_session']);
const LEGACY_FEATURES = ['note_saved', 'sketch_saved'];
const AI_TIMING_METRICS = {
  response_time_ms: { label: 'Response time', description: 'Request start to completion' },
  latency_ms: { label: 'First-text latency', description: 'Request start to first visible text' },
  streaming_time_ms: { label: 'Streaming time', description: 'First visible text to completion' },
};
const AI_TIMING_OUTCOMES = { completed: 'Completed', failed: 'Failed', cancelled: 'Stopped' };
const FEATURE_USAGE_GROUPS = {
  reminders: { title: 'Reminders', primary: 'created', caption: 'reminders created', overview: ['devices', 'completed', 'opened'], metrics: { devices: 'Devices', created: 'Created', updated: 'Edited', completed: 'Completed', reopened: 'Reopened', deleted: 'Deleted', restored: 'Restored', opened: 'Sources opened' } },
  sketching: { title: 'Drawing', primary: 'created', caption: 'drawings created', overview: ['devices', 'edit_sessions', 'opened'], metrics: { devices: 'Devices', created: 'Created', edit_sessions: 'Editing sessions', opened: 'Opened', deleted: 'Deleted' } },
  recording: { title: 'Audio recording', primary: 'seconds', caption: 'active recording time', overview: ['devices', 'saved', 'started'], metrics: { devices: 'Devices', started: 'Started', saved: 'Saved', discarded: 'Discarded', paused: 'Pauses', resumed: 'Resumes', failed: 'Errors', seconds: 'Active seconds' } },
  listening: { title: 'Read aloud', primary: 'seconds', caption: 'playback time', overview: ['devices', 'started', 'completed'], metrics: { devices: 'Devices', started: 'Started', paused: 'Pauses', resumed: 'Resumes', stopped: 'Stopped', completed: 'Completed', failed: 'Errors', seconds: 'Playback seconds' } },
};
const countryNames = typeof Intl.DisplayNames === 'function' ? new Intl.DisplayNames(undefined, { type: 'region' }) : null;
const state = { authenticated: false, email: '', checkingSession: false, signingOut: false, logoutFailed: false, authController: null, authRequest: 0, days: 30, data: null, controller: null, request: 0, loading: false, lastAttempt: 0, error: false, timer: null, snapshotMode: false, chartSource: 'device', series: new Set(DEVICE_SERIES) };

function setText(id, value) { $(id).textContent = value; }
function count(value) { return number.format(value); }
function milliseconds(value) {
  if (value === null || value === undefined) return 'No samples';
  if (value < 1000) return `${count(value)} ms`;
  return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(value / 1000)} s`;
}
function duration(seconds) {
  if (seconds === 0) return '0m';
  if (seconds < 60) return '<1m';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${count(minutes)}m`;
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return remainder === 0 ? `${count(hours)}h` : `${count(hours)}h ${remainder}m`;
}
function percent(value, total) { return total > 0 ? Math.min(100, value / total * 100) : 0; }
function formatPercent(value) { return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(value)}%`; }
function eventName(name) { return EVENT_NAMES[name] || String(name).replaceAll('_', ' '); }
function date(value) { return new Date(value.length === 10 ? `${value}T00:00:00Z` : value); }
function notice(message = '', kind = '') {
  const node = $('notice');
  node.textContent = message;
  node.dataset.kind = kind;
  node.hidden = !message;
}
function status(label, type) {
  setText('connection-label', label);
  $('connection-dot').dataset.status = type;
}
function cell(value, tag = 'td') {
  const node = document.createElement(tag);
  node.textContent = value;
  return node;
}
function emptyTable(body, columns, message) {
  const row = document.createElement('tr');
  const item = cell(message);
  item.colSpan = columns;
  item.className = 'table-empty';
  row.append(item);
  body.replaceChildren(row);
}
function sectionEmpty(parent, text) {
  const empty = document.createElement('div');
  empty.className = 'section-empty';
  empty.textContent = text;
  parent.replaceChildren(empty);
}
function svgElement(type, attrs = {}, text) {
  const node = document.createElementNS(SVG_NS, type);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (text !== undefined) node.textContent = text;
  return node;
}
function setAccessVisible(visible) {
  $('access-panel').hidden = !visible;
  updateAuthControls();
}
function updateAuthControls() {
  const busy = state.checkingSession || state.signingOut;
  $('google-sign-in').setAttribute('aria-disabled', String(busy));
  for (const id of ['sign-out', 'mobile-sign-out']) {
    $(id).hidden = !state.authenticated && !state.signingOut && !state.logoutFailed;
    $(id).disabled = state.signingOut;
  }
  $('session-account').hidden = !state.authenticated || !state.email;
  $('session-account').textContent = state.email;
  $('session-account').title = state.email;
}
function setLoading(loading) {
  state.loading = loading;
  document.body.classList.toggle('is-loading', loading);
  $('refresh').disabled = loading || (!state.authenticated && !state.snapshotMode);
  $('refresh').dataset.loading = String(loading);
  $('export').disabled = loading || !state.data;
  $('main').setAttribute('aria-busy', String(loading));
}
function resetValues() {
  configureSourceLayout();
  for (const id of ['account-total', 'account-signed-in', 'account-ai', 'account-requests', 'returning-devices', 'ai-cancelled']) setText(id, '—');
  for (const id of ['account-ai-change', 'account-requests-change']) { $(id).removeAttribute('title'); setText(id, 'From server records in this period'); }
  for (const node of document.querySelectorAll('.is-unmeasured')) node.classList.remove('is-unmeasured');
  for (const id of ['metric-active', 'metric-readers', 'metric-ai', 'metric-time', 'new-devices', 'total-sessions', 'total-ai-requests', 'adoption-percent', 'reading-total', 'reading-average', 'reading-adoption', 'ai-requests', 'ai-completed', 'ai-failed', 'ai-unresolved']) setText(id, '—');
  const defaults = { active: 'Distinct installations in this period', readers: 'Distinct devices using the reader', ai: 'Distinct devices making AI requests', time: 'Reading, notes, drawing, and Ask AI' };
  for (const [key, text] of Object.entries(defaults)) {
    setText(`change-${key}`, text);
    delete $(`change-${key}`).dataset.direction;
    $(`change-${key}`).removeAttribute('title');
  }
  setText('date-range', `Last ${state.days} days · UTC`);
  setText('updated-at', state.authenticated ? 'Waiting for analytics' : 'Sign in to view usage');
  setText('adoption-note', 'Share of active devices that used AI.');
  setText('ai-device-note', 'Across devices that asked Kodi AI for help.');
  setText('ai-success', '— outcomes');
  setText('chart-total', '—');
  setText('footer-status', 'PRIVATE · KODI READER');
  setText('reading-coverage', '');
  $('reading-coverage').hidden = true;
  $('adoption-bar').style.width = '0%';
  $('adoption-track').setAttribute('aria-label', 'AI adoption unavailable');
  $('ai-completed-bar').style.width = '0%';
  $('ai-failed-bar').style.width = '0%';
  $('ai-cancelled-bar').style.width = '0%';
  $('ai-unknown-bar').style.width = '0%';
  $('outcome-track').setAttribute('aria-label', 'AI request outcomes unavailable');
  sectionEmpty($('feature-list'), 'Sign in to see feature activity.');
  sectionEmpty($('version-list'), 'Version distribution appears with app activity.');
  sectionEmpty($('country-list'), 'Sign in to see country totals.');
  renderFeatureUsage();
  renderAiPerformance();
  $('legacy-features').hidden = true;
  setText('history-ledger', '');
  emptyTable($('recent-table'), 3, 'Activity appears as events reach the server.');
  emptyTable($('daily-table'), 6, 'Sign in to view daily data.');
  renderChart();
  $('export').disabled = true;
}
function clearDashboard({ message = '', focus = true } = {}) {
  state.authenticated = false;
  state.email = '';
  state.logoutFailed = false;
  state.snapshotMode = false;
  state.data = null;
  state.error = false;
  state.request += 1;
  state.controller?.abort();
  state.controller = null;
  clearInterval(state.timer);
  state.timer = null;
  setLoading(false);
  resetValues();
  setAccessVisible(true);
  status('Private dashboard', 'locked');
  notice(message, message ? 'error' : '');
  if (focus) $('google-sign-in').focus();
}
function authErrorMessage(code) {
  if (code === 'access_denied') return 'This Google account does not have access to analytics. Sign in with the dashboard owner’s account.';
  if (code === 'not_configured') return 'Google sign-in is not available yet. Please try again later.';
  if (code === 'session_expired') return 'Your session has expired. Sign in with Google again to continue.';
  return 'Google sign-in could not be completed. Please try again.';
}
function callbackMessage() {
  const url = new URL(location.href);
  if (!url.searchParams.has('auth_error')) return '';
  const message = authErrorMessage(url.searchParams.get('auth_error'));
  url.searchParams.delete('auth_error');
  history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  return message;
}
async function restoreSession({ message = '' } = {}) {
  state.authController?.abort();
  const controller = new AbortController();
  state.authController = controller;
  const request = ++state.authRequest;
  state.checkingSession = true;
  updateAuthControls();
  status('Checking sign-in', 'loading');
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch('/api/analytics/auth/session', { credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store', signal: controller.signal, referrerPolicy: 'no-referrer' });
    if (request !== state.authRequest) return;
    if (response.status === 401 || response.status === 403) { clearDashboard({ message: message || (response.status === 403 ? authErrorMessage('access_denied') : ''), focus: false }); return; }
    if (!response.ok) throw new Error('session_unavailable');
    const session = await response.json();
    if (request !== state.authRequest) return;
    if (typeof session?.authenticated !== 'boolean') throw new Error('invalid_session');
    if (!session.authenticated) { clearDashboard({ message, focus: false }); return; }
    state.authenticated = true;
    state.email = typeof session.email === 'string' ? session.email : '';
    state.checkingSession = false;
    setAccessVisible(false);
    await load();
  } catch {
    if (request !== state.authRequest) return;
    clearDashboard({ message: message || 'Could not check your sign-in. You can sign in with Google to try again.', focus: false });
  } finally {
    clearTimeout(timeout);
    if (request === state.authRequest) {
      state.authController = null;
      state.checkingSession = false;
      updateAuthControls();
    }
  }
}
async function signOut() {
  if (state.signingOut) return;
  state.authRequest += 1;
  state.authController?.abort();
  state.authController = null;
  state.checkingSession = false;
  state.signingOut = true;
  clearDashboard({ focus: false });
  status('Signing out', 'loading');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch('/api/analytics/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store', signal: controller.signal, referrerPolicy: 'no-referrer' });
    if (!response.ok) throw new Error('logout_failed');
    notice('You are signed out.');
    status('Private dashboard', 'locked');
  } catch {
    state.logoutFailed = true;
    notice('Could not finish signing out. Your analytics are hidden. Try signing out again.', 'error');
    status('Sign-out incomplete', 'error');
    return;
  } finally {
    clearTimeout(timeout);
    state.signingOut = false;
    updateAuthControls();
  }
  $('google-sign-in').focus();
}
function validateData(input, requestedDays) {
  if (!input || input.days !== requestedDays || !input.summary || !Array.isArray(input.daily) || !Array.isArray(input.features) || !Array.isArray(input.versions) || !Array.isArray(input.recent) || !Number.isFinite(date(input.generated_at || '').getTime())) throw new Error('invalid_data');
  const nonnegative = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
  for (const key of ['active_users', 'readers', 'ai_users', 'reading_seconds', 'new_users', 'sessions', 'ai_requests', 'ai_completed', 'ai_failed']) {
    if (!input.summary[key] || !nonnegative(input.summary[key].value) || !nonnegative(input.summary[key].previous)) throw new Error('invalid_data');
  }
  if (!input.period || !Number.isFinite(date(input.period.start || '').getTime()) || !Number.isFinite(date(input.period.end || '').getTime())) throw new Error('invalid_data');
  for (const item of input.daily) {
    if (typeof item.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(item.date) || !Number.isFinite(date(item.date).getTime()) || !['active_users', 'readers', 'ai_users', 'reading_seconds', 'ai_requests'].every((key) => nonnegative(item[key]))) throw new Error('invalid_data');
  }
  for (const item of input.features) if (typeof item.name !== 'string' || !nonnegative(item.count) || !nonnegative(item.users)) throw new Error('invalid_data');
  for (const item of input.versions) if (typeof item.version !== 'string' || !nonnegative(item.users)) throw new Error('invalid_data');
  for (const item of input.recent) if (typeof item.name !== 'string' || typeof item.date !== 'string' || !Number.isFinite(date(item.date).getTime()) || !nonnegative(item.count)) throw new Error('invalid_data');
  if (input.summary.returning_users && (!nonnegative(input.summary.returning_users.value) || !nonnegative(input.summary.returning_users.previous))) throw new Error('invalid_data');
  if (input.ai_outcomes) {
    for (const key of ['started', 'completed', 'failed', 'cancelled', 'unknown', 'legacy_started']) if (!nonnegative(input.ai_outcomes[key])) throw new Error('invalid_data');
    const outcomes = input.ai_outcomes;
    if (outcomes.completed + outcomes.failed + outcomes.cancelled + outcomes.unknown !== outcomes.started || outcomes.legacy_started > outcomes.unknown) throw new Error('invalid_data');
  }
  if (input.ai_performance !== undefined) {
    const performance = input.ai_performance;
    const integer = value => Number.isSafeInteger(value) && value >= 0;
    if (!performance || typeof performance.available !== 'boolean' || typeof performance.previous_available !== 'boolean'
      || !integer(performance.coverage?.devices) || !integer(performance.coverage?.older_devices)) throw new Error('invalid_data');
    for (const outcome of Object.keys(AI_TIMING_OUTCOMES)) {
      const group = performance[outcome];
      if (!group || !integer(group.requests)) throw new Error('invalid_data');
      for (const key of Object.keys(AI_TIMING_METRICS)) {
        const metric = group[key];
        if (!metric || !integer(metric.samples) || metric.samples > group.requests) throw new Error('invalid_data');
        for (const stat of ['average', 'p50', 'p95']) {
          if (metric.samples === 0 ? metric[stat] !== null : !nonnegative(metric[stat]) || metric[stat] > 86400000) throw new Error('invalid_data');
        }
        if (metric.samples > 0 && metric.p50 > metric.p95) throw new Error('invalid_data');
      }
    }
  }
  if (input.coverage) {
    if (!['first_event_at', 'last_received_at'].every(key => input.coverage[key] === null || (typeof input.coverage[key] === 'string' && Number.isFinite(date(input.coverage[key]).getTime()))) || !nonnegative(input.coverage.instrumented_devices) || !nonnegative(input.coverage.legacy_devices) || typeof input.coverage.semantic_features_available !== 'boolean') throw new Error('invalid_data');
    if (input.coverage.feature_usage_available !== undefined && typeof input.coverage.feature_usage_available !== 'boolean') throw new Error('invalid_data');
    if (input.coverage.feature_usage_previous_available !== undefined && typeof input.coverage.feature_usage_previous_available !== 'boolean') throw new Error('invalid_data');
    for (const key of ['feature_usage_devices', 'feature_usage_legacy_devices']) if (input.coverage[key] !== undefined && !nonnegative(input.coverage[key])) throw new Error('invalid_data');
  }
  if (input.feature_usage !== undefined) {
    if (!input.feature_usage || typeof input.feature_usage !== 'object' || Array.isArray(input.feature_usage)) throw new Error('invalid_data');
    for (const [key, definition] of Object.entries(FEATURE_USAGE_GROUPS)) {
      const group = input.feature_usage[key];
      if (group === undefined) continue;
      if (!group || typeof group.available !== 'boolean') throw new Error('invalid_data');
      if (group.previous_available !== undefined && typeof group.previous_available !== 'boolean') throw new Error('invalid_data');
      for (const metric of Object.keys(definition.metrics)) if (!nonnegative(group[metric]?.value) || !nonnegative(group[metric]?.previous)) throw new Error('invalid_data');
    }
  }
  if (input.countries !== undefined) {
    if (!Array.isArray(input.countries) || input.countries.length > 260) throw new Error('invalid_data');
    const seen = new Set();
    for (const country of input.countries) {
      if ((country.country_code !== null && (typeof country.country_code !== 'string' || !/^[A-Z]{2}$/.test(country.country_code))) || !nonnegative(country.devices) || seen.has(country.country_code)) throw new Error('invalid_data');
      seen.add(country.country_code);
    }
    if (input.countries.reduce((sum, row) => sum + row.devices, 0) !== input.summary.active_users.value) throw new Error('invalid_data');
  }
  if (input.server_metrics) {
    const server = input.server_metrics;
    if (!server.totals || !server.summary || !Array.isArray(server.daily) || !Array.isArray(server.recent)) throw new Error('invalid_data');
    for (const key of ['registered_accounts', 'credit_accounts', 'ai_accounts', 'ai_requests', 'ai_charged']) if (!nonnegative(server.totals[key])) throw new Error('invalid_data');
    for (const key of ['new_accounts', 'signed_in_accounts', 'ai_accounts', 'ai_requests', 'ai_charged', 'ai_released']) if (!nonnegative(server.summary[key]?.value) || !nonnegative(server.summary[key]?.previous)) throw new Error('invalid_data');
    for (const day of server.daily) if (typeof day.date !== 'string' || !Number.isFinite(date(day.date).getTime()) || !['new_accounts', 'ai_accounts', 'ai_requests', 'ai_charged', 'ai_released'].every((key) => nonnegative(day[key]))) throw new Error('invalid_data');
    for (const event of server.recent) if (typeof event.name !== 'string' || typeof event.date !== 'string' || !Number.isFinite(date(event.date).getTime()) || !nonnegative(event.count)) throw new Error('invalid_data');
  }
  if (input.data_source?.kind === 'local_snapshot' && (!LOCAL_HOST || !input.server_metrics || typeof input.data_source.captured_at !== 'string' || !Number.isFinite(date(input.data_source.captured_at).getTime()))) throw new Error('invalid_data');
  return input;
}
function failureMessage(code, statusCode) {
  if (code === 'not_configured') return 'Analytics is not available on the server yet. Please try again later.';
  if (code === 'storage_unavailable') return 'The analytics database is unavailable. Check the server configuration and try again.';
  if (statusCode === 429) return 'The server is receiving too many requests. Please wait a moment and refresh.';
  if (statusCode === 404) return 'The analytics endpoint is unavailable. Deploy the analytics API with this dashboard, then refresh.';
  return 'Could not load analytics. Check your connection and the analytics server, then refresh.';
}
async function load({ snapshot = state.snapshotMode, bootstrap = false } = {}) {
  if ((!state.authenticated && !snapshot) || (snapshot && !LOCAL_HOST)) return false;
  state.controller?.abort();
  const controller = new AbortController();
  state.controller = controller;
  const request = ++state.request;
  const requestedDays = state.days;
  state.lastAttempt = Date.now();
  state.error = false;
  setLoading(true);
  status(snapshot ? 'Reading database snapshot' : state.data ? 'Refreshing analytics' : 'Connecting', 'loading');
  notice();
  const timeout = setTimeout(() => controller.abort(), 20000);
  let timedOut = false;
  controller.signal.addEventListener('abort', () => { timedOut = true; }, { once: true });
  try {
    const endpoint = snapshot ? 'local-snapshot' : 'dashboard';
    const response = await fetch(`/api/analytics/${endpoint}?days=${requestedDays}`, { method: 'GET', headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store', signal: controller.signal, referrerPolicy: 'no-referrer' });
    if (request !== state.request) return;
    if (bootstrap && !response.ok) { status('Private dashboard', 'locked'); setAccessVisible(true); return false; }
    if (!snapshot && (response.status === 401 || response.status === 403)) {
      clearDashboard({ message: authErrorMessage(response.status === 403 ? 'access_denied' : 'session_expired') });
      return false;
    }
    let payload;
    try { payload = await response.json(); } catch { throw new Error(response.ok ? 'invalid_data' : 'server_error'); }
    if (request !== state.request) return;
    if (!response.ok) {
      const error = new Error(failureMessage(payload?.error?.code, response.status));
      error.publicMessage = true;
      throw error;
    }
    const data = validateData(payload, requestedDays);
    if ((snapshot && data.data_source?.kind !== 'local_snapshot') || (!snapshot && data.data_source?.kind === 'local_snapshot')) throw new Error('invalid_data');
    state.data = data;
    state.snapshotMode = snapshot;
    setAccessVisible(false);
    render();
    status(snapshot ? 'Database snapshot' : 'Connected · auto-refresh', snapshot ? 'snapshot' : 'live');
    if (!snapshot && data.summary.active_users.value === 0) notice(hasTelemetry() ? 'No device activity was recorded in this period. The recorded totals are zero.' : 'App telemetry has not started yet. Reader engagement and feature usage will appear as analytics-enabled Kodi apps send activity.');
    if (!snapshot && !state.timer) state.timer = setInterval(() => { if (!document.hidden && !state.loading && Date.now() - state.lastAttempt >= 60000) load(); }, 15000);
    return true;
  } catch (error) {
    if (request !== state.request) return;
    state.error = true;
    if (bootstrap) { status('Private dashboard', 'locked'); setAccessVisible(true); return false; }
    const message = error.message === 'invalid_data' ? 'The server returned an unexpected analytics response. Check that the dashboard and API versions match.' : error.publicMessage ? error.message : timedOut ? 'The analytics request timed out. Check the server and refresh to try again.' : failureMessage();
    const hasStaleData = Boolean(state.data);
    notice(`${message}${hasStaleData ? ' Showing the last successfully loaded data below.' : ''}`, hasStaleData ? 'stale' : 'error');
    status(hasStaleData ? 'Last data · refresh failed' : 'Unable to connect', 'error');
    return false;
  } finally {
    clearTimeout(timeout);
    if (request === state.request) { state.controller = null; setLoading(false); }
  }
}
function metric(id, data, formatter = count) {
  setText(`metric-${id}`, formatter(data.value));
  const target = $(`change-${id}`);
  if (data.previous === 0) {
    target.textContent = data.value > 0 ? 'New activity this period' : 'No change from the previous period';
    target.dataset.direction = data.value > 0 ? 'up' : 'flat';
  } else {
    const delta = (data.value - data.previous) / data.previous * 100;
    target.textContent = `${delta > 0 ? '↗ +' : delta < 0 ? '↘ −' : ''}${formatPercent(Math.abs(delta))} vs previous period`;
    target.dataset.direction = delta > 0 ? 'up' : delta < 0 ? 'down' : 'flat';
  }
  target.title = `Previous period: ${formatter(data.previous)}`;
}
function historicalLead() { return state.snapshotMode; }
function configureSourceLayout() {
  const server = historicalLead();
  const hasHistory = Boolean(state.data?.server_metrics);
  const target = server ? $('telemetry-mount') : $('main-kpis');
  if ($('telemetry-kpis').parentNode !== target) target.append($('telemetry-kpis'));
  const historyTarget = server ? $('main-kpis') : $('history-mount');
  if ($('server-kpis').parentNode !== historyTarget) historyTarget.append($('server-kpis'));
  $('server-kpis').hidden = !hasHistory && !server;
  $('history-section').hidden = !hasHistory || server;
  $('outcome-track').hidden = server || !state.data?.ai_outcomes;
  $('ai-cancelled-group').hidden = server;
  $('returning-row').hidden = server;
  $('telemetry-section').hidden = !server;
  $('source-banner').hidden = !server;
  const nextSource = server ? 'server' : 'device';
  const keys = server ? SERVER_SERIES : DEVICE_SERIES;
  if (state.chartSource !== nextSource) { state.series = new Set(keys); state.chartSource = nextSource; }
  const buttons = [...document.querySelectorAll('[data-series]')];
  buttons.forEach((button, index) => {
    button.dataset.series = keys[index];
    button.setAttribute('aria-pressed', String(state.series.has(keys[index])));
    button.lastChild.textContent = SERIES_NAMES[keys[index]];
  });
  setText('trend-heading', server ? 'Historical account & AI activity' : 'Daily app activity');
  setText('trend-unit', server ? 'COUNTS / DAY' : 'DEVICES / DAY');
  setText('chart-footnote', server ? 'New registrations, reserved AI requests, and distinct AI accounts per UTC day.' : 'Each line counts distinct devices per UTC day. Daily counts cannot be added to get period uniques.');
  const headers = server ? ['Date (UTC)', 'New registrations', 'AI requests', 'AI accounts'] : ['Date (UTC)', 'Active', 'Reader devices', 'AI', 'Engagement time', 'AI requests'];
  const row = document.createElement('tr');
  for (const header of headers) { const heading = cell(header, 'th'); heading.scope = 'col'; row.append(heading); }
  $('daily-head').replaceChildren(row);
  const labels = server ? {
    'audience-first-label': 'Credit accounts', 'audience-first-note': 'Accounts with a credit profile · all time',
    'audience-second-label': 'New registrations', 'audience-second-note': 'Accounts created in this period',
    'audience-third-label': 'AI requests · all time', 'audience-third-note': 'Reservations in the credit ledger',
    'adoption-label': 'AI reach in this period', 'audience-source-note': 'Account and credit totals come from server records. Device activity and reader engagement are measured separately below.',
    'ai-request-label': 'AI requests reserved', 'outcome-heading': 'Historical AI credit ledger', 'outcome-completed-label': 'Charged', 'outcome-failed-label': 'Refunded', 'outcome-unresolved-label': 'Reserved',
    'ai-outcome-note': 'Each count uses its own ledger timestamp, so charges and refunds may belong to reservations from another period. A charge can include text generated before delivery was interrupted; these are credit events, not completed or failed requests.',
    'recent-note': 'Recent daily account and AI credit ledger totals from this saved snapshot. No account identifiers are displayed.',
  } : {
    'audience-first-label': 'New devices', 'audience-first-note': 'First seen in this period',
    'audience-second-label': 'Foreground activations', 'audience-second-note': 'App became active; this is not a timed session count',
    'audience-third-label': 'AI requests', 'audience-third-note': 'Actual requests started across devices',
    'adoption-label': 'AI adoption', 'audience-source-note': 'Devices are random pseudonymous installations, without account linkage. One person using two devices counts twice.',
    'ai-request-label': 'requests started', 'outcome-heading': 'Outcomes of requests started in this period', 'outcome-completed-label': 'Completed', 'outcome-failed-label': 'Failed', 'outcome-unresolved-label': 'Unknown',
    'ai-outcome-note': 'Outcomes are matched to requests started in the selected period. Intentional stops count separately. In-flight, interrupted, and uncorrelated legacy requests remain Unknown.',
    'recent-note': 'The 12 most recent app event and UTC day groups.',
  };
  for (const [id, text] of Object.entries(labels)) setText(id, text);
  if (server) {
    $('source-banner').dataset.kind = 'snapshot';
    setText('source-title', 'Your historical account & AI activity.');
    setText('source-description', 'Aggregate account and AI credit records captured from the Kodi Reader database. This saved view does not update live. The separate device measurements below start with the analytics-enabled app release.');
    setText('source-badge', 'SAVED DATABASE SNAPSHOT');
    const captured = state.data?.data_source?.captured_at;
    setText('source-captured', captured ? `Captured ${longDate.format(date(captured))} at ${time.format(date(captured))} UTC · Refresh rereads this saved snapshot.` : '');
  }
}
function hasTelemetry() {
  if (!state.data) return false;
  return Boolean(state.data.coverage?.first_event_at) || state.data.summary.active_users.value > 0 || state.data.features.some((feature) => feature.count > 0) || state.data.summary.reading_seconds.value > 0;
}
function unmeasured(id) { setText(id, 'Not measured yet'); $(id).classList.add('is-unmeasured'); }
function accountComparison(id, metric) {
  const node = $(id);
  node.removeAttribute('title');
  if (metric.previous === 0) node.textContent = metric.value > 0 ? 'New activity this period' : 'No records in either period';
  else {
    const change = (metric.value - metric.previous) / metric.previous * 100;
    node.textContent = `${change > 0 ? '+' : change < 0 ? '−' : ''}${formatPercent(Math.abs(change))} vs previous period`;
  }
  node.title = `Previous period: ${count(metric.previous)}`;
}
function render() {
  const data = state.data;
  const summary = data.summary;
  const server = historicalLead() ? data.server_metrics : null;
  const measured = hasTelemetry();
  const coverage = data.coverage;
  $('reading-coverage').hidden = state.snapshotMode || !measured;
  for (const node of document.querySelectorAll('.is-unmeasured')) node.classList.remove('is-unmeasured');
  configureSourceLayout();
  metric('active', summary.active_users);
  metric('readers', summary.readers);
  metric('ai', summary.ai_users);
  metric('time', summary.reading_seconds, duration);
  setText('date-range', `${shortDate.format(date(data.period.start))} – ${longDate.format(date(data.period.end))} · UTC`);
  const captured = data.data_source?.captured_at || data.generated_at;
  setText('updated-at', state.snapshotMode ? `Captured ${time.format(date(captured))} UTC · saved snapshot` : `Updated ${time.format(date(data.generated_at))} UTC · every minute`);
  setText('new-devices', count(server ? server.totals.credit_accounts : summary.new_users.value));
  setText('returning-devices', summary.returning_users ? count(summary.returning_users.value) : 'Not measured');
  setText('total-sessions', count(server ? server.summary.new_accounts.value : summary.sessions.value));
  setText('total-ai-requests', count(server ? server.totals.ai_requests : summary.ai_requests.value));
  const aiUsers = server ? server.summary.ai_accounts.value : summary.ai_users.value;
  const audience = server ? server.totals.registered_accounts : summary.active_users.value;
  const adoption = percent(aiUsers, audience);
  setText('adoption-percent', audience > 0 ? formatPercent(adoption) : 'No active devices');
  $('adoption-bar').style.width = `${adoption}%`;
  $('adoption-track').setAttribute('aria-label', audience > 0 ? `${count(aiUsers)} ${server ? 'AI accounts in this period out of' : 'AI devices out of'} ${count(audience)} ${server ? 'all-time registered accounts' : 'active devices'}` : 'No active devices to measure AI adoption');
  setText('adoption-note', server ? `${count(aiUsers)} accounts made an AI request in this period, out of ${count(audience)} registered accounts in total.` : `${count(aiUsers)} of ${count(audience)} active devices used AI.`);
  setText('reading-total', duration(summary.reading_seconds.value));
  setText('reading-average', summary.readers.value > 0 ? duration(summary.reading_seconds.value / summary.readers.value) : 'No reader devices');
  setText('reading-adoption', summary.active_users.value > 0 ? formatPercent(percent(summary.readers.value, summary.active_users.value)) : 'No active devices');
  if (data.server_metrics) {
    const history = data.server_metrics;
    setText('account-total', count(history.totals.registered_accounts));
    setText('account-signed-in', count(history.summary.signed_in_accounts.value));
    setText('account-ai', count(history.summary.ai_accounts.value));
    setText('account-requests', count(history.summary.ai_requests.value));
    setText('account-sign-in-change', 'Accounts, based on latest auth sign-in');
    accountComparison('account-ai-change', history.summary.ai_accounts);
    accountComparison('account-requests-change', history.summary.ai_requests);
    setText('history-ledger', `Independent credit events in this period: ${count(history.summary.ai_charged.value)} charged and ${count(history.summary.ai_released.value)} refunded. A charge does not establish that a response was completed. These records are separate from the app telemetry above.`);
  }
  renderAi(server, measured);
  renderAiPerformance();
  if (!measured) {
    for (const id of ['metric-active', 'metric-readers', 'metric-ai', 'metric-time', 'reading-total', 'reading-average', 'reading-adoption']) unmeasured(id);
    for (const id of ['change-active', 'change-readers', 'change-ai', 'change-time']) { setText(id, 'App telemetry has not started'); $(id).removeAttribute('title'); delete $(id).dataset.direction; }
    setText('telemetry-note', 'Not measured yet. App usage, reader engagement, and feature actions begin with the analytics-enabled app release. Historical account and credit records do not measure this activity.');
    sectionEmpty($('feature-list'), 'Not measured yet. Feature counts begin when analytics-enabled Kodi installations send activity.');
    setText('feature-tag', 'NOT MEASURED YET');
    $('legacy-features').hidden = true;
    sectionEmpty($('version-list'), 'Not measured yet. App versions arrive with device events.');
    if (!server) {
      for (const id of ['new-devices', 'returning-devices', 'total-sessions', 'total-ai-requests']) setText(id, 'Not measured');
      setText('adoption-percent', 'Not measured');
    }
  } else {
    const detail = coverage ? `${count(coverage.instrumented_devices)} version-2 devices and ${count(coverage.legacy_devices)} legacy devices in this period.` : 'This response uses legacy event definitions.';
    setText('telemetry-note', `Pseudonymous app events measure reader engagement and feature usage separately from account records. ${detail}`);
    setText('reading-coverage', `Version coverage: ${detail}`);
    if (coverage?.legacy_devices > 0 || !coverage) setText('change-time', 'Includes legacy reader timing; see version coverage');
    setText('feature-tag', coverage?.semantic_features_available ? 'MEANINGFUL ACTIONS' : 'PARTIAL COVERAGE');
    renderFeatures();
    renderVersions();
  }
  renderCountries();
  renderFeatureUsage();
  renderRecent();
  renderDaily();
  renderChart();
  setText('footer-status', `${state.snapshotMode ? 'SAVED DATABASE SNAPSHOT' : 'UPDATED'} ${longDate.format(date(captured)).toUpperCase()} · UTC`);
  $('export').disabled = false;
}
function renderAi(server, measured) {
  const summary = state.data.summary;
  const outcomes = state.data.ai_outcomes;
  const started = server ? server.summary.ai_requests.value : outcomes?.started ?? summary.ai_requests.value;
  setText('ai-requests', server || measured ? count(started) : 'Not measured');
  setText('ai-device-note', server ? `${count(server.summary.ai_accounts.value)} distinct accounts reserved AI requests in this period.` : `${count(summary.ai_users.value)} distinct devices asked Kodi AI for help.${outcomes?.legacy_started ? ` ${count(outcomes.legacy_started)} legacy starts have no request correlation and remain Unknown.` : ''}`);
  if (server) {
    setText('ai-completed', count(server.summary.ai_charged.value));
    setText('ai-failed', count(server.summary.ai_released.value));
    setText('ai-unresolved', count(started));
    setText('ai-success', 'Independent credit events');
    return;
  }
  if (!outcomes) {
    for (const id of ['ai-completed', 'ai-failed', 'ai-unresolved', 'ai-cancelled']) setText(id, measured ? 'Unavailable' : 'Not measured');
    setText('ai-success', measured ? 'Legacy outcomes are uncorrelated' : 'Not measured yet');
    setText('ai-outcome-note', 'Older events do not correlate request starts and outcomes. Completed, failed, stopped, and Unknown cohort counts become available with the updated analytics backend. Legacy daily events remain in the activity log and CSV.');
    return;
  }
  for (const [key, id] of Object.entries({ completed: 'ai-completed', failed: 'ai-failed', cancelled: 'ai-cancelled', unknown: 'ai-unresolved' })) setText(id, measured ? count(outcomes[key]) : 'Not measured');
  const settled = outcomes.completed + outcomes.failed + outcomes.cancelled;
  setText('ai-success', started > 0 ? `${count(settled)} of ${count(started)} have a known outcome` : measured ? '0 requests started' : 'Not measured yet');
  $('ai-completed-bar').style.width = `${percent(outcomes.completed, started)}%`;
  $('ai-failed-bar').style.width = `${percent(outcomes.failed, started)}%`;
  $('ai-cancelled-bar').style.width = `${percent(outcomes.cancelled, started)}%`;
  $('ai-unknown-bar').style.width = `${percent(outcomes.unknown, started)}%`;
  $('outcome-track').setAttribute('aria-label', `${count(outcomes.completed)} completed, ${count(outcomes.failed)} failed, ${count(outcomes.cancelled)} stopped, ${count(outcomes.unknown)} unknown out of ${count(started)} requests started in the period`);
}
function renderAiPerformance() {
  const performance = state.data?.ai_performance;
  const available = performance?.available === true;
  const samples = available ? performance.completed.response_time_ms.samples : 0;
  const status = !state.data ? 'PRIVATE' : !available ? 'NOT MEASURED YET' : samples > 0 ? 'COMPLETED RESPONSES' : 'NO COMPLETED SAMPLES';
  setText('ai-performance-status', status);
  const cards = $('ai-timing-cards');
  cards.replaceChildren();
  for (const [key, definition] of Object.entries(AI_TIMING_METRICS)) {
    const metric = available ? performance.completed[key] : null;
    const article = document.createElement('article'); article.className = 'ai-timing-card';
    const label = cell(definition.label, 'h3');
    const value = cell(!state.data ? '—' : !available ? 'Not measured yet' : milliseconds(metric.average), 'p'); value.className = 'ai-timing-value';
    value.classList.toggle('is-unmeasured', !metric || metric.samples === 0);
    const caption = cell('Average · completed responses', 'p'); caption.className = 'ai-timing-caption';
    const definitionText = cell(definition.description, 'p'); definitionText.className = 'ai-timing-definition';
    const distribution = document.createElement('dl'); distribution.className = 'ai-timing-distribution';
    for (const [stat, name] of [['p50', 'Median'], ['p95', '95th percentile']]) {
      const row = document.createElement('div');
      row.append(cell(name, 'dt'), cell(metric?.samples > 0 ? milliseconds(metric[stat]) : '—', 'dd'));
      distribution.append(row);
    }
    const sample = cell(!state.data ? 'Sign in to view timings.' : !available ? 'Awaiting timing measurements.' : `${count(metric.samples)} ${metric.samples === 1 ? 'sample' : 'samples'}`, 'p'); sample.className = 'ai-timing-samples';
    article.append(label, value, caption, definitionText, distribution, sample); cards.append(article);
  }
  const body = $('ai-timing-table');
  body.replaceChildren();
  if (!available) {
    emptyTable(body, 6, state.data ? 'Not measured yet. Updated Kodi apps must report request timings.' : 'Sign in to view response timings.');
  } else {
    for (const [outcome, label] of Object.entries(AI_TIMING_OUTCOMES)) {
      for (const [key, definition] of Object.entries(AI_TIMING_METRICS)) {
        const metric = performance[outcome][key];
        const row = document.createElement('tr');
        const heading = cell(label, 'th'); heading.scope = 'row';
        row.append(heading, cell(definition.label), cell(count(metric.samples)), cell(milliseconds(metric.average)), cell(milliseconds(metric.p50)), cell(milliseconds(metric.p95)));
        body.append(row);
      }
    }
  }
  if (!state.data) {
    $('ai-timing-details').open = false;
    setText('ai-performance-coverage', 'Sign in to see Ask AI response timings.');
    setText('ai-timing-other-outcomes', 'Failed and stopped requests are measured separately.');
    return;
  }
  const snapshot = state.snapshotMode ? 'Saved snapshot. ' : '';
  if (!available) {
    setText('ai-performance-coverage', `${snapshot}Not measured yet. Response timings appear when updated Kodi apps send measurements; older requests and credit records have no timing data.`);
    setText('ai-timing-other-outcomes', 'Failed and stopped timings are not measured yet.');
    return;
  }
  const coverage = performance.coverage;
  const older = coverage.older_devices > 0 ? ` ${count(coverage.older_devices)} older ${coverage.older_devices === 1 ? 'device does' : 'devices do'} not report timings.` : '';
  setText('ai-performance-coverage', `${snapshot}${count(coverage.devices)} ${coverage.devices === 1 ? 'device can' : 'devices can'} report request timings.${older} Only requests started in the selected period with a recorded timing are included.`);
  setText('ai-timing-other-outcomes', `${count(samples)} completed ${samples === 1 ? 'response' : 'responses'} with timing samples. Separate measurements: ${count(performance.failed.response_time_ms.samples)} failed and ${count(performance.cancelled.response_time_ms.samples)} stopped requests. Requests ending before text have no first-text latency or streaming sample.`);
}
function aiPerformanceCsvRows(data) {
  const performance = data.ai_performance;
  const rows = [[], ['AI performance status', performance?.available ? 'Measured' : 'Not measured yet'], ['AI performance previous-period capability', performance?.previous_available ? 'Measured' : 'Not measured yet'], ['AI timing definition', 'Response: request start to terminal outcome; latency: request start to first visible text; streaming: first visible text to terminal outcome'], ['AI timing cohort', 'Requests started in the selected period; completed, failed and stopped outcomes remain separate']];
  if (performance) rows.push(['Timing-capable devices', performance.coverage.devices], ['Older devices without timing capability', performance.coverage.older_devices]);
  rows.push(['AI timing outcome', 'Metric (milliseconds)', 'Timed requests in outcome', 'Samples', 'Average (ms)', 'Median / p50 (ms)', 'p95 (ms)']);
  if (performance?.available) {
    for (const [outcome, label] of Object.entries(AI_TIMING_OUTCOMES)) {
      for (const key of Object.keys(AI_TIMING_METRICS)) {
        const metric = performance[outcome][key];
        rows.push([label, key, performance[outcome].requests, metric.samples, metric.average ?? '', metric.p50 ?? '', metric.p95 ?? '']);
      }
    }
  }
  return rows;
}
function appendFeatureRows(container, rows) {
  const maximum = Math.max(1, ...rows.filter(item => item.measured).map(item => item.count));
  for (const feature of rows) {
    const row = document.createElement('div'); row.className = 'feature-row';
    const label = document.createElement('span'); label.className = 'feature-name'; label.textContent = eventName(feature.name);
    const bar = document.createElement('div'); bar.className = 'feature-bar'; bar.setAttribute('aria-hidden', 'true');
    const fill = document.createElement('span'); fill.style.width = `${feature.measured ? feature.count / maximum * 100 : 0}%`; bar.append(fill);
    const amount = document.createElement('span'); amount.className = 'feature-count'; amount.textContent = feature.measured ? count(feature.count) : 'Not measured';
    const devices = document.createElement('span'); devices.textContent = feature.measured ? `${count(feature.users)} ${feature.users === 1 ? 'device' : 'devices'}` : 'Needs version 2'; amount.append(devices);
    row.append(label, bar, amount); container.append(row);
  }
}
function renderFeatures() {
  const semantic = Boolean(state.data.coverage?.semantic_features_available);
  const rows = FEATURE_NAMES.map(name => ({ ...(state.data.features.find(item => item.name === name) || { name, count: 0, users: 0 }), measured: !SEMANTIC_FEATURES.has(name) || semantic }));
  $('feature-list').replaceChildren();
  appendFeatureRows($('feature-list'), rows);
  const legacy = LEGACY_FEATURES.map(name => ({ ...(state.data.features.find(item => item.name === name) || { name, count: 0, users: 0 }), measured: true }));
  $('legacy-features').hidden = !legacy.some(item => item.count > 0);
  $('legacy-feature-list').replaceChildren();
  if (!$('legacy-features').hidden) appendFeatureRows($('legacy-feature-list'), legacy);
  setText('feature-note', semantic ? `Notes and drawings count new items and meaningful editing sessions. Repeated autosaves, restored data, empty drafts, and failed saves are excluded.${state.data.coverage.legacy_devices > 0 ? ' Partial coverage: legacy devices do not report these new measurements.' : ''}` : 'New note and drawing metrics have not been measured by version-2 devices in this period. General feature events and any legacy autosave counts are shown separately.');
}
function featureUsageMetrics(groupName) {
  const metrics = Object.fromEntries(Object.keys(FEATURE_USAGE_GROUPS[groupName].metrics).map(key => [key, { value: null, previous: null }]));
  const source = state.data?.feature_usage?.[groupName];
  if (source) {
    for (const key of Object.keys(metrics)) metrics[key] = {
      value: source.available ? source[key].value : null,
      previous: source.previous_available === true ? source[key].previous : null,
    };
  }
  if (groupName === 'sketching') {
    if (!source && state.data?.coverage?.semantic_features_available) {
      for (const [key, event] of Object.entries({ created: 'sketch_created', edit_sessions: 'sketch_edit_session' })) {
        metrics[key] = { value: state.data.features.find(item => item.name === event)?.count ?? 0, previous: null };
      }
    }
    for (const key of ['opened', 'deleted']) metrics[key] = {
      value: state.data?.coverage?.feature_usage_available ? metrics[key].value : null,
      previous: state.data?.coverage?.feature_usage_previous_available ? metrics[key].previous : null,
    };
  }
  return metrics;
}
function featureUsageValue(value, { seconds = false } = {}) {
  return value === null ? state.data ? 'Not measured yet' : '—' : seconds ? duration(value) : count(value);
}
function renderFeatureUsage() {
  const container = $('feature-usage-cards');
  const expanded = new Set(state.data ? [...container.querySelectorAll('details[open]')].map(item => item.dataset.group) : []);
  container.replaceChildren();
  for (const [key, definition] of Object.entries(FEATURE_USAGE_GROUPS)) {
    const metrics = featureUsageMetrics(key);
    const primary = metrics[definition.primary];
    const measured = Object.values(metrics).some(item => item.value !== null);
    const complete = Object.values(metrics).every(item => item.value !== null);
    const card = document.createElement('article');
    card.className = 'panel feature-usage-card';
    const heading = document.createElement('h3');
    heading.id = `feature-usage-${key}-title`;
    heading.textContent = definition.title;
    card.setAttribute('aria-labelledby', heading.id);
    const header = document.createElement('div'); header.className = 'feature-usage-card-header';
    const badge = document.createElement('span'); badge.className = 'feature-usage-status';
    badge.textContent = !state.data ? 'PRIVATE' : !measured ? 'NOT MEASURED YET' : complete ? 'MEASURED' : 'PARTIAL COVERAGE';
    header.append(heading, badge);
    const value = document.createElement('p'); value.className = 'feature-usage-primary';
    value.classList.toggle('is-unmeasured', primary.value === null);
    value.textContent = featureUsageValue(primary.value, { seconds: definition.primary === 'seconds' });
    const caption = document.createElement('p'); caption.className = 'feature-usage-caption'; caption.textContent = definition.caption;
    const comparison = document.createElement('p'); comparison.className = 'feature-usage-comparison';
    comparison.textContent = primary.previous !== null ? `Previous period: ${featureUsageValue(primary.previous, { seconds: definition.primary === 'seconds' })}` : primary.value === null ? state.data ? 'Awaiting feature measurements.' : 'Sign in to view usage.' : 'Previous period unavailable in this report.';
    const summary = document.createElement('dl'); summary.className = 'feature-usage-summary';
    for (const metric of definition.overview) {
      const row = document.createElement('div');
      const amount = cell(featureUsageValue(metrics[metric].value), 'dd');
      if (metrics[metric].value === null) amount.className = 'feature-usage-unavailable';
      row.append(cell(definition.metrics[metric], 'dt'), amount);
      summary.append(row);
    }
    const details = document.createElement('details'); details.className = 'feature-usage-details'; details.dataset.group = key; details.open = expanded.has(key);
    const toggle = document.createElement('summary'); toggle.textContent = 'View all measurements';
    const scroll = document.createElement('div'); scroll.className = 'table-scroll';
    const table = document.createElement('table'); table.className = 'feature-usage-table';
    const tableCaption = document.createElement('caption'); tableCaption.className = 'sr-only'; tableCaption.textContent = `${definition.title} measurements for this and the previous period`;
    const head = document.createElement('thead'); const headerRow = document.createElement('tr');
    for (const label of ['Measurement', 'This period', 'Previous']) { const item = cell(label, 'th'); item.scope = 'col'; headerRow.append(item); }
    head.append(headerRow);
    const body = document.createElement('tbody');
    for (const [metric, label] of Object.entries(definition.metrics)) {
      const row = document.createElement('tr'); const name = cell(label, 'th'); name.scope = 'row';
      row.append(name, cell(featureUsageValue(metrics[metric].value)), cell(metrics[metric].previous === null && metrics[metric].value !== null ? 'Unavailable' : featureUsageValue(metrics[metric].previous)));
      body.append(row);
    }
    table.append(tableCaption, head, body); scroll.append(table); details.append(toggle, scroll);
    card.append(header, value, caption, comparison, summary, details); container.append(card);
  }
  if (!state.data) { setText('feature-usage-coverage', 'Sign in to see feature activity.'); return; }
  const coverage = state.data.coverage;
  const snapshot = state.snapshotMode ? 'Saved snapshot. ' : '';
  if (coverage?.feature_usage_available) {
    const measured = coverage.feature_usage_devices;
    const devices = typeof measured === 'number' ? `${count(measured)} ${measured === 1 ? 'device reports' : 'devices report'} the newer feature measurements.` : 'Updated Kodi apps report these feature measurements.';
    const partial = coverage.feature_usage_legacy_devices > 0 ? ` ${count(coverage.feature_usage_legacy_devices)} older devices do not report reminder, audio, or drawing open/delete actions.` : '';
    setText('feature-usage-coverage', `${snapshot}${devices}${partial} Counts describe recorded actions; they do not measure completed research or drawing time.`);
  } else {
    setText('feature-usage-coverage', `${snapshot}${coverage?.semantic_features_available ? 'Drawing creation and editing sessions are measured. Reminder, recording, read-aloud, and drawing open/delete measurements have not started in this period.' : 'Not measured yet. Feature counts appear when analytics-enabled Kodi apps send the corresponding activity.'} Missing measurements are not zero.`);
  }
}
function renderCountries() {
  const container = $('country-list');
  if (!Array.isArray(state.data.countries)) { sectionEmpty(container, 'Not measured yet. Country observations begin with the updated analytics backend; historical snapshots have no location data.'); return; }
  if (!state.data.countries.length) { sectionEmpty(container, hasTelemetry() ? '0 active devices in this period, so there are no connection countries to show.' : 'Not measured yet. Country totals appear when the first analytics-enabled installations send activity.'); return; }
  const total = state.data.summary.active_users.value;
  const rows = [...state.data.countries].sort((a, b) => b.devices - a.devices || String(a.country_code || '').localeCompare(String(b.country_code || '')));
  container.replaceChildren();
  for (const country of rows) {
    const row = document.createElement('div'); row.className = 'country-row';
    const label = document.createElement('span'); label.className = 'country-name';
    let name = 'Unknown';
    if (country.country_code) { try { name = countryNames?.of(country.country_code) || country.country_code; } catch { name = country.country_code; } }
    label.textContent = name;
    const share = document.createElement('span'); share.className = 'country-share'; share.textContent = formatPercent(percent(country.devices, total));
    const bar = document.createElement('div'); bar.className = 'country-bar'; bar.setAttribute('aria-hidden', 'true');
    const fill = document.createElement('span'); fill.style.width = `${percent(country.devices, total)}%`; bar.append(fill);
    const amount = document.createElement('strong'); amount.className = 'country-count'; amount.textContent = `${count(country.devices)} ${country.devices === 1 ? 'device' : 'devices'}`;
    row.append(label, bar, share, amount); container.append(row);
  }
}
function renderVersions() {
  const container = $('version-list');
  const versions = state.data.versions;
  if (!versions.length) { sectionEmpty(container, 'No app versions reported in this period yet.'); return; }
  const total = state.data.summary.active_users.value;
  container.replaceChildren();
  for (const version of versions) {
    const row = document.createElement('div');
    row.className = 'version-row';
    const label = document.createElement('span');
    label.className = 'version-name';
    label.textContent = version.version;
    const bar = document.createElement('div');
    bar.className = 'version-bar';
    bar.setAttribute('aria-hidden', 'true');
    const fill = document.createElement('span');
    fill.style.width = `${percent(version.users, total)}%`;
    bar.append(fill);
    const value = document.createElement('span');
    value.className = 'version-value';
    value.textContent = count(version.users);
    value.title = `${count(version.users)} ${version.users === 1 ? 'device' : 'devices'}`;
    const share = document.createElement('span');
    share.textContent = ` / ${formatPercent(percent(version.users, total))}`;
    value.append(share);
    row.append(label, bar, value);
    container.append(row);
  }
}
function renderRecent() {
  const container = $('recent-table');
  const recent = historicalLead() ? state.data.server_metrics?.recent || [] : state.data.recent;
  if (!recent.length) { emptyTable(container, 3, historicalLead() ? 'No account or AI ledger records in this period.' : 'No activity received in this period yet.'); return; }
  container.replaceChildren();
  for (const event of recent) {
    const row = document.createElement('tr');
    row.append(cell(eventName(event.name)), cell(shortDate.format(date(event.date))), cell(count(event.count)));
    container.append(row);
  }
}
function renderDaily() {
  const container = $('daily-table');
  const server = historicalLead() ? state.data.server_metrics : null;
  const daily = server?.daily || state.data.daily;
  if (!daily.length) { emptyTable(container, server ? 4 : 6, 'No daily records in this period.'); return; }
  container.replaceChildren();
  for (const day of [...daily].reverse()) {
    const row = document.createElement('tr');
    if (server) row.append(cell(longDate.format(date(day.date))), cell(count(day.new_accounts)), cell(count(day.ai_requests)), cell(count(day.ai_accounts)));
    else row.append(cell(longDate.format(date(day.date))), cell(count(day.active_users)), cell(count(day.readers)), cell(count(day.ai_users)), cell(duration(day.reading_seconds)), cell(count(day.ai_requests)));
    container.append(row);
  }
}
function chartTooltip(day, pointX, chartWidth) {
  const tooltip = $('chart-tooltip');
  tooltip.replaceChildren();
  const heading = document.createElement('strong');
  heading.textContent = longDate.format(date(day.date));
  tooltip.append(heading);
  for (const series of state.series) {
    const row = document.createElement('span');
    row.textContent = SERIES_NAMES[series];
    const value = document.createElement('b');
    value.textContent = count(day[series]);
    row.append(value);
    tooltip.append(row);
  }
  tooltip.hidden = false;
  const stage = $('chart-stage');
  const relativeX = pointX / chartWidth * stage.clientWidth;
  tooltip.style.left = `${Math.max(0, Math.min(stage.clientWidth - tooltip.offsetWidth, relativeX + 12))}px`;
  tooltip.style.top = '14px';
}
function renderChart() {
  const svg = $('activity-chart');
  const chartWidth = Math.max(280, $('chart-stage').clientWidth);
  svg.setAttribute('viewBox', `0 0 ${chartWidth} 244`);
  const title = svgElement('title', { id: 'chart-title' }, 'Daily app usage');
  const description = svgElement('desc', { id: 'chart-description' }, state.data ? historicalLead() ? `New registrations, reserved AI requests, and distinct AI accounts per UTC day for the last ${state.days} days. Full values are available in the daily data table below.` : `Distinct active, reader, and AI devices each UTC day for the last ${state.days} days. Full values are available in the daily data table below.` : 'Sign in to see daily active, reading, and AI devices.');
  svg.replaceChildren(title, description);
  $('chart-tooltip').hidden = true;
  const daily = (historicalLead() ? state.data?.server_metrics?.daily : state.data?.daily) || [];
  const series = [...state.series];
  const left = 33, right = chartWidth - 15, top = 14, bottom = 212;
  const highest = Math.max(0, ...daily.flatMap((item) => series.map((key) => item[key])));
  const stepRaw = Math.max(1, highest / 4);
  const magnitude = 10 ** Math.floor(Math.log10(stepRaw));
  const step = Math.ceil(stepRaw / magnitude) * magnitude;
  const maximum = step * 4;
  const y = (value) => bottom - value / maximum * (bottom - top);
  const x = (index) => daily.length <= 1 ? (left + right) / 2 : left + index / (daily.length - 1) * (right - left);
  for (let i = 0; i <= 4; i += 1) {
    const value = i * step;
    const position = y(value);
    svg.append(svgElement('line', { x1: left, x2: right, y1: position, y2: position, class: 'chart-grid' }));
    svg.append(svgElement('text', { x: left - 10, y: position + 3, 'text-anchor': 'end', class: 'chart-axis' }, state.data ? count(value) : '—'));
  }
  if (daily.length) {
    const indexes = new Set([0, Math.round((daily.length - 1) / 3), Math.round((daily.length - 1) * 2 / 3), daily.length - 1]);
    for (const index of indexes) svg.append(svgElement('text', { x: x(index), y: 238, 'text-anchor': index === 0 ? 'start' : index === daily.length - 1 ? 'end' : 'middle', class: 'chart-axis' }, shortDate.format(date(daily[index].date))));
  }
  const empty = $('chart-empty');
  const hasActivity = daily.some((day) => (historicalLead() ? SERVER_SERIES : DEVICE_SERIES).some((key) => day[key] > 0));
  empty.hidden = hasActivity && series.length > 0;
  empty.querySelector('strong').textContent = !state.data ? 'Your activity story starts here' : !series.length ? 'Choose a line to explore' : 'A quiet chapter, for now';
  empty.querySelector('span:last-child').textContent = !state.data ? 'Connect to see real usage from Kodi.' : !series.length ? 'Use the legend above to show daily activity.' : historicalLead() ? 'No registrations or AI reservations recorded in this period.' : 'No device activity recorded in this period yet.';
  if (!hasActivity || !series.length) return;
  for (const key of series) {
    const line = daily.map((day, index) => `${index === 0 ? 'M' : 'L'}${x(index).toFixed(2)} ${y(day[key]).toFixed(2)}`).join(' ');
    if (key === 'active_users' || key === 'new_accounts') svg.append(svgElement('path', { d: `${line} L${x(daily.length - 1)} ${bottom} L${x(0)} ${bottom} Z`, fill: '#416f4d', opacity: '.045' }));
    svg.append(svgElement('path', { d: line, fill: 'none', stroke: COLORS[key], 'stroke-width': key === 'active_users' || key === 'new_accounts' ? '2.3' : '2', 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
  }
  const focusLine = svgElement('line', { x1: 0, x2: 0, y1: top, y2: bottom, stroke: '#9aaf8c', 'stroke-width': '1', 'stroke-dasharray': '3 3', visibility: 'hidden' });
  svg.append(focusLine);
  for (const [index, day] of daily.entries()) {
    const point = svgElement('g', { class: 'chart-point', tabindex: '0', role: 'img', 'aria-label': `${longDate.format(date(day.date))}: ${series.map((key) => `${count(day[key])} ${SERIES_NAMES[key].toLowerCase()}`).join(', ')}` });
    const position = x(index);
    const width = (right - left) / Math.max(1, daily.length - 1);
    point.append(svgElement('rect', { x: Math.max(left, position - width / 2), y: top, width: Math.min(right, position + width / 2) - Math.max(left, position - width / 2), height: bottom - top, fill: 'transparent' }));
    for (const key of series) point.append(svgElement('circle', { cx: position, cy: y(day[key]), r: daily.length === 1 ? '3' : '2', fill: COLORS[key], opacity: daily.length === 1 ? '1' : '0' }));
    const show = () => { chartTooltip(day, position, chartWidth); focusLine.setAttribute('x1', position); focusLine.setAttribute('x2', position); focusLine.setAttribute('visibility', 'visible'); for (const circle of point.querySelectorAll('circle')) circle.setAttribute('opacity', '1'); };
    const hide = () => { $('chart-tooltip').hidden = true; focusLine.setAttribute('visibility', 'hidden'); if (daily.length > 1) for (const circle of point.querySelectorAll('circle')) circle.setAttribute('opacity', '0'); };
    point.addEventListener('pointerenter', show);
    point.addEventListener('pointerleave', hide);
    point.addEventListener('focus', show);
    point.addEventListener('blur', hide);
    point.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
        event.preventDefault();
        const sibling = event.key === 'ArrowRight' ? point.nextElementSibling : point.previousElementSibling;
        if (sibling?.classList.contains('chart-point')) sibling.focus();
      }
      if (event.key === 'Escape') hide();
    });
    svg.append(point);
  }
  setText('chart-total', historicalLead() ? `${count(state.data.server_metrics.summary.ai_requests.value)} AI requests in period` : `${count(state.data.summary.active_users.value)} active devices in period`);
}
function csvValue(value) {
  let text = String(value ?? '');
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}
function exportCsv() {
  const data = state.data;
  if (!data) return;
  const rows = [ ['Kodi Reader analytics'], ['Generated at (UTC)', data.generated_at], ['Period start (UTC)', data.period.start], ['Period end (UTC)', data.period.end], ['Data source', data.data_source?.kind || 'authenticated_server'], ['Captured at (UTC)', data.data_source?.captured_at || data.generated_at], ['Measurement', 'Pseudonymous device telemetry; account and credit records are separate'], ['Reader engagement', 'Reading, notes, drawing and Ask AI in the foreground reader workspace; excludes idle time'], ['Country measurement', 'Latest approximate upload-country observation in the period, not the location of past offline activity'] ];
  if (data.server_metrics) {
    rows.push(['Account and AI credit records · all time', 'Value']);
    for (const [key, value] of Object.entries(data.server_metrics.totals)) rows.push([key, value]);
    rows.push([], ['Account and AI credit metric', 'Selected period', 'Previous period']);
    for (const [key, value] of Object.entries(data.server_metrics.summary)) rows.push([key, value.value, value.previous]);
    rows.push([], ['Server date (UTC)', 'New registrations', 'AI accounts', 'AI requests reserved', 'AI requests charged', 'AI requests refunded']);
    for (const day of data.server_metrics.daily) rows.push([day.date, day.new_accounts, day.ai_accounts, day.ai_requests, day.ai_charged, day.ai_released]);
    rows.push([], ['Server event date (UTC)', 'Event', 'Count']);
    for (const event of data.server_metrics.recent) rows.push([event.date, event.name, event.count]);
  }
  rows.push([], ['Device telemetry status', hasTelemetry() ? (data.summary.active_users.value > 0 ? 'Events received in period' : 'Recorded zero activity in selected period') : 'Not measured yet: app telemetry has not started'], ['Device telemetry metric', 'Selected period', 'Previous period']);
  const summaryNames = { active_users: 'Active devices', readers: 'Reader devices', ai_users: 'AI devices', reading_seconds: 'Reader engagement seconds', new_users: 'New devices', sessions: 'Foreground activations', ai_requests: 'AI requests started', ai_completed: 'Legacy independent AI completion events', ai_failed: 'Legacy independent AI failure events' };
  for (const [key, label] of Object.entries(summaryNames)) rows.push([label, hasTelemetry() ? data.summary[key].value : '', hasTelemetry() ? data.summary[key].previous : '']);
  if (data.summary.returning_users) rows.push(['Returning devices', hasTelemetry() ? data.summary.returning_users.value : '', hasTelemetry() ? data.summary.returning_users.previous : '']);
  if (data.coverage) { rows.push([], ['Coverage', 'Value']); for (const [key, value] of Object.entries(data.coverage)) rows.push([key, value]); }
  rows.push([], ['Feature group', 'Measurement', 'Selected period', 'Previous period', 'Measurement status']);
  for (const [group, definition] of Object.entries(FEATURE_USAGE_GROUPS)) {
    const metrics = featureUsageMetrics(group);
    for (const [key, label] of Object.entries(definition.metrics)) {
      const metric = metrics[key];
      const status = metric.value === null ? metric.previous === null ? 'Not measured yet' : 'Current period unavailable; previous measured' : metric.previous === null ? 'Measured; previous period unavailable' : 'Measured';
      rows.push([definition.title, label, metric.value ?? '', metric.previous ?? '', status]);
    }
  }
  if (data.ai_outcomes) { rows.push([], ['AI request cohort outcome', 'Count']); for (const [key, value] of Object.entries(data.ai_outcomes)) rows.push([key, hasTelemetry() ? value : '']); }
  rows.push(...aiPerformanceCsvRows(data));
  rows.push([], ['Connection country (upload origin)', 'Distinct active devices']);
  if (Array.isArray(data.countries)) for (const country of data.countries) rows.push([country.country_code || 'Unknown', country.devices]);
  else rows.push(['Not measured yet', '']);
  rows.push([], ['Date (UTC)', 'Active devices', 'Reader devices', 'AI devices', 'Reader engagement seconds', 'AI requests started']);
  if (hasTelemetry()) for (const day of data.daily) rows.push([day.date, day.active_users, day.readers, day.ai_users, day.reading_seconds, day.ai_requests]);
  rows.push([], ['Feature event', 'Event count', 'Distinct devices']);
  if (hasTelemetry()) for (const feature of data.features) rows.push([feature.name, SEMANTIC_FEATURES.has(feature.name) && !data.coverage?.semantic_features_available ? '' : feature.count, SEMANTIC_FEATURES.has(feature.name) && !data.coverage?.semantic_features_available ? '' : feature.users]);
  rows.push([], ['App version', 'Distinct devices']);
  for (const version of data.versions) rows.push([version.version, version.users]);
  rows.push([], ['Recent date (UTC)', 'Event', 'Count']);
  for (const event of data.recent) rows.push([event.date, event.name, event.count]);
  const blob = new Blob(['\uFEFF', rows.map((row) => row.map(csvValue).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `kodi-analytics-${state.days}d-${data.generated_at.slice(0, 10)}.csv`;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
$('google-sign-in').addEventListener('click', (event) => {
  if (state.checkingSession || state.signingOut) event.preventDefault();
});
$('period').addEventListener('change', () => {
  state.days = Number($('period').value);
  state.data = null;
  state.request += 1;
  state.controller?.abort();
  setLoading(false);
  resetValues();
  notice();
  if (state.authenticated || state.snapshotMode) load();
});
$('refresh').addEventListener('click', () => load());
$('connect-live').addEventListener('click', () => { clearDashboard({ focus: false }); restoreSession(); });
$('sign-out').addEventListener('click', signOut);
$('mobile-sign-out').addEventListener('click', signOut);
$('export').addEventListener('click', exportCsv);
for (const button of document.querySelectorAll('[data-series]')) button.addEventListener('click', () => {
  const key = button.dataset.series;
  if (state.series.has(key)) state.series.delete(key); else state.series.add(key);
  button.setAttribute('aria-pressed', String(state.series.has(key)));
  renderChart();
});
const navLinks = [...document.querySelectorAll('.side-nav a')];
for (const link of navLinks) link.addEventListener('click', () => {
  for (const item of navLinks) item.removeAttribute('aria-current');
  link.setAttribute('aria-current', 'page');
});
if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) {
      const selected = navLinks.find((link) => link.hash === `#${entry.target.id}`);
      if (selected) { for (const link of navLinks) link.removeAttribute('aria-current'); selected.setAttribute('aria-current', 'page'); }
    }
  }, { rootMargin: '-10% 0px -65% 0px', threshold: 0 });
  for (const id of ['overview', 'reading', 'ai', 'ai-performance', 'countries', 'features', 'feature-usage', 'activity']) observer.observe($(id));
}
document.addEventListener('visibilitychange', () => { if (!document.hidden && state.authenticated && !state.loading && Date.now() - state.lastAttempt >= 60000) load(); });
window.addEventListener('resize', renderChart);
window.addEventListener('pagehide', () => {
  state.authRequest += 1;
  state.authController?.abort();
  state.authController = null;
  state.checkingSession = false;
  clearDashboard({ focus: false });
});
window.addEventListener('pageshow', (event) => { if (event.persisted) initialize(); });
async function initialize() {
  const request = state.authRequest;
  resetValues();
  const message = callbackMessage();
  if (LOCAL_HOST && !message && await load({ snapshot: true, bootstrap: true })) return;
  if (request !== state.authRequest) return;
  await restoreSession({ message });
}
initialize();
