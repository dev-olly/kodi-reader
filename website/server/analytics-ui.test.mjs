import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Exercise the shipped dashboard functions without starting authentication or
// requiring a browser connection. Elements are checked against the actual HTML.
function dashboard() {
  class Element {
    constructor() {
      this.children = [];
      this.value = '';
      this.open = false;
      this.classList = { toggle() {} };
    }
    set textContent(value) { this.value = String(value); this.children = []; }
    get textContent() { return this.value + this.children.map(child => child.textContent).join(' '); }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.value = ''; this.children = children; }
  }
  const html = readFileSync(new URL('../analytics.html', import.meta.url), 'utf8');
  const elements = new Map([...html.matchAll(/\bid="([^"]+)"/g)].map(match => [match[1], new Element()]));
  const context = vm.createContext({
    Intl, URL, console,
    location: { hostname: 'www.kodi-reader.app' },
    document: { getElementById: id => elements.get(id), createElement: () => new Element() },
  });
  const source = readFileSync(new URL('../analytics.js', import.meta.url), 'utf8');
  const code = source.slice(0, source.indexOf("$('google-sign-in').addEventListener"));
  vm.runInContext(`${code}\nglobalThis.dashboard = { state, validateData, renderAiPerformance, aiPerformanceCsvRows, milliseconds };`, context);
  return { ...context.dashboard, elements };
}

function stats(value = 0, samples = 1) {
  return { samples, average: samples ? value : null, p50: samples ? value : null, p95: samples ? value : null };
}
function group(samples = 0, response = 0, latency = 0, streaming = 0) {
  return { requests: samples, response_time_ms: stats(response, samples), latency_ms: stats(latency, samples), streaming_time_ms: stats(streaming, samples) };
}
function performance() {
  return {
    available: true, previous_available: false,
    coverage: { devices: 2, older_devices: 1 },
    completed: group(1, 2500, 500, 2000), failed: group(), cancelled: group(),
  };
}
function payload(timing = performance()) {
  const data = {
    days: 30, generated_at: '2026-11-08T12:00:00Z',
    period: { start: '2026-10-10T00:00:00Z', end: '2026-11-08T12:00:00Z' },
    summary: Object.fromEntries(['active_users', 'readers', 'ai_users', 'reading_seconds', 'new_users', 'sessions', 'ai_requests', 'ai_completed', 'ai_failed'].map(key => [key, { value: 0, previous: 0 }])),
    daily: [], features: [], versions: [], recent: [],
  };
  if (timing !== undefined) data.ai_performance = timing;
  return data;
}

test('dashboard accepts legacy data and finite timing stats, including measured zero', () => {
  const app = dashboard();
  const legacy = payload(); delete legacy.ai_performance;
  assert.equal(app.validateData(legacy, 30), legacy);
  const data = payload();
  data.ai_performance.completed = group(1);
  assert.equal(app.validateData(data, 30), data);
  assert.equal(app.milliseconds(0), '0 ms');
  assert.equal(app.milliseconds(null), 'No samples');
});

test('dashboard refuses malformed timing data rather than rendering fabricated values', () => {
  const app = dashboard();
  const mutations = [
    data => { data.ai_performance.completed.latency_ms.average = NaN; },
    data => { data.ai_performance.completed.response_time_ms.samples = 2; },
    data => { data.ai_performance.completed.streaming_time_ms.p95 = null; },
    data => { data.ai_performance.failed.latency_ms.average = 0; },
    data => { data.ai_performance.completed.response_time_ms.p95 = 86400001; },
    data => { data.ai_performance.coverage.devices = -1; },
    data => { data.ai_performance.completed.latency_ms.p50 = 1000; },
    data => { data.ai_performance.available = 'true'; },
  ];
  for (const mutate of mutations) {
    const data = payload(); mutate(data);
    assert.throws(() => app.validateData(data, 30), /invalid_data/);
  }
});

test('completed response cards and failed/stopped timing samples remain separate', () => {
  const app = dashboard();
  const data = payload();
  data.ai_performance.failed = group(1, 9000);
  data.ai_performance.failed.latency_ms = stats(null, 0);
  data.ai_performance.failed.streaming_time_ms = stats(null, 0);
  data.ai_performance.cancelled = group(1, 7000, 1000, 6000);
  app.state.data = app.validateData(data, 30);
  app.renderAiPerformance();
  const cards = app.elements.get('ai-timing-cards');
  assert.equal(cards.children.length, 3);
  assert.match(cards.children[0].textContent, /2.5 s/);
  assert.match(cards.children[1].textContent, /500 ms/);
  assert.doesNotMatch(cards.textContent, /9 s|7 s/);
  assert.match(app.elements.get('ai-timing-other-outcomes').textContent, /1 failed and 1 stopped/);
  const body = app.elements.get('ai-timing-table');
  assert.equal(body.children.length, 9);
  assert.match(body.children[3].textContent, /Failed Response time 1 9 s/);
  assert.match(body.children[4].textContent, /Failed First-text latency 0 No samples/);
  assert.match(app.elements.get('ai-performance-coverage').textContent, /1 older device does not report timings/);
});

test('sign-out rendering clears prior timings and old snapshots stay unmeasured', () => {
  const app = dashboard();
  app.state.data = payload();
  app.renderAiPerformance();
  app.elements.get('ai-timing-details').open = true;
  app.state.data = null;
  app.renderAiPerformance();
  assert.equal(app.elements.get('ai-performance-status').textContent, 'PRIVATE');
  assert.doesNotMatch(app.elements.get('ai-timing-cards').textContent, /2.5 s/);
  assert.equal(app.elements.get('ai-timing-details').open, false);
  const legacy = payload(); delete legacy.ai_performance;
  app.state.data = legacy; app.state.snapshotMode = true;
  app.renderAiPerformance();
  assert.match(app.elements.get('ai-timing-cards').textContent, /Not measured yet/);
  assert.match(app.elements.get('ai-performance-coverage').textContent, /Saved snapshot.*older requests and credit records have no timing data/);
});

test('no completed timing samples never turn into a zero response time', () => {
  const app = dashboard();
  const data = payload(); data.ai_performance.completed = group();
  app.state.data = data; app.renderAiPerformance();
  assert.equal(app.elements.get('ai-performance-status').textContent, 'NO COMPLETED SAMPLES');
  assert.match(app.elements.get('ai-timing-cards').textContent, /No samples/);
  assert.doesNotMatch(app.elements.get('ai-timing-cards').textContent, /0 ms/);
});

test('CSV includes raw milliseconds, percentiles, and sample counts without filling missing samples', () => {
  const app = dashboard();
  const data = payload(); data.ai_performance.completed = group(1);
  const rows = app.aiPerformanceCsvRows(data).map(row => Array.from(row));
  assert.deepEqual(rows.find(row => row[0] === 'Completed' && row[1] === 'response_time_ms'), ['Completed', 'response_time_ms', 1, 1, 0, 0, 0]);
  assert.deepEqual(rows.find(row => row[0] === 'Failed' && row[1] === 'latency_ms'), ['Failed', 'latency_ms', 0, 0, '', '', '']);
  assert.ok(rows.some(row => row[0] === 'Timing-capable devices' && row[1] === 2));
  const legacy = payload(); delete legacy.ai_performance;
  const legacyRows = app.aiPerformanceCsvRows(legacy);
  assert.ok(legacyRows.some(row => row[0] === 'AI performance status' && row[1] === 'Not measured yet'));
  assert.ok(!legacyRows.some(row => row[0] === 'Completed'));
});
