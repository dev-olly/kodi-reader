import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('./readerLifecycle.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { openReaderPublication, pdfPageTarget, resolveEpubHref, runReaderCommand } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

test('a replaced or transitioning reader never sends its queued updates', async () => {
  let calls = 0;
  await runReaderCommand(async () => { calls++; }, () => false);
  assert.equal(calls, 0);
});
test('an old view failing after a chapter change cannot display an error on the new chapter', async () => {
  let current = 'chapter-a'; let rejectOld;
  const reply = new Promise((_, reject) => { rejectOld = reject; });
  const pending = runReaderCommand(() => reply, () => current === 'chapter-a');
  current = 'chapter-b';
  rejectOld(new Error('The old native view closed'));
  await assert.doesNotReject(pending);
});
test('genuine errors for the current reader remain visible while superseded updates finish quietly', async () => {
  const failure = new Error('The current reading view could not display this chapter');
  await assert.rejects(runReaderCommand(async () => { throw failure; }, () => true), error => error === failure);
  await assert.doesNotReject(runReaderCommand(async () => 'superseded', () => true));
});

test('opening a synced document downloads its missing bytes before publication parsing', async () => {
  let hasBytes = false; let releaseDownload; let parsed = false;
  const gate = new Promise(resolve => { releaseDownload = resolve; });
  const opening = openReaderPublication(async () => { await gate; hasBytes = true; return { sessionId: 'downloaded-book' }; }, async () => {
    assert.equal(hasBytes, true); parsed = true; return { title: 'Downloaded EPUB' };
  }, () => true);
  await Promise.resolve(); assert.equal(parsed, false);
  releaseDownload(); const result = await opening;
  assert.equal(result.session.sessionId, 'downloaded-book'); assert.equal(result.publication.title, 'Downloaded EPUB');
});
test('a superseded opening never parses or publishes its obsolete session', async () => {
  let releaseOpen; let active = true; let parsed = false;
  const gate = new Promise(resolve => { releaseOpen = resolve; });
  const opening = openReaderPublication(async () => { await gate; return {}; }, async () => { parsed = true; return {}; }, () => active);
  active = false; releaseOpen(); assert.equal(await opening, null); assert.equal(parsed, false);
});
test('download errors leave publication parsing uncalled and preserve the failure', async () => {
  let parsed = false;
  await assert.rejects(openReaderPublication(async () => { throw new Error('download interrupted'); }, async () => { parsed = true; return {}; }, () => true), /download interrupted/);
  assert.equal(parsed, false);
});

test('nested PDF outline links target their one-based destination instead of the current page', () => {
  const outline = [{ title: 'Part one', href: '#page=1', children: [{ title: 'Nested chapter', href: '#page=4', children: [] }] }];
  assert.equal(pdfPageTarget(outline[0].children[0].href, 6), 3);
  assert.equal(pdfPageTarget(outline[0].href, 6), 0);
  assert.equal(pdfPageTarget('#page=6', 6), 5);
});
test('invalid PDF outline destinations cannot navigate outside the document', () => {
  for (const href of ['#page=0', '#page=7', '#page=-1', '#page=1.5', '#page=Infinity', '#page=9007199254740992', '#footnote', '']) assert.equal(pdfPageTarget(href, 6), null, href);
  assert.equal(pdfPageTarget('#page=1', 0), null);
  assert.equal(pdfPageTarget('#page=1', NaN), null);
});

test('literal hash and query characters in EPUB ZIP names remain distinct from navigation fragments', () => {
  const order = [{ href: 'OPS/current.xhtml' }, { href: 'OPS/chapter%231%3F.xhtml' }, { href: 'OPS/chapter.xhtml' }];
  assert.deepEqual(resolveEpubHref('OPS/chapter%231%3F.xhtml#foo%20bar', order, 0), { spineIndex: 1, fragment: 'foo bar' });
  assert.deepEqual(resolveEpubHref('chapter%231%3F.xhtml#foo%20bar', order, 0, 'chapter'), { spineIndex: 1, fragment: 'foo bar' });
  assert.deepEqual(resolveEpubHref('OPS/chapter.xhtml#1%3F', order, 0), { spineIndex: 2, fragment: '1?' });
});
test('EPUB fragments decode exactly once, including literal percent sequences and hashes', () => {
  const order = [{ href: 'OPS/chapter%2520one.xhtml' }];
  assert.deepEqual(resolveEpubHref('#section%2520one', order, 0, 'chapter'), { spineIndex: 0, fragment: 'section%20one' });
  assert.deepEqual(resolveEpubHref('#literal#hash', order, 0, 'chapter'), { spineIndex: 0, fragment: 'literal#hash' });
});
test('TOC root paths and chapter-relative links resolve against their own origins', () => {
  const order = [{ href: 'chapter.xhtml' }, { href: 'OPS/current.xhtml' }, { href: 'OPS/chapter.xhtml' }];
  assert.deepEqual(resolveEpubHref('chapter.xhtml', order, 1, 'publication'), { spineIndex: 0, fragment: null });
  assert.deepEqual(resolveEpubHref('chapter.xhtml', order, 1, 'chapter'), { spineIndex: 2, fragment: null });
  assert.equal(resolveEpubHref('https://example.com/chapter.xhtml', order, 1, 'chapter'), null);
  assert.equal(resolveEpubHref('#bad%fragment', order, 1, 'chapter'), null);
});
