import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
const root = resolve(import.meta.dirname, '..');
const read = path => readFileSync(resolve(root, path), 'utf8');
test('untrusted reader has only the reader event command and no window-wide grants', () => {
  const capability = JSON.parse(read('src-tauri/capabilities/reader.json'));
  assert.deepEqual(capability.permissions, ['allow-reader-event']);
  assert.deepEqual(capability.webviews, ['book-reader']);
  assert.equal(capability.windows, undefined);
  assert.match(read('src-tauri/src/reader.rs'), /view\.label\(\)\s*!=\s*"book-reader"/);
  assert.match(read('src-tauri/build.rs'), /AppManifest::new\(\)\s*\.commands/);
});
test('desktop vendor inputs record exact source hashes without sharing mutable Apple paths', () => {
  const manifest=JSON.parse(read('vendor-manifest.json'));
  assert.match(manifest.sourceCommit, /^[a-f0-9]{40}$/);
  for (const [destination, input] of Object.entries(manifest.files)) {
    assert.ok(destination.startsWith('Desktop/public/vendor/'));
    assert.match(input.sha256, /^[a-f0-9]{64}$/);
  }
});
test('native reader bridge is standalone and has no arbitrary evaluate command', () => {
  const bridge=read('public/vendor/reader/bridge.js');
  assert.match(bridge, /reader_event/);
  assert.match(bridge, /sessionId: boot.sessionId/);
  assert.ok(!read('src-tauri/build.rs').includes('"evaluate"'));
});
test('release checklist is explicit rather than treating local builds as native validation', () => {
  const gates=JSON.parse(read('release-acceptance.json'));
  assert.ok(Object.keys(gates.checks).length>=9);
  assert.match(read('scripts/check-release.mjs'), /evidence/);
});
