const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { zipSync, unzipSync, strToU8 } = require('fflate');
const { moduleLoader, filesystemAdapter, cryptoAdapter, mobileRoot } = require('./helpers.cjs');

function fixture(t, options) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kodi-mobile-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const load = moduleLoader({ 'expo-file-system': filesystemAdapter(root, options), 'expo-crypto': cryptoAdapter });
  return { root, load, files: load('src/lib/files.ts'), importer: load('src/lib/epub/import.ts') };
}

function epub(root, identifier, title = 'Test', name = 'test.epub') {
  const entries = {
    'META-INF/container.xml': strToU8('<container><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),
    'book.opf': strToU8(`<package><metadata><identifier>${identifier}</identifier><title>${title}</title></metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>`),
    'chapter.xhtml': strToU8(`<html><head><title>${title}</title></head><body><p>${title}</p></body></html>`),
  };
  const file = path.join(root, name);
  fs.writeFileSync(file, zipSync(entries));
  return file;
}

test('dot identifiers stay in a dedicated book directory and preserve the library', async (t) => {
  const { root, files, importer } = fixture(t);
  files.ensureLayout();
  files.libraryFile.write('private notes');
  for (const id of ['.', '..']) {
    const { record } = await importer.importDocument(epub(root, id), 'test.epub');
    assert.match(record.id, /^epub-[a-f0-9]{64}$/);
    assert.equal(files.libraryFile.textSync(), 'private notes');
    assert.ok(fs.existsSync(path.join(files.rootDirectory.path, record.extractedRelativePath, 'chapter.xhtml')));
    assert.equal(files.sanitizedFileName(id), 'book');
  }
});

test('full identifiers remain distinct and reimports reuse the original book', async (t) => {
  const { root, files, importer } = fixture(t);
  const identifiers = ['web:https://example.com/a/b', 'web:https://example.com/a-b', 'x'.repeat(130) + 'a', 'x'.repeat(130) + 'b'];
  const ids = new Set();
  for (const [i, identifier] of identifiers.entries()) {
    const title = `Book ${i}`;
    const uri = epub(root, identifier, title, `${i}.epub`);
    const { record } = await importer.importDocument(uri, `${i}.epub`);
    ids.add(record.id);
    assert.match(fs.readFileSync(path.join(files.rootDirectory.path, record.extractedRelativePath, 'chapter.xhtml'), 'utf8'), new RegExp(title));
    assert.equal((await importer.importDocument(uri, `${i}.epub`)).record.id, record.id);
  }
  assert.equal(ids.size, identifiers.length);
});

test('PDF identity uses file content rather than name and size', async (t) => {
  const { root, importer } = fixture(t);
  const uri = path.join(root, 'a.pdf');
  fs.writeFileSync(uri, 'first');
  const first = (await importer.importDocument(uri, 'same.pdf')).record;
  fs.writeFileSync(uri, 'other');
  const second = (await importer.importDocument(uri, 'same.pdf')).record;
  assert.notEqual(first.id, second.id);
});

test('import waits for extraction and copy, and propagates copy failures', async (t) => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let copying = false;
  const { root, files, importer } = fixture(t, { beforeCopy: async () => { copying = true; await gate; } });
  const pending = importer.importDocument(epub(root, 'async'), 'test.epub');
  let returned = false;
  pending.then(() => { returned = true; });
  while (!copying) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(returned, false);
  release();
  const { record } = await pending;
  assert.ok(fs.existsSync(path.join(files.rootDirectory.path, record.importedRelativePath)));
  assert.ok(fs.existsSync(path.join(files.rootDirectory.path, record.extractedRelativePath, 'chapter.xhtml')));
  const failing = fixture(t, { beforeCopy: async () => { throw new Error('disk full'); } });
  await assert.rejects(failing.importer.importDocument(epub(failing.root, 'failure'), 'test.epub'), /disk full/);
});

test('the durable copy starts only after the asynchronous extraction move finishes', async (t) => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let moving = false, copying = false;
  const { root, importer } = fixture(t, {
    beforeMove: async () => { moving = true; await gate; },
    beforeCopy: async () => { copying = true; },
  });
  const pending = importer.importDocument(epub(root, 'delayed-move'), 'test.epub');
  while (!moving) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(copying, false);
  release();
  await pending;
  assert.equal(copying, true);
});

test('runtime installation waits for copies, retries failures, and installs inside the book', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kodi-runtime-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  let fail = true;
  const fsModule = filesystemAdapter(root, { beforeCopy: async () => { if (fail) throw new Error('copy failed'); } });
  const load = moduleLoader({
    'expo-file-system': fsModule,
    'expo-asset': { Asset: { fromModule: (file) => ({ localUri: file, downloadAsync: async () => {} }) } },
  });
  const runtime = load('src/reader/runtime.ts');
  await assert.rejects(runtime.ensureRuntimeInstalled(), /copy failed/);
  fail = false;
  await runtime.ensureRuntimeInstalled();
  const book = new fsModule.Directory(root, 'Kodi', 'Extracted', 'book');
  book.create();
  await runtime.ensureBookRuntimeInstalled(book);
  for (const name of ['reader.js', 'reader.css', 'bridge.js']) {
    assert.equal(fs.readFileSync(new URL(runtime.bookRuntimeURL(book, name)), 'utf8'), fs.readFileSync(path.join(mobileRoot, 'src/reader/runtime', name + '.txt'), 'utf8'));
  }
});

