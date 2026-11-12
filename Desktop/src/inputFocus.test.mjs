import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('./inputFocus.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { focusRangeControl, ownsKeyboardInput } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

test('clicking a range gives its Arrow keys to the input instead of the reader', () => {
  let activeElement = { tagName: 'BODY', matches: () => false };
  const input = {
    tagName: 'INPUT', disabled: false,
    matches: selector => selector.split(', ').includes('input'),
    focus(options) { assert.deepEqual(options, { preventScroll: true }); activeElement = this; },
  };
  assert.equal(ownsKeyboardInput(activeElement), false);
  focusRangeControl({ currentTarget: input });
  for (const key of ['ArrowLeft', 'ArrowRight', 'Home', 'End']) {
    const event = { key, target: activeElement };
    assert.equal(event.target.tagName, 'INPUT');
    assert.equal(ownsKeyboardInput(event.target), true);
  }
});
test('text controls keep keyboard ownership while reading content retains reader shortcuts', () => {
  for (const tag of ['input', 'textarea', 'select']) {
    assert.equal(ownsKeyboardInput({ matches: selector => selector.split(', ').includes(tag) }), true);
  }
  assert.equal(ownsKeyboardInput({ matches: () => false, isContentEditable: true }), true);
  assert.equal(ownsKeyboardInput({ matches: () => false, isContentEditable: false }), false);
  assert.equal(ownsKeyboardInput(null), false);
  assert.equal(ownsKeyboardInput({}), false);
});
