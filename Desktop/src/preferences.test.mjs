import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('./preferences.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { readPreference, savePreference, readSavedPrompts } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
function storage(entries = {}) {
  const values = new Map(Object.entries(entries));
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
}

test('library ordering survives a return from the reader, including ascending and descending titles', () => {
  const saved = storage();
  for (const direction of ['false', 'true']) {
    savePreference('kodi-desktop.sort', 'title', saved);
    savePreference('kodi-desktop.descending', direction, saved);
    assert.equal(readPreference('kodi-desktop.sort', ['title', 'recent', 'added'], 'recent', saved), 'title');
    assert.equal(readPreference('kodi-desktop.descending', ['true', 'false'], 'true', saved), direction);
  }
});

test('obsolete preferences recover to a supported library filter and layout', () => {
  const saved = storage({ filter: 'archived', layout: 'shelf' });
  assert.equal(readPreference('filter', ['all', 'unread'], 'all', saved), 'all');
  assert.equal(readPreference('layout', ['grid', 'list'], 'grid', saved), 'grid');
});

test('unavailable preference storage does not stop offline reading or account UI', () => {
  const unavailable = { getItem() { throw new Error('storage denied'); }, setItem() { throw new Error('storage full'); } };
  assert.equal(readPreference('layout', ['grid', 'list'], 'grid', unavailable), 'grid');
  assert.deepEqual(readSavedPrompts(unavailable), []);
  assert.doesNotThrow(() => savePreference('layout', 'list', unavailable));
});

test('corrupt and non-array saved prompts cannot crash Ask AI', () => {
  for (const raw of ['{', '{}', 'true', 'null', '"a question"']) {
    assert.deepEqual(readSavedPrompts(storage({ 'kodi-desktop.prompts': raw })), []);
  }
});

test('saved prompts retain unique usable questions and discard unsupported values', () => {
  assert.deepEqual(readSavedPrompts(storage({ 'kodi-desktop.prompts': JSON.stringify(['Explain', 42, null, {}, ' ', 'Explain', 'Why?']) })), ['Explain', 'Why?']);
});
