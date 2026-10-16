const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { moduleLoader, mobileRoot } = require('./helpers.cjs');

const root = path.resolve(process.argv[2]);
const book = path.join(root, 'Extracted', 'book');
const runtime = path.join(book, '.kodi-runtime');
fs.mkdirSync(runtime, { recursive: true });
fs.writeFileSync(path.join(root, 'library.json'), 'synthetic private notes');
for (const name of ['reader.js', 'reader.css', 'bridge.js']) fs.copyFileSync(path.join(mobileRoot, 'src/reader/runtime', name + '.txt'), path.join(runtime, name));
const { injectChapterHead } = moduleLoader()('src/reader/chapterDocument.ts');
const nonce = 'native-smoke-nonce';
const boot = { documentToken: nonce, options: { spineIndex: 0, marginX: 20, marginY: 30, animatePageTurns: false, edgeTapPaging: false, variables: { '--font-size': '20px', '--line-height': '1.6' } }, highlights: [] };
const tags = [
  `<link rel="stylesheet" href="${pathToFileURL(path.join(runtime, 'reader.css'))}"/>`,
  `<script nonce="${nonce}">window.__kodiBoot=${JSON.stringify(boot)};</script>`,
  ...['reader.js', 'bridge.js'].map((name) => `<script nonce="${nonce}" src="${pathToFileURL(path.join(runtime, name))}"></script>`),
].join('\n');
const body = '<body><p id="passage">A highlighted passage in the protected reader.</p>' + '<p>Many words across several pages to exercise the native pagination and restore behavior.</p>'.repeat(60) + '<p id="target" onclick="window.publisherEvent=true">Chapter target</p></body>';
const html = '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><!-- <head> decoy --><head><title>Smoke</title><script>window.publisherExecuted=true;</script></head>' + body + '</html>';
fs.writeFileSync(path.join(book, 'chapter.xhtml'), injectChapterHead(html, tags, nonce));
