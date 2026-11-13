// Direct W3C WebDriver smoke of a REAL packaged Tauri binary, no browser mocks.
// Linux: dbus-run-session -- xvfb-run -a node scripts/native-smoke.mjs <binary> <fixture.epub>
// Windows: install a matching msedgedriver, then invoke this script directly.
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
const application = resolve(process.argv[2] ?? '');
const fixture = resolve(process.argv[3] ?? '');
if (!process.argv[2] || !process.argv[3]) throw new Error('Supply native application and fixture EPUB paths.');
const directory = mkdtempSync(join(tmpdir(), 'kodi-native-smoke-'));
const freePort = () => new Promise((resolvePort, reject) => {
  const socket = createServer(); socket.on('error', reject); socket.listen(0, '127.0.0.1', () => {
    const port = socket.address().port; socket.close(() => resolvePort(port));
  });
});
const port = await freePort(); const nativePort = await freePort();
const env = { ...process.env, XDG_DATA_HOME: join(directory, 'data'), XDG_CONFIG_HOME: join(directory, 'config'), APPDATA: join(directory, 'data'), LOCALAPPDATA: join(directory, 'local') };
const driver = spawn(process.env.TAURI_DRIVER_PATH ?? 'tauri-driver', ['--port', String(port), '--native-port', String(nativePort)], { env, stdio: ['ignore', 'pipe', 'pipe'] });
let driverFailure;
driver.on('error', error => { driverFailure = error; });
let log = ''; driver.stdout.on('data', value => { log += value; }); driver.stderr.on('data', value => { log += value; });
const base = `http://127.0.0.1:${port}`;
let session;
let captureFailure = async () => {};
const request = async (method, path, body) => {
  const response = await fetch(`${base}${path}`, { method, headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(45_000) });
  const json = await response.json();
  if (!response.ok || json.value?.error) throw new Error(`Native WebDriver ${path}: ${json.value?.message ?? response.status}`);
  return json.value;
};
const poll = async (predicate, description, timeout = 30_000) => {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (driverFailure) throw driverFailure;
    try { const result = await predicate(); if (result) return result; } catch (error) { if (Date.now() + 250 >= until) throw error; }
    await new Promise(resolveDelay => setTimeout(resolveDelay, 200));
  }
  throw new Error(`Timed out: ${description}`);
};
try {
  await poll(async () => { await request('GET', '/status'); return true; }, 'starting native driver');
  const started = await request('POST', '/session', { capabilities: { alwaysMatch: { 'tauri:options': { application } } } });
  session = started.sessionId;
  if (!session) throw new Error('Native driver did not return a session.');
  const execute = (script, args = []) => request('POST', `/session/${session}/execute/sync`, { script, args });
  const invoke = async (command, args = {}) => {
    const result = await request('POST', `/session/${session}/execute/async`, {
      script: 'const [command, args, done] = arguments; window.__TAURI_INTERNALS__.invoke(command,args).then(value=>done({ok:true,value}),error=>done({ok:false,error:String(error)}));', args: [command, args],
    });
    if (!result.ok) throw new Error(`Native command ${command}: ${result.error}`);
    return result.value;
  };
  const click = async selector => {
    const element = await poll(() => request('POST', `/session/${session}/element`, { using: 'css selector', value: selector }), `finding ${selector}`);
    const id = element['element-6066-11e4-a52e-4f735466cecf'];
    if (!id) throw new Error(`Native driver returned no element for ${selector}.`);
    await request('POST', `/session/${session}/element/${encodeURIComponent(id)}/click`, {});
  };
  await poll(() => execute('return document.body.innerText.includes("Kodi") && !!window.__TAURI_INTERNALS__;'), 'loading native chrome');
  const imported = await invoke('import_documents', { paths: [fixture] });
  const book = Object.values(imported.books).find(value => value.title === 'Kodi native smoke fixture');
  if (!book) throw new Error('Native import failed to create its library record.');
  const publication = await invoke('publication_get', { bookId: book.id });
  if (publication.readingOrder.length !== 1) throw new Error('Native parser returned the wrong reading order.');
  await click('button[aria-label="Read Kodi native smoke fixture"]');
  await poll(() => execute('return !!document.querySelector(".reader-workspace");'), 'opening imported EPUB');
  const output = resolve(process.env.KODI_SMOKE_OUTPUT ?? 'native-smoke-results');
  captureFailure = async () => {
    mkdirSync(output, { recursive: true });
    const state = await invoke('library_get');
    const chrome = await execute('return {text:document.body.innerText,location:document.querySelector(".reading-location small")?.textContent,bounds:document.querySelector(".native-reader-slot")?.getBoundingClientRect().toJSON()};');
    writeFileSync(join(output, 'failure-state.json'), JSON.stringify({ book: state.books[book.id], chrome }, null, 2));
    const screenshot = await request('GET', `/session/${session}/screenshot`);
    writeFileSync(join(output, 'failure-window.png'), Buffer.from(screenshot, 'base64'));
  };
  // The first position can arrive before chrome preferences and native resize
  // have finished repaginating. Observe a stable, navigable layout first.
  let previousLayout = ''; let stableSince = 0;
  const initial = await poll(async () => {
    const location = await execute('return document.querySelector(".reading-location small")?.textContent || "";');
    const pages = location.match(/^(\d+) of (\d+)$/);
    const state = await invoke('library_get'); const current = state.books[book.id];
    if (!current?.position || !pages || Number(pages[2]) <= Number(pages[1])) { previousLayout = ''; stableSince = 0; return null; }
    const layout = JSON.stringify([location, current.progress, current.position]);
    if (layout !== previousLayout) { previousLayout = layout; stableSince = Date.now(); return null; }
    return Date.now() - stableSince >= 1000 ? current : null;
  }, 'receiving a stable, navigable position from the native child reader');
  await click('button[aria-label="Next page"]');
  const advanced = await poll(async () => { const state = await invoke('library_get'); return state.books[book.id]?.progress > initial.progress ? state.books[book.id] : null; }, 'persisting the next native reader page');
  const screenshot = await request('GET', `/session/${session}/screenshot`);
  mkdirSync(output, { recursive: true });
  writeFileSync(join(output, 'native-window.png'), Buffer.from(screenshot, 'base64'));
  writeFileSync(join(output, 'result.json'), JSON.stringify({ platform: process.platform, importedBook: book.id, chapters: publication.readingOrder.length, progressBefore: initial.progress, progressAfter: advanced.progress, checked: ['native launch', 'real Rust IPC import', 'EPUB parsing', 'native child position event', 'next-page persisted'], manualAcceptance: false }, null, 2));
  console.log('Native launch, import, child rendering events and persisted pagination smoke passed. Physical-device acceptance remains required.');
} catch (error) {
  await captureFailure().catch(diagnostic => console.error('Could not capture native failure diagnostics:', String(diagnostic)));
  throw error;
} finally {
  if (session) await request('DELETE', `/session/${session}`).catch(() => {});
  driver.kill();
  if (process.env.KODI_SMOKE_OUTPUT) { mkdirSync(resolve(process.env.KODI_SMOKE_OUTPUT), { recursive: true }); writeFileSync(join(resolve(process.env.KODI_SMOKE_OUTPUT), 'driver.log'), log); }
  rmSync(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
