import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
// Run the actual component callbacks with deterministic React/native boundaries.
// Native commands below are test doubles; no microphone or app connection is used.
const root = new URL('./', import.meta.url);
async function helper(path) {
  const source = await readFile(new URL(path, root), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
}
const { createDraftFlusher } = await helper('editorLifecycle.ts');
const { noteReferences, removeNoteReference, renameNoteReference, insertAudioTranscript } = await helper('noteMedia.ts');
const source = (await readFile(new URL('components/NotesPanel.tsx', root), 'utf8')).replace(/^import .+\n/gm, '').replace(/^export /gm, '');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None, jsx: ts.JsxEmit.React } }).outputText;
const icons = ['ArrowLeft', 'Bold', 'Check', 'Code', 'Download', 'FileText', 'Italic', 'List', 'Mic', 'Pause', 'Pencil', 'Play', 'Plus', 'Search', 'Sparkles', 'Square', 'Trash2', 'IconButton', 'ActionMenu', 'EmptyState', 'AudioAttachment', 'SketchAttachment', 'ReactMarkdown', 'remarkGfm', 'Suspense'];
const tick = async () => { for (let n = 0; n < 12; n++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function harness({ update, native, annotation } = {}) {
  const hooks = [], effects = [], registry = new Set(), calls = [], writes = [], errors = [], reminders = [], openedReminders = [];
  let index = 0, tree, serial = 0;
  const props = {
    book: { id: 'book-A', kind: 'epub' },
    annotation: { id: 'note-A', note: 'A thought', text: 'quote', color: 'yellow', locator: { spineIndex: 0 }, sketches: [], audioRecordings: [], createdAt: 1, modifiedAt: 1, ...annotation },
    onUpdate: async (id, changes) => { writes.push(changes); const result = update ? await update(id, changes, writes.length) : {}; if (result !== undefined) props.annotation = { ...props.annotation, ...changes }; return result; },
    onError: error => errors.push(error), onReminder: (...args) => reminders.push(args), onOpenReminder: id => { openedReminders.push(id); }, onDelete() {}, onBack() {}, onExport() {},
  };
  const deps = {
    React: { createElement: (type, props, ...children) => ({ type, props: { ...props, children } }) },
    lazy: () => 'MarkdownEditor',
    useRef(initial) { const slot = index++; return hooks[slot] ??= { current: initial }; },
    useState(initial) { const slot = index++; hooks[slot] ??= { value: typeof initial === 'function' ? initial() : initial }; return [hooks[slot].value, value => { hooks[slot].value = typeof value === 'function' ? value(hooks[slot].value) : value; }]; },
    useEffect(run, dependencies) { const slot = index++; const old = hooks[slot]; if (!old || dependencies.some((value, n) => value !== old.dependencies[n])) effects.push(() => { old?.cleanup?.(); hooks[slot] = { dependencies, cleanup: run() }; }); },
    registerEditor: callback => { registry.add(callback); return () => registry.delete(callback); },
    createDraftFlusher, noteReferences, removeNoteReference, renameNoteReference, insertAudioTranscript,
    command: async (name, args) => { calls.push({ name, args }); if (native) return native(name, args); if (name === 'audio_record_finish') return { books: { 'book-A': { annotations: [props.annotation] } } }; return {}; },
    describeError: error => error instanceof Error ? error.message : String(error),
    now: () => 123, uuid: () => `00000000-0000-4000-8000-${String(++serial).padStart(12, '0')}`,
    HIGHLIGHTS: [], duration: () => '', navigator: { platform: 'MacIntel' },
    setTimeout: () => 1, clearTimeout() {},
  };
  for (const name of icons) deps[name] = name;
  const factory = new Function('deps', `const { ${Object.keys(deps).join(',')} } = deps;\n${compiled}\nreturn NoteEditor;`);
  const NoteEditor = factory(deps);
  function render() { index = 0; tree = NoteEditor(props); for (const effect of effects.splice(0)) effect(); return tree; }
  function find(predicate, element = tree) { if (!element || typeof element !== 'object') return null; if (predicate(element)) return element; for (const child of (element.props?.children || []).flat(Infinity)) { const result = find(predicate, child); if (result) return result; } return null; }
  function cleanup() { for (const hook of hooks) hook?.cleanup?.(); }
  function strictRemount() { cleanup(); for (let n = 0; n < hooks.length; n++) if (hooks[n]?.dependencies) hooks[n] = undefined; render(); }
  render();
  return { render, find, cleanup, strictRemount, props, calls, writes, errors, reminders, openedReminders, registry, editor: () => find(element => element.type === 'MarkdownEditor').props };
}

test('a sketch remains attached when typing and blur overlap its delayed save', async () => {
  const first = deferred(), second = deferred();
  const h = harness({ update: (_id, _changes, count) => count === 1 ? first.promise : count === 2 ? second.promise : {} });
  const action = h.editor().onCommand('sketch', ''); await tick();
  assert.equal(h.writes.length, 1); assert.equal(h.writes[0].sketches.length, 1);
  h.render(); const text = h.editor().value + '\nTyped while saving'; h.editor().onChange(text); h.editor().onBlur();
  first.resolve({}); await tick();
  assert.equal(h.writes.length, 2); assert.equal(h.writes[1].note, text); assert.equal(h.writes[1].sketches.length, 1);
  assert.equal(h.calls.length, 0); second.resolve({}); await action;
  assert.deepEqual(h.calls.map(call => call.name), ['sketch_open']); h.cleanup(); await tick();
});

test('a failed note save blocks a reminder and rejects its slash command for retry', async () => {
  const h = harness({ update: async () => undefined });
  h.editor().onChange('Unsaved thought');
  await assert.rejects(h.editor().onCommand('remind', 'Research topic'), /could not be saved/);
  assert.equal(h.reminders.length, 0); assert.equal(h.errors.length, 1);
  h.render(); assert.ok(h.find(element => element.props?.role === 'alert')); h.cleanup(); await tick();
});

test('duplicate recording commands reject while teardown waits for the original start then finishes it', async () => {
  const started = deferred(); let h;
  h = harness({ native: name => name === 'audio_record_start' ? started.promise : name === 'audio_record_finish' ? { books: { 'book-A': { annotations: [h.props.annotation] } } } : {} });
  const action = h.editor().onCommand('audio', ''); await tick();
  await assert.rejects(h.editor().onCommand('audio', ''), /Wait for the current note action/);
  const flush = [...h.registry][0](); await tick(); assert.equal(h.calls.length, 1);
  started.resolve({}); await action; await flush;
  assert.deepEqual(h.calls.map(call => call.name), ['audio_record_start', 'audio_record_finish']); h.cleanup(); await tick();
});

test('an unexpected unmount safely finishes a late recording start without opening a microphone in the test', async () => {
  const started = deferred(); let h;
  h = harness({ native: name => name === 'audio_record_start' ? started.promise : name === 'audio_record_finish' ? { books: { 'book-A': { annotations: [h.props.annotation] } } } : {} });
  const action = h.editor().onCommand('audio', ''); await tick(); h.cleanup(); await tick();
  assert.equal(h.registry.size, 0); started.resolve({}); await action; await tick();
  assert.deepEqual(h.calls.map(call => call.name), ['audio_record_start', 'audio_record_finish']);
});

test('retrying a failed sketch save preserves its original identity', async () => {
  const h = harness({ update: async (_id, _changes, count) => count === 1 ? undefined : {} });
  await assert.rejects(h.editor().onCommand('sketch', ''), /sketch could not be saved/);
  const id = h.writes[0].sketches[0].id;
  h.render(); const retry = h.find(element => element.type === 'button' && element.props.children.includes('Try again'));
  assert.ok(retry); retry.props.onClick(); await tick();
  assert.equal(h.writes.length, 2); assert.equal(h.writes[1].sketches.length, 1); assert.equal(h.writes[1].sketches[0].id, id);
  assert.equal(h.calls[0].args.sketchId, id); h.cleanup(); await tick();
});

for (const [name, argument] of [['sketch', ''], ['audio', ''], ['remind', 'Research topic']]) {
  test(`a restored /${name} retries through the parser instead of leaving command text behind`, async () => {
    let canSave = false, h;
    h = harness({
      update: async () => canSave ? {} : undefined,
      native: command => command === 'audio_record_finish' ? { books: { 'book-A': { annotations: [h.props.annotation] } } } : {},
    });
    const afterRemoval = 'A changed thought';
    h.editor().onChange(afterRemoval);
    await assert.rejects(h.editor().onCommand(name, argument), /could not be saved/);
    h.render();
    const oldRetry = h.find(element => element.type === 'button' && element.props.children.includes('Try again'));
    assert.ok(oldRetry);

    // MarkdownEditor restores this text after the callback rejects. Its
    // synchronous onChange reaches the parent before the next React render.
    h.editor().onChange(`${afterRemoval}\n/${name}${argument ? ` ${argument}` : ''}`);
    const callsBeforeRetry = h.calls.length, writesBeforeRetry = h.writes.length;
    oldRetry.props.onClick(); await tick();
    assert.equal(h.calls.length, callsBeforeRetry);
    assert.equal(h.writes.length, writesBeforeRetry);
    h.render();
    assert.equal(h.find(element => element.type === 'button' && element.props.children.includes('Try again')), null);
    const alert = h.find(element => element.props?.role === 'alert');
    assert.ok(JSON.stringify(alert).includes('Press Enter on the command'));

    // Enter consumes the restored command before invoking the callback again.
    canSave = true; h.editor().onChange(afterRemoval);
    await h.editor().onCommand(name, argument);
    assert.ok(h.writes.every(write => !write.note.includes(`/${name}`)));
    if (name === 'sketch') assert.equal(h.calls.filter(call => call.name === 'sketch_open').length, 1);
    if (name === 'audio') assert.equal(h.calls.filter(call => call.name === 'audio_record_start').length, 1);
    if (name === 'remind') assert.equal(h.reminders[0][0], argument);
    h.cleanup(); await tick();
  });
}

test('Strict Mode setup-cleanup-setup does not finalize the new editor owner', async () => {
  const h = harness(); h.strictRemount(); await tick();
  assert.equal(h.registry.size, 1); assert.equal(h.errors.length, 0);
  await h.editor().onCommand('remind', 'Topic'); assert.equal(h.reminders.length, 1); h.cleanup(); await tick();
});

test('renaming a sketch serializes its link, metadata, and typing during the delayed write', async () => {
  const id = 'aabbccdd-1234-5678-abcd-1234567890ab'; const first = deferred();
  const h = harness({ annotation: { note: `[Old](kodi-sketch://${id})`, sketches: [{ id, title: 'Old' }] }, update: (_id, _changes, count) => count === 1 ? first.promise : {} });
  const renamed = h.find(element => element.type === 'SketchAttachment').props.onRename('New [idea]'); await tick();
  assert.equal(h.writes[0].sketches[0].title, 'New [idea]');
  h.render(); const latest = h.editor().value + '\nTyped during rename'; h.editor().onChange(latest); h.editor().onBlur();
  first.resolve({}); await renamed;
  assert.equal(h.writes.at(-1).note, latest); assert.equal(h.writes.at(-1).sketches[0].title, 'New [idea]');
  assert.ok(latest.includes('[New \\[idea\\]]')); h.cleanup(); await tick();
});

test('legacy attachment metadata-only renames persist even when no Markdown link changes', async () => {
  const id = 'aabbccdd-1234-5678-abcd-1234567890ab';
  const h = harness({ annotation: { audioRecordings: [{ id, title: 'Old', path: 'Audio/fixture.m4a' }] } });
  await h.find(element => element.type === 'AudioAttachment').props.onRename('Named recording');
  assert.equal(h.writes.length, 1); assert.equal(h.writes[0].note, 'A thought');
  assert.equal(h.writes[0].audioRecordings[0].title, 'Named recording'); h.cleanup(); await tick();
});

test('deleting legacy media cannot be reversed by a concurrent autosave or old props', async () => {
  const id = 'aabbccdd-1234-5678-abcd-1234567890ab'; const first = deferred();
  const h = harness({ annotation: { sketches: [{ id, title: 'Legacy sketch' }] }, update: (_id, _changes, count) => count === 1 ? first.promise : {} });
  const removed = h.find(element => element.type === 'SketchAttachment').props.onDelete(); await tick();
  assert.equal(h.writes[0].sketches.length, 0); h.render();
  h.editor().onChange('Typing while deleting'); h.editor().onBlur(); first.resolve({}); await removed;
  assert.equal(h.writes.at(-1).sketches.length, 0); assert.equal(h.writes.at(-1).note, 'Typing while deleting'); h.cleanup(); await tick();
});

test('preview reminder links open the existing reminder after saving rather than create another', async () => {
  const id = 'aabbccdd-1234-5678-abcd-1234567890ab'; const h = harness();
  h.editor().onChange('Latest reminder context');
  h.find(element => element.type === 'button' && element.props.children.includes('Preview')).props.onClick(); await tick(); h.render();
  h.find(element => typeof element.type === 'function' && element.type.name === 'MarkdownPreview').props.onReference('reminder', id); await tick();
  assert.equal(h.writes.at(-1).note, 'Latest reminder context'); assert.deepEqual(h.openedReminders, [id]); assert.equal(h.reminders.length, 0); h.cleanup(); await tick();
});

test('recording transcripts can be inserted and saved below their live audio reference', async () => {
  const id = 'aabbccdd-1234-5678-abcd-1234567890ab';
  const h = harness({ annotation: { note: `[Audio](kodi-audio://${id})`, audioRecordings: [{ id, transcript: 'Words from my recording.' }] } });
  await h.find(element => element.type === 'AudioAttachment').props.onAddTranscript();
  assert.ok(h.writes.at(-1).note.includes(`kodi-audio://${id})\n\nWords from my recording\\.`));
  assert.equal(h.writes.at(-1).audioRecordings.length, 1); h.cleanup(); await tick();
});
