import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('./model.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { DEFAULT_LIBRARY, currentStreak, localDay, matchingBooks, narrationPlaybackAction, newAnnotation, percent } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
const book = (id, title, progress, lastOpenedAt = 0) => ({ id, title, progress, author: 'Author', addedAt: 1, lastOpenedAt });

test('raising a daily goal does not erase earned streak days', () => {
  const yesterday = new Date(); yesterday.setDate(yesterday.getDate() - 1);
  const library = { ...DEFAULT_LIBRARY, goalMinutes: 60, readingHistory: { [localDay()]: 1200, [localDay(yesterday)]: 1200 }, completedReadingDays: [localDay(), localDay(yesterday)] };
  assert.equal(currentStreak(library), 2);
});
test('an unfinished today retains yesterday’s streak and does not count an empty day', () => {
  const yesterday = new Date(); yesterday.setDate(yesterday.getDate() - 1);
  const library = { ...DEFAULT_LIBRARY, readingHistory: { [localDay(yesterday)]: 1200 } };
  assert.equal(currentStreak(library), 1);
  assert.equal(currentStreak(DEFAULT_LIBRARY), 0);
});
test('PDF annotation creation preserves local quadrilaterals and Unicode quotes', () => {
  const anchors = [{ pageIndex: 3, quads: [[.1, .1, .5, .1, .5, .2, .1, .2]], text: 'A😀é' }];
  const annotation = newAnnotation({ kind: 'pdf', spineIndex: 2 }, { text: 'A😀é', spineIndex: 3, locator: { pdfAnchors: anchors, start: { elementPath: [], offset: 0 } } }, 'green');
  assert.equal(annotation.locator.spineIndex, 3);
  assert.deepEqual(annotation.locator.pdfAnchors, anchors);
  assert.equal(annotation.text, 'A😀é');
});
test('library filters and ordering remain independent and deterministic', () => {
  const books = [book('b', 'Beta', .4), book('c', 'Charlie', 1), book('a', 'Alpha', 0)];
  assert.deepEqual(matchingBooks(books, '', 'progress', 'title', false).map(item => item.id), ['b']);
  assert.deepEqual(matchingBooks(books, 'author', 'finished', 'title', false).map(item => item.id), ['c']);
  assert.deepEqual(matchingBooks(books, '', 'all', 'title', false).map(item => item.id), ['a', 'b', 'c']);
});
test('removed cards stay hidden across searches and reading filters while cloud-only books remain visible', () => {
  const removed = { ...book('removed', 'Removed document', .5, Date.now() / 1000), removedFromLibrary: true, offlineAvailable: false, annotations: [{ id: 'saved-note', note: 'Kept thought' }] };
  const cloud = { ...book('cloud', 'Cloud document', .5, Date.now() / 1000), offlineAvailable: false };
  const local = book('local', 'Local document', 0);
  const books = [removed, cloud, local];
  const original = JSON.stringify(books);
  for (const filter of ['all', 'recent', 'progress', 'unread', 'finished']) {
    for (const descending of [false, true]) {
      assert.ok(!matchingBooks(books, '', filter, 'title', descending).some(item => item.id === removed.id));
      assert.deepEqual(matchingBooks(books, 'Removed document', filter, 'title', descending), []);
    }
  }
  assert.deepEqual(matchingBooks(books, '', 'all', 'title', false).map(item => item.id), ['cloud', 'local']);
  assert.deepEqual(matchingBooks(books, 'Cloud', 'progress', 'title', false).map(item => item.id), ['cloud']);
  assert.equal(JSON.stringify(books), original, 'filtering must not erase preserved notes or local state');
  const restored = { ...removed, removedFromLibrary: false, offlineAvailable: true };
  assert.equal(matchingBooks([restored], 'Removed document', 'progress', 'title', false)[0], restored);
});
test('malformed progress never produces invalid layout values', () => {
  assert.equal(percent(NaN), 0); assert.equal(percent(-2), 0); assert.equal(percent(1.2), 100);
});
test('opening Listen while a note recording plays or pauses starts narration with its own owner', () => {
  assert.equal(narrationPlaybackAction({ phase: 'playing', path: 'Audio/note.m4a' }), 'start');
  assert.equal(narrationPlaybackAction({ phase: 'paused', path: 'Audio/note.m4a' }), 'start');
});
test('narration controls pause preparation and resume only the narration session', () => {
  assert.equal(narrationPlaybackAction({ kind: 'narration', phase: 'preparing' }), 'pause');
  assert.equal(narrationPlaybackAction({ kind: 'narration', phase: 'playing' }), 'pause');
  assert.equal(narrationPlaybackAction({ kind: 'narration', phase: 'paused' }), 'resume');
});
