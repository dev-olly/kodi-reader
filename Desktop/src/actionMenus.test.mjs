import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('./actionMenus.ts', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { createActionMenuCoordinator } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
const primitiveSource = (await readFile(new URL('./components/Primitives.tsx', import.meta.url), 'utf8')).replace(/^import .+\n/gm, '').replace(/^export /gm, '');
const primitives = ts.transpileModule(primitiveSource, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None, jsx: ts.JsxEmit.React } }).outputText;

function eventBus() {
  const listeners = new Map(), adds = [], removes = [];
  return {
    listeners, adds, removes,
    addEventListener(name, listener, capture) { adds.push({ name, capture }); if (!listeners.has(name)) listeners.set(name, new Map()); listeners.get(name).set(listener, capture); },
    removeEventListener(name, listener, capture) { removes.push({ name, capture }); assert.equal(listeners.get(name)?.get(listener), capture); listeners.get(name)?.delete(listener); },
    dispatch(name, target, extra = {}) { const event = { type: name, target, defaultPrevented: false, stopped: false, preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.stopped = true; }, ...extra }; const handlers = [...(listeners.get(name) || [])]; for (const [listener, capture] of handlers) if (capture) listener(event); extra.atTarget?.(event); for (const [listener, capture] of handlers) if (!capture) listener(event); return event; },
    count() { return [...listeners.values()].reduce((count, values) => count + values.size, 0); },
  };
}
function fixture() {
  const document = eventBus(); document.defaultView = eventBus();
  function node(tagName, parent = null) {
    const value = {
      nodeType: 1, tagName: tagName.toUpperCase(), parentElement: parent, children: [], ownerDocument: document, open: false, disabled: false, focusCount: 0,
      contains(other) { for (let item = other; item; item = item.parentElement) if (item === this) return true; return false; },
      querySelector(selector) { return this.children.find(child => child.tagName.toLowerCase() === selector) || null; },
      closest(selector) { const choices = selector.split(', '); for (let item = this; item; item = item.parentElement) if (choices.includes(item.tagName.toLowerCase()) || choices.includes('[role="menuitem"]') && item.role === 'menuitem') return item; return null; },
      getAttribute(name) { return this[name] ?? null; },
      focus(options) { assert.deepEqual(options, { preventScroll: true }); this.focusCount++; document.activeElement = this; document.dispatch('focusin', this); },
    };
    parent?.children.push(value); return value;
  }
  const outside = node('main');
  const menu = () => { const details = node('details'), summary = node('summary', details), popover = node('div', details), button = node('button', popover), icon = node('svg', button); return { details, summary, button, icon }; };
  return { document, node, outside, menu, coordinator: createActionMenuCoordinator(document) };
}

test('summary clicks without pointer events open one action menu and close the previous one', () => {
  const f = fixture(), a = f.menu(), b = f.menu();
  f.coordinator.register(a.details); f.coordinator.register(b.details);
  assert.equal(f.document.dispatch('click', a.summary).defaultPrevented, true);
  assert.equal(a.details.open, true);
  f.document.dispatch('click', b.summary);
  assert.equal(a.details.open, false); assert.equal(b.details.open, true);
  f.document.dispatch('click', b.summary); assert.equal(b.details.open, false);
});

test('outside pointer, click, keyboard focus and window blur dismiss without taking outside focus', () => {
  for (const name of ['pointerdown', 'click', 'focusin', 'blur']) {
    const f = fixture(), menu = f.menu(); f.coordinator.register(menu.details);
    f.document.dispatch('click', menu.summary); const focused = menu.summary.focusCount;
    if (name === 'blur') f.document.defaultView.dispatch(name, f.document.defaultView);
    else f.document.dispatch(name, f.outside);
    assert.equal(menu.details.open, false, name);
    assert.equal(menu.summary.focusCount, focused, name);
  }
});

test('Escape closes the active action menu and returns focus to its trigger', () => {
  const f = fixture(), menu = f.menu(); f.coordinator.register(menu.details);
  f.document.dispatch('click', menu.summary); const focused = menu.summary.focusCount;
  const event = f.document.dispatch('keydown', menu.button, { key: 'Escape' });
  assert.equal(event.defaultPrevented, true); assert.equal(event.stopped, true);
  assert.equal(menu.details.open, false); assert.equal(menu.summary.focusCount, focused + 1);
});

