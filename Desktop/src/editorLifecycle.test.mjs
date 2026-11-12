import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('./editorLifecycle.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { registerEditor, flushEditors, createDraftFlusher } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

test('reader/window teardown waits for pending note writes and recording saves', async () => {
  let release; let resolved = false;
  const done = new Promise(resolve => { release = resolve; });
  const stop = registerEditor(async () => { await done; });
  const flushing = flushEditors().then(() => { resolved = true; });
  await Promise.resolve(); assert.equal(resolved, false);
  release(); await flushing; assert.equal(resolved, true); stop();
});
test('failed note saves prevent teardown and retain registered retry work', async () => {
  let fail = true; let count = 0;
  const stop = registerEditor(async () => { count++; if (fail) throw new Error('disk unavailable'); });
  await assert.rejects(flushEditors(), /disk unavailable/);
  fail = false; await flushEditors(); assert.equal(count, 2); stop();
});
test('unmounted editors no longer participate in subsequent reader transitions', async () => {
  let invoked = false;
  const stop = registerEditor(async () => { invoked = true; }); stop();
  await flushEditors(); assert.equal(invoked, false);
});

test('typing during a delayed native save is persisted before the same flush resolves', async () => {
  let pending = 'first draft'; let saved = ''; let releaseFirst;
  const gate = new Promise(resolve => { releaseFirst = resolve; }); const writes = [];
  const flush = createDraftFlusher(() => pending, () => saved, async text => {
    writes.push(text); if (writes.length === 1) await gate; saved = text; return true;
  });
  const closing = flush();
  pending = 'latest Unicode thought 😀'; releaseFirst();
  assert.equal(await closing, true);
  assert.equal(saved, 'latest Unicode thought 😀');
  assert.deepEqual(writes, ['first draft', 'latest Unicode thought 😀']);
});
test('blur, debounce, and teardown share one in-flight write queue', async () => {
  let pending = 'A'; let saved = ''; let release; let writes = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const flush = createDraftFlusher(() => pending, () => saved, async text => { writes++; await gate; saved = text; return true; });
  const blur = flush(); const close = flush();
  assert.equal(blur, close); release();
  assert.equal(await close, true); assert.equal(writes, 1);
});
test('a failed delayed save retains the newest draft for retry', async () => {
  let pending = 'A'; let saved = ''; let fail = true;
  const flush = createDraftFlusher(() => pending, () => saved, async text => { if (fail) return false; saved = text; return true; });
  assert.equal(await flush(), false);
  pending = 'B'; fail = false;
  assert.equal(await flush(), true); assert.equal(saved, 'B');
});
test('teardown reflush after recording finalization preserves late text and its new audio link', async () => {
  let pending = 'A'; let saved = ''; let releaseRecording;
  const gate = new Promise(resolve => { releaseRecording = resolve; });
  const flush = createDraftFlusher(() => pending, () => saved, async text => { saved = text; return true; });
  const stop = registerEditor(async () => { await flush(); await gate; pending += '\n[Audio](kodi-audio://fixture)'; await flush(); });
  const closing = flushEditors(); await Promise.resolve();
  pending = 'typed while encoding'; releaseRecording(); await closing;
  assert.equal(saved, 'typed while encoding\n[Audio](kodi-audio://fixture)'); stop();
});
test('metadata-only changes share the save queue and reflush changes made during a delayed write', async () => {
  let revision = 1, savedRevision = 0, release; const writes = [];
  const gate = new Promise(resolve => { release = resolve; });
  const flush = createDraftFlusher(() => 'Same note text', () => 'Same note text', async () => {
    const captured = revision; writes.push(captured); if (writes.length === 1) await gate;
    savedRevision = captured; return true;
  }, () => revision !== savedRevision);
  const saving = flush(); revision = 2; assert.equal(flush(), saving); release();
  assert.equal(await saving, true); assert.deepEqual(writes, [1, 2]);
});