test('security policy precedes publisher scripts and preserves body locators', () => {
  const { injectChapterHead } = moduleLoader()('src/reader/chapterDocument.ts');
  const body = '<body>\n<p onclick="steal()">Reading text</p>\n</body>';
  const original = '<?xml version="1.0"?><html><!-- <head> decoy --><head><script>steal()</script></head>' + body + '</html>';
  const secure = injectChapterHead(original, '<script nonce="test-nonce">trusted()</script>', 'test-nonce');
  assert.ok(secure.indexOf('Content-Security-Policy') < secure.indexOf('<script>steal()'));
  assert.ok(secure.includes("script-src 'nonce-test-nonce'"));
  assert.ok(secure.includes("connect-src 'none'"));
  assert.ok(secure.includes(body));
  assert.throws(() => injectChapterHead('<script>steal()</script><html><head></head></html>', '', 'test-nonce'));
  assert.throws(() => injectChapterHead('<html><body>No head</body></html>', '', 'test-nonce'));
});

test('all bundled sample chapters accept the protected head injection', () => {
  const { injectChapterHead } = moduleLoader()('src/reader/chapterDocument.ts');
  const { parsePublication } = moduleLoader()('src/lib/epub/parse.ts');
  for (const name of ['alice.epub', 'frankenstein.epub']) {
    const entries = unzipSync(fs.readFileSync(path.join(mobileRoot, 'assets/samples', name)));
    const pub = parsePublication({ exists: (p) => Boolean(entries[p]), text: (p) => new TextDecoder().decode(entries[p]), size: (p) => entries[p]?.length ?? 0 });
    for (const chapter of pub.readingOrder) assert.ok(injectChapterHead(new TextDecoder().decode(entries[chapter.path]), '', 'sample-nonce').includes('Content-Security-Policy'));
  }
});

function noteHarness() {
  const cleanups = [], updates = [], timers = new Map();
  let nextTimer = 0;
  const jsx = (type, props) => ({ type, props });
  let alertActions;
  const mocks = {
    react: { useCallback: (f) => f, useEffect: (f) => cleanups.push(f()), useRef: (value) => ({ current: value }), useState: (value) => [value, () => {}] },
    'react/jsx-runtime': { jsx, jsxs: jsx },
    'expo-router': { Stack: { Screen: 'Screen', Toolbar: { Button: 'Button' } }, useLocalSearchParams: () => ({ bookId: 'book', annotationId: 'note' }), useRouter: () => ({ back() {} }) },
    'expo-haptics': {},
    'react-native': { StyleSheet: { create: (x) => x }, TextInput: 'TextInput', ScrollView: 'ScrollView', View: 'View', Pressable: 'Pressable', Alert: { alert: (_title, _body, actions) => { alertActions = actions; } } },
    '@/components/GlassSurface': { GlassGroup: 'GlassGroup', GlassSurface: 'GlassSurface' },
    '@/components/Typography': { Typography: 'Typography' },
    '@/hooks/use-palette': { usePalette: () => ({}) },
    '@/lib/store': { useBook: () => ({ id: 'book', annotations: [{ id: 'note', color: 'yellow', text: 'Quote', note: 'original' }] }), updateAnnotation: (...args) => updates.push(args), deleteAnnotation: () => {} },
    '@/lib/theme': { Fonts: {}, Radius: {}, Spacing: {} },
    '@/lib/types': { FILL_COLORS: ['yellow'], HIGHLIGHT_SWATCH: { yellow: '#fff' } },
  };
  const load = moduleLoader(mocks, { setTimeout: (f) => { const id = ++nextTimer; timers.set(id, f); return id; }, clearTimeout: (id) => timers.delete(id) });
  const tree = load('src/app/note/[bookId]/[annotationId].tsx').default();
  const nodes = [];
  function walk(node) { if (!node || typeof node !== 'object') return; nodes.push(node); [node.props?.children].flat(Infinity).forEach(walk); }
  walk(tree);
  return { nodes, timers, updates, unmount: () => cleanups.forEach((f) => f?.()), edit: (value) => nodes.find((n) => n.type === 'TextInput').props.onChangeText(value), delete: () => { nodes.find((n) => n.type === 'Pressable' && n.props.onPress?.name === 'remove').props.onPress(); alertActions[1].onPress(); } };
}

test('dismissing a note commits the latest edit and cancels its timer', () => {
  const note = noteHarness();
  note.edit('first edit'); note.edit('last edit'); note.unmount();
  assert.equal(note.timers.size, 0);
  assert.equal(note.updates.length, 1);
  assert.equal(note.updates[0][2].note, 'last edit');
});

test('deleting a note cancels pending edits without committing on unmount', () => {
  const note = noteHarness();
  note.edit('discarded'); note.delete(); note.unmount();
  assert.equal(note.timers.size, 0);
  assert.equal(note.updates.length, 0);
});