test('registered programmatic disclosures stay exclusive while informational details are untouched', () => {
  const f = fixture(), a = f.menu(), b = f.menu(), information = f.node('details');
  f.coordinator.register(a.details); f.coordinator.register(b.details);
  a.details.open = true; f.document.dispatch('toggle', a.details);
  b.details.open = true; f.document.dispatch('toggle', b.details);
  information.open = true; f.document.dispatch('toggle', information);
  assert.equal(a.details.open, false); assert.equal(b.details.open, true); assert.equal(information.open, true);
  f.document.dispatch('pointerdown', f.outside); assert.equal(information.open, true);
});

test('disabled actions stay open and enabled actions remain visible through activation', () => {
  const f = fixture(), menu = f.menu(); f.coordinator.register(menu.details);
  f.document.dispatch('click', menu.summary);
  menu.button.disabled = true; f.document.dispatch('click', menu.icon); assert.equal(menu.details.open, true);
  menu.button.disabled = false;
  let activated = false;
  const event = f.document.dispatch('click', menu.icon, { atTarget() { assert.equal(menu.details.open, true); activated = true; } });
  assert.equal(activated, true);
  assert.equal(menu.details.open, false); assert.equal(event.defaultPrevented, false);
});

test('one listener set survives multiple mounts and is removed after the last cleanup', () => {
  const f = fixture(), a = f.menu(), b = f.menu();
  const cleanupA = f.coordinator.register(a.details), cleanupB = f.coordinator.register(b.details);
  assert.equal(f.document.adds.length, 6); assert.equal(f.document.defaultView.adds.length, 1);
  cleanupA(); assert.equal(f.document.count(), 6);
  cleanupB(); cleanupB(); assert.equal(f.document.count(), 0); assert.equal(f.document.defaultView.count(), 0);
  assert.equal(f.document.removes.length, 6);
  const remount = f.coordinator.register(a.details); f.document.dispatch('click', a.summary);
  assert.equal(a.details.open, true); remount(); assert.equal(a.details.open, false); assert.equal(f.document.count(), 0);
});

test('the actual ActionMenu preserves its child callback and leaves focus in the opened dialog', () => {
  const f = fixture(), menu = f.menu(); let effect, cleanup, opened = false;
  const dialogInput = f.node('input');
  const button = { type: 'button', props: { onClick() { assert.equal(menu.details.open, true); opened = true; f.document.activeElement = dialogInput; } } };
  const dependencies = {
    React: { createElement: (type, props, ...children) => ({ type, props: { ...props, children } }) },
    useRef: () => ({ current: null }), useLayoutEffect: callback => { effect = callback; },
    registerActionMenu: element => f.coordinator.register(element),
  };
  const ActionMenu = new Function('dependencies', `const {${Object.keys(dependencies).join(',')}} = dependencies;\n${primitives}\nreturn ActionMenu;`)(dependencies);
  const tree = ActionMenu({ label: 'Book actions', trigger: '•••', className: 'book-menu', children: button });
  tree.props.ref.current = menu.details; cleanup = effect();
  assert.equal(tree.type, 'details'); assert.equal(tree.props.className, 'book-menu');
  assert.equal(tree.props.children[0].type, 'summary'); assert.equal(tree.props.children[0].props['aria-label'], 'Book actions');
  f.document.dispatch('click', menu.summary);
  f.document.dispatch('click', menu.button, { detail: 0, atTarget() { button.props.onClick(); } });
  assert.equal(opened, true); assert.equal(menu.details.open, false); assert.equal(f.document.activeElement, dialogInput);
  cleanup(); assert.equal(f.document.count(), 0);
});
test('moving focus from the summary to an item cannot dismiss it before its click', () => {
  const f = fixture(), menu = f.menu(); f.coordinator.register(menu.details);
  f.document.dispatch('click', menu.summary);
  // A captured element blur used to call the application's window-blur
  // handler, hiding the menu on pointer down before WebKit could click it.
  f.document.defaultView.dispatch('blur', menu.summary);
  assert.equal(menu.details.open, true);
  f.document.dispatch('pointerdown', menu.button);
  menu.button.focus({ preventScroll: true });
  assert.equal(menu.details.open, true);
  let activated = false;
  f.document.dispatch('click', menu.button, { atTarget() { assert.equal(menu.details.open, true); activated = true; } });
  assert.equal(activated, true); assert.equal(menu.details.open, false);
});
