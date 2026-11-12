import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const bridge = await readFile(new URL('../public/vendor/reader/bridge.js', import.meta.url), 'utf8');
function openChapter(position, fragment) {
  const calls = [];
  const events = [];
  const listeners = new Map();
  const reader = new Proxy({}, { get: (_target, name) => (...args) => calls.push([name, ...args]) });
  const boot = { spineIndex: 3, position, fragment, settings: { theme: 'light' }, annotations: [], reminders: [] };
  vm.runInNewContext(bridge, { window: { __KODI_BOOT__: boot, __reader: reader, __TAURI_INTERNALS__: { invoke: async (_command, args) => { events.push(args.message); } } }, document: { addEventListener: (name, listener) => listeners.set(name, listener) }, matchMedia: () => ({ matches: false }) });
  listeners.get('DOMContentLoaded')();
  return { calls, events, key: event => listeners.get('keydown')({ ctrlKey: false, altKey: false, metaKey: false, shiftKey: false, target: { tagName: 'BODY' }, preventDefault() {}, ...event }) };
}

test('crossing backward into the previous chapter restores its final page after startup', () => {
  const { calls } = openChapter({ spineIndex: 3, start: { elementPath: [], offset: 0 }, desktopChapterEnd: true });
  assert.equal(calls.filter(([name]) => name === 'goToEnd').length, 1);
  assert.ok(calls.findIndex(([name]) => name === 'start') < calls.findIndex(([name]) => name === 'goToEnd'));
  assert.equal(calls.some(([name]) => name === 'goToPosition'), false);
});
test('normal forward opening and saved positions keep their own anchor', () => {
  const anchor = { elementPath: [2, 1], offset: 8 };
  const { calls } = openChapter({ spineIndex: 3, start: anchor });
  assert.deepEqual(calls.find(([name]) => name === 'goToPosition'), ['goToPosition', anchor, false]);
  assert.equal(calls.some(([name]) => name === 'goToEnd'), false);
});
test('an end marker from a different chapter cannot override current content or explicit references', () => {
  assert.equal(openChapter({ spineIndex: 2, desktopChapterEnd: true }).calls.some(([name]) => name === 'goToEnd'), false);
  const { calls } = openChapter({ spineIndex: 3, desktopChapterEnd: true }, 'footnote');
  assert.deepEqual(calls.find(([name]) => name === 'goToFragment'), ['goToFragment', 'footnote']);
  assert.equal(calls.some(([name]) => name === 'goToEnd'), false);
});
test('Shift+M asks the trusted app for the live marker even when there was none at chapter startup', () => {
  const reader = openChapter(null);
  reader.key({ key: 'M', shiftKey: true });
  assert.equal(reader.events.at(-1).type, 'readingMarkerRequested');
  assert.equal(reader.calls.some(([name]) => name === 'setReadingMarkerPlacement'), false);
});
test('plain M still places a marker while modified typing does not invoke a reader shortcut', () => {
  const reader = openChapter(null);
  reader.key({ key: 'm' });
  assert.deepEqual(reader.calls.at(-1), ['setReadingMarkerPlacement', true]);
  reader.key({ key: 'M', shiftKey: true, metaKey: true });
  assert.equal(reader.events.length, 0);
});
