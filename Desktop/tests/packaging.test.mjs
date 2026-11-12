import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { bundleConfiguration } from '../scripts/bundle-config.mjs';
import { collectInternal } from '../scripts/collect-internal.mjs';

const commit = 'a'.repeat(40);
const required = ['windows11', 'ubuntu2404Wayland', 'ubuntu2404X11', 'ubuntu2604Wayland', 'fedoraWayland', 'macDriveRoundTrip', 'offlineAudio', 'signedUpdateUpgrade', 'installerDataRetention'];
const releaseEnv = { KODI_SUPABASE_URL: 'https://example.supabase.co', KODI_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture', KODI_GOOGLE_CLIENT_ID: 'desktop-fixture', KODI_UPDATER_PUBLIC_KEY: 'fixture-public-key', TAURI_SIGNING_PRIVATE_KEY: 'fixture-private-key' };
test('configured installer icons exist and include a square PNG for AppImage packaging', () => {
  const root = new URL('../src-tauri/', import.meta.url);
  const config = JSON.parse(readFileSync(new URL('tauri.conf.json', root), 'utf8'));
  const icons = config.bundle.icon.map(path => ({ path, bytes: readFileSync(new URL(path, root)) }));
  const pngs = icons.filter(icon => icon.path.endsWith('.png'));
  assert.ok(pngs.length, 'AppImage needs a configured PNG icon');
  for (const { bytes } of pngs) {
    assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    assert.equal(bytes.subarray(12, 16).toString('ascii'), 'IHDR');
    assert.ok(bytes.readUInt32BE(16) >= 32);
    assert.equal(bytes.readUInt32BE(16), bytes.readUInt32BE(20), 'AppImage requires a square icon');
  }
  const windows = icons.find(icon => icon.path.endsWith('.ico'));
  assert.ok(windows, 'NSIS needs its Windows icon');
  assert.equal(windows.bytes.subarray(0, 4).toString('hex'), '00000100');
});
test('internal Windows/Linux bundles have isolated preview data and no updater', () => {
  for (const platform of ['win32', 'linux']) {
    const config = bundleConfiguration({ platform });
    assert.equal(config.identifier, 'com.olly.KodiReader.Desktop.Preview');
    assert.equal(config.productName, 'Kodi Reader Preview');
    assert.equal(config.bundle.createUpdaterArtifacts, false);
    assert.equal(config.plugins?.updater, undefined);
    assert.deepEqual(config.bundle.targets, platform === 'win32' ? ['nsis'] : ['appimage', 'deb', 'rpm']);
  }
  assert.throws(() => bundleConfiguration({ platform: 'darwin' }), /existing signed native release/);
});
test('public packaging still requires every native acceptance gate and real signing configuration', () => {
  assert.throws(() => bundleConfiguration({ platform: 'linux', release: true, env: releaseEnv, acceptance: { checks: {} } }), /acceptance/);
  const acceptance = { checks: Object.fromEntries(required.map(name => [name, { passed: true, evidence: `fixture-${name}` }])) };
  const env = { ...releaseEnv };
  delete env.TAURI_SIGNING_PRIVATE_KEY;
  assert.throws(() => bundleConfiguration({ platform: 'linux', release: true, env, acceptance }), /signing key/);
  const config = bundleConfiguration({ platform: 'linux', release: true, env: releaseEnv, acceptance });
  assert.equal(config.identifier, undefined);
  assert.equal(config.bundle.createUpdaterArtifacts, true);
  assert.equal(config.plugins.updater.pubkey, releaseEnv.KODI_UPDATER_PUBLIC_KEY);
  assert.throws(() => bundleConfiguration({ platform: 'win32', release: true, env: releaseEnv, acceptance }), /Authenticode/);
  acceptance.checks.windows11.passed = false;
  assert.throws(() => bundleConfiguration({ platform: 'linux', release: true, env: releaseEnv, acceptance }), /acceptance/);
});
function fixture(target = 'x86_64-unknown-linux-gnu') {
  const root = mkdtempSync(join(tmpdir(), 'kodi-packaging-'));
  const write = (path, value = path) => { const full = join(root, path); mkdirSync(join(full, '..'), { recursive: true }); writeFileSync(full, value); };
  write('package.json', JSON.stringify({ version: '0.1.0' }));
  write('src-tauri/tauri.ci.conf.json', JSON.stringify(bundleConfiguration({ platform: target.includes('windows') ? 'win32' : 'linux' })));
  for (const suffix of target.includes('windows') ? ['exe'] : ['AppImage', 'deb', 'rpm']) write(`src-tauri/target/release/bundle/${suffix}/Kodi Preview.${suffix}`, `fixture installer ${suffix}`);
  for (const name of ['BUILD.txt', 'ffmpeg-version.txt', 'COPYING.LGPLv2.1', 'SHA256SUMS', 'ffmpeg-fixture.tar.xz', 'ffmpeg-fixture.tar.xz.asc']) write(`src-tauri/resources/ffmpeg/${name}`);
  write('src-tauri/resources/licenses/manifest.json', '[]');
  write('src-tauri/resources/licenses/LICENSE.txt');
  write('THIRD_PARTY_NOTICES.md');
  return { root, write, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}
test('native preview collection produces real checksummed installer/source/license files', () => {
  for (const target of ['x86_64-unknown-linux-gnu', 'x86_64-pc-windows-msvc']) {
    const { root, write, cleanup } = fixture(target);
    try {
      if (target.includes('linux')) write('native-smoke-results/result.json', '{"manualAcceptance":false}');
      const manifest = collectInternal({ root, target, commit, runId: 'fixture-run', createdAt: '2026-11-12T00:00:00Z' });
      const output = join(root, 'internal-output');
      assert.equal(manifest.manualAcceptance, false);
      assert.equal(manifest.publicReleaseReady, false);
      assert.equal(manifest.sourceCommit, commit);
      assert.equal(manifest.updaterEnabled, false);
      assert.equal(manifest.installers.length, target.includes('windows') ? 1 : 3);
      assert.equal(manifest.nativeSmokeEvidence, target.includes('linux'));
      for (const file of manifest.files) assert.equal(createHash('sha256').update(readFileSync(join(output, file.path))).digest('hex'), file.sha256);
      const sums = readFileSync(join(output, 'SHA256SUMS'), 'utf8');
      assert.match(sums, /preview-manifest.json/);
      assert.match(sums, /ffmpeg\/ffmpeg-fixture.tar.xz/);
      assert.match(sums, /licenses\/manifest.json/);
      assert.ok(!readdirSync(output).includes('latest.json'));
      assert.throws(() => collectInternal({ root, target, commit }), /must be empty/);
    } finally { cleanup(); }
  }
});
test('internal collector rejects signed updater files and incomplete native bundles', () => {
  const { root, write, cleanup } = fixture();
  try {
    const signature = 'src-tauri/target/release/bundle/AppImage/Kodi Preview.AppImage.sig';
    write(signature, 'not an internal updater');
    assert.throws(() => collectInternal({ root, target: 'x86_64-unknown-linux-gnu', commit }), /signed updater/);
    rmSync(join(root, signature));
    rmSync(join(root, 'src-tauri/target/release/bundle/rpm/Kodi Preview.rpm'));
    assert.throws(() => collectInternal({ root, target: 'x86_64-unknown-linux-gnu', commit }), /exactly one .rpm/);
  } finally { cleanup(); }
});
