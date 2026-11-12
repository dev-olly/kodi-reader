import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('./noteMedia.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { noteReferences, removeNoteReference, renameNoteReference, insertAudioTranscript, notePreviewText } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
const id = 'AABBCCDD-1234-5678-ABCD-1234567890AB';
const audio = `[A thought \\[from today\\]](kodi-audio://${id})`;
test('Apple uppercase media UUIDs and escaped labels remain recognizable', () => {
  const refs = noteReferences(audio);
  assert.equal(refs.length, 1); assert.equal(refs[0].kind, 'audio'); assert.equal(refs[0].id, id.toLowerCase());
});
test('media links inside fenced examples are never treated as attachments', () => {
  const markdown = `\`\`\`md\n${audio}\n\`\`\`\n\n${audio}\n\n~~~~\n${audio}\n~~~\n${audio}\n~~~~\n`;
  assert.equal(noteReferences(markdown).length, 1);
});
test('deleting an attachment removes only its live link, preserving code examples', () => {
  const markdown = `Before\n\n${audio}\n\n\`\`\`md\n${audio}\n\`\`\`\n\nAfter`;
  const removed = removeNoteReference(markdown, 'audio', id.toLowerCase());
  assert.equal(noteReferences(removed).length, 0);
  assert.ok(removed.includes(`\`\`\`md\n${audio}\n\`\`\``));
  assert.ok(removed.startsWith('Before')); assert.ok(removed.endsWith('After'));
});
test('inline and malformed attachment links remain ordinary Markdown', () => {
  assert.equal(noteReferences(`An inline ${audio}\n[Broken](kodi-audio://------------------------------------)`).length, 0);
});
test('renaming media updates live link labels with Markdown escapes and preserves fenced examples', () => {
  const markdown = `${audio}\n\n\`\`\`md\n${audio}\n\`\`\`\n\nOther ${audio}`;
  const renamed = renameNoteReference(markdown, 'audio', id.toLowerCase(), 'New [idea] \\ draft');
  assert.equal(noteReferences(renamed)[0].line, `[New \\[idea\\] \\\\ draft](kodi-audio://${id})`);
  assert.ok(renamed.includes(`\`\`\`md\n${audio}\n\`\`\``));
  assert.ok(renamed.endsWith(`Other ${audio}`));
  assert.equal(renameNoteReference(`[Old](KODI-AUDIO://${id})`, 'audio', id, 'New'), `[New](KODI-AUDIO://${id})`);
});
test('transcript insertion targets the live recording reference and inserts editable literal text', () => {
  const markdown = `\`\`\`md\n${audio}\n\`\`\`\n\n${audio}\n\nAfter`;
  const inserted = insertAudioTranscript(markdown, id.toLowerCase(), ' # Heading\r\n*literal* [words] ');
  assert.equal(inserted, `\`\`\`md\n${audio}\n\`\`\`\n\n${audio}\n\n\\# Heading\n\\*literal\\* \\[words\\]\n\nAfter`);
  assert.equal(insertAudioTranscript(`\`\`\`\n${audio}\n\`\`\``, id, 'words'), null);
  assert.equal(insertAudioTranscript(audio, id, ' \n'), null);
});
test('plain note snippets retain attachment labels while hiding internal destinations and UUIDs', () => {
  const preview = notePreviewText(`# My thought\n\n**An idea**\n${audio}\n[Check source](kodi-reminder://${id})\n[Sketch](kodi-sketch://${id})\n[Website](https://example.com/article)`);
  assert.equal(preview, 'My thought An idea A thought [from today] Check source Sketch Website');
  assert.equal(preview.includes('kodi-'), false); assert.equal(preview.includes(id), false);
});
