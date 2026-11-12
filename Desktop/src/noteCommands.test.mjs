import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
import { CompletionContext } from '@codemirror/autocomplete';
import { EditorSelection, EditorState } from '@codemirror/state';
import { keymap, runScopeHandlers } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';

const source = await readFile(new URL('./noteCommands.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
  .replace(/from\s+(['"])(@codemirror\/[^'"]+)\1/g, (_match, _quote, name) => `from ${JSON.stringify(import.meta.resolve(name))}`);
const { noteCommandExtensions } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

function editor(doc, position = doc.length) {
  const calls = [];
  let state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(position),
    extensions: [markdown(), history(), noteCommandExtensions((name, argument) => calls.push({ name, argument })), keymap.of([...defaultKeymap, ...historyKeymap])],
  });
  const view = { get state() { return state; }, dispatch(spec) { state = state.update(spec).state; }, focus() {} };
  const enter = () => runScopeHandlers(view, { key: 'Enter', code: 'Enter', keyCode: 13, shiftKey: false, ctrlKey: false, metaKey: false, altKey: false, stopPropagation() {} }, 'editor');
  return { view, calls, enter };
}

async function commandCompletions(view) {
  const context = new CompletionContext(view.state, view.state.selection.main.head, false);
  for (const source of view.state.languageDataAt('autocomplete', context.pos)) {
    if (typeof source !== 'function') continue;
    const result = await source(context);
    if (result?.options.some(option => ['/sketch', '/audio', '/remind'].includes(option.label))) return result;
  }
  return null;
}

test('all three slash commands execute on Enter with real Markdown keymaps installed', () => {
  for (const [text, name, argument] of [['/sketch', 'sketch', ''], ['/audio', 'audio', ''], ['/remind Research this idea', 'remind', 'Research this idea']]) {
    const current = editor(text);
    assert.equal(current.enter(), true);
    assert.deepEqual(current.calls, [{ name, argument }]);
    assert.equal(current.view.state.doc.toString(), '');
  }
});

test('command aliases, leading spaces, case and reminder arguments are normalized', () => {
  for (const [text, name, argument] of [['  /DrAw  ', 'sketch', ''], [' /AuDiO', 'audio', ''], ['   /TASK  Look up the source  ', 'remind', 'Look up the source']]) {
    const current = editor(text);
    current.enter();
    assert.deepEqual(current.calls, [{ name, argument }]);
    assert.equal(current.view.state.doc.toString(), '');
  }
});

test('commands inside fenced, indented and inline code never execute or offer command completions', async () => {
  for (const text of [
    '```\n/sketch\n```',
    '~~~text\n/audio\n~~~',
    '    /remind Keep this example',
    '\t/sketch',
    '`example\n/audio\n`',
  ]) {
    const newline = text.indexOf('\n', text.indexOf('/'));
    const position = newline < 0 ? text.length : newline;
    const current = editor(text, position);
    assert.equal(await commandCompletions(current.view), null, text);
    current.enter();
    assert.deepEqual(current.calls, [], text);
    assert.ok(current.view.state.doc.toString().includes(text.includes('/audio') ? '/audio' : text.includes('/remind') ? '/remind' : '/sketch'), text);
  }
});

test('genuine prose, unknown commands and a cursor in the middle remain text', async () => {
  for (const text of ['A thought about /sketch', '/sketch is a useful example', '/audio recording example', '/unknown', '- /sketch']) {
    const current = editor(text);
    assert.equal(await commandCompletions(current.view), null, text);
    current.enter();
    assert.deepEqual(current.calls, [], text);
    assert.ok(current.view.state.doc.toString().includes(text), text);
  }
  const current = editor('/sketch', 3);
  assert.equal(await commandCompletions(current.view), null);
  current.enter();
  assert.deepEqual(current.calls, []);
});

test('typing slash exposes all actions and picker apply executes the selected action', async () => {
  const current = editor('An earlier thought\n  /');
  const result = await commandCompletions(current.view);
  assert.deepEqual(result.options.map(option => option.label), ['/sketch', '/audio', '/remind']);
  const option = result.options[1];
  option.apply(current.view, option, result.from, result.to);
  assert.deepEqual(current.calls, [{ name: 'audio', argument: '' }]);
  assert.equal(current.view.state.doc.toString(), 'An earlier thought\n');
});

test('picker apply accepts partial aliases and preserves a reminder argument', async () => {
  for (const [text, name, argument] of [[' /DRA', 'sketch', ''], ['/remind Find the original paper', 'remind', 'Find the original paper']]) {
    const current = editor(text);
    const result = await commandCompletions(current.view);
    assert.equal(result.options.length, 1);
    const option = result.options[0];
    option.apply(current.view, option, result.from, result.to);
    assert.deepEqual(current.calls, [{ name, argument }]);
  }
});

test('a stale completion cannot execute after the command line becomes prose', async () => {
  const current = editor('/sk');
  const result = await commandCompletions(current.view);
  current.view.dispatch({ changes: { from: 0, to: 3, insert: 'Plain note text' }, selection: { anchor: 15 } });
  const option = result.options[0];
  option.apply(current.view, option, result.from, result.to);
  assert.deepEqual(current.calls, []);
  assert.equal(current.view.state.doc.toString(), 'Plain note text');
});
