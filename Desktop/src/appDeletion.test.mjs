import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

// These tests execute the production App/LibraryView callbacks. React effects,
// native commands, and the library store use isolated in-memory boundaries.
async function loadHelper(path) {
  const source = await readFile(new URL(path, import.meta.url), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(output).toString('base64')}`);
}
async function loadComponent(path) {
  const source = (await readFile(new URL(path, import.meta.url), 'utf8')).replace(/^import .+\n/gm, '').replace(/^export /gm, '');
  return ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None, jsx: ts.JsxEmit.React } }).outputText;
}
const model = await loadHelper('./model.ts');
const preferences = await loadHelper('./preferences.ts');
const appSource = await loadComponent('./App.tsx');
const librarySource = await loadComponent('./components/LibraryView.tsx');
const tick = async () => { for (let n = 0; n < 16; n++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function descendants(element, predicate) {
  if (!element || typeof element !== 'object') return [];
  return [...(predicate(element) ? [element] : []), ...(element.props?.children || []).flat(Infinity).flatMap(child => descendants(child, predicate))];
}
function text(element) {
  if (typeof element === 'string' || typeof element === 'number') return String(element);
  return (element?.props?.children || []).flat(Infinity).map(text).join('');
}
function mount(source, name, dependencies, props = {}) {
  const hooks = [], effects = [];
  let index = 0, tree;
  const equal = (a, b) => a?.length === b.length && b.every((value, n) => Object.is(a[n], value));
  const deps = {
    ...dependencies,
    React: { Fragment: 'Fragment', createElement: (type, props, ...children) => ({ type, props: { ...props, children } }) },
    useRef(initial) { const slot = index++; return hooks[slot] ??= { current: initial }; },
    useState(initial) { const slot = index++; hooks[slot] ??= { value: typeof initial === 'function' ? initial() : initial }; return [hooks[slot].value, value => { hooks[slot].value = typeof value === 'function' ? value(hooks[slot].value) : value; }]; },
    useMemo(create, values) { const slot = index++; if (!hooks[slot] || !equal(hooks[slot].values, values)) hooks[slot] = { values, value: create() }; return hooks[slot].value; },
    useCallback(callback, values) { return deps.useMemo(() => callback, values); },
    useEffect(run, values) { const slot = index++; const old = hooks[slot]; if (!old || !equal(old.values, values)) effects.push(() => { old?.cleanup?.(); hooks[slot] = { values, cleanup: run() }; }); },
  };
  const Component = new Function('deps', `const { ${Object.keys(deps).join(',')} } = deps;\n${source}\nreturn ${name};`)(deps);
  const render = () => { index = 0; tree = Component(props); for (const effect of effects.splice(0)) effect(); return tree; };
  render();
  return { render, find: (predicate, within = tree) => descendants(within, predicate)[0], all: predicate => descendants(tree, predicate), cleanup: () => { for (const hook of hooks) hook?.cleanup?.(); } };
}
function fixtureBook(id, title, extra = {}) {
  return { id, title, author: 'Fixture author', kind: 'epub', importedRelativePath: `Books/${id}.epub`, annotations: [], bookmarks: [], reminders: [], chats: [], progress: 0, addedAt: 1, lastOpenedAt: 0, ...extra };
}
const icons = Object.fromEntries(['AlertCircle', 'BookOpen', 'Check', 'ChevronRight', 'FileText', 'Flame', 'Link', 'LoaderCircle', 'Plus', 'Search', 'Settings', 'X', 'ArrowDownWideNarrow', 'Grid2X2', 'List', 'MoreHorizontal', 'IconButton', 'Modal', 'Spinner', 'Suspense', 'ActionMenu', 'EmptyState'].map(name => [name, name]));
function harness(native, suppliedLibrary) {
  const books = { A: fixtureBook('book-A', 'First fixture'), B: fixtureBook('book-B', 'Selected fixture') };
  let library = suppliedLibrary || { ...structuredClone(model.DEFAULT_LIBRARY), books: { [books.A.id]: books.A, [books.B.id]: books.B } };
  const latest = { current: library }, calls = [], accepted = [];
  let error = null, lazyIndex = 0;
  const accept = next => { accepted.push(next); library = next; latest.current = next; };
  const setError = value => { error = value; };
  const run = async operation => { try { return await operation(); } catch (cause) { setError(cause.message); return undefined; } };
  const useLibrary = () => ({ library, latest, loading: false, error, setError, accept, run, mutateBook: async () => { throw new Error('Unexpected book mutation in deletion test'); }, libraryCommand: async () => { throw new Error('Unexpected library command in deletion test'); } });
  const dependencies = {
    ...icons, ...model, useLibrary,
    lazy: () => ['LibraryView', 'ReaderView', 'GlobalNotes', 'RemindersView', 'SettingsView'][lazyIndex++],
    command: async (name, args) => { calls.push({ name, args }); assert.equal(name, 'book_delete'); return native ? native(name, args, library) : library; },
    isNative: () => false, describeError: cause => cause instanceof Error ? cause.message : String(cause),
    subscribe: async () => () => {}, registerEditor: () => () => {}, flushEditors: async () => {},
    openReaderPublication: async () => { throw new Error('Unexpected reader opening'); }, runReaderCommand: async () => {},
    chooseDocuments: async () => [], chooseExport: async () => null,
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    document: { documentElement: { dataset: {} }, visibilityState: 'visible' }, window: { addEventListener() {}, removeEventListener() {} },
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
  };
  const app = mount(appSource, 'App', dependencies);
  const libraryView = () => mount(librarySource, 'LibraryView', { ...icons, ...model, ...preferences, mediaSource: async () => '' }, app.find(element => element.type === 'LibraryView').props);
  const modal = () => app.find(element => element.type === 'Modal');
  const form = () => app.find(element => element.type === 'form', modal());
  const cancel = () => app.find(element => element.type === 'button' && text(element) === 'Cancel', modal());
  const checkbox = () => app.find(element => element.type === 'input' && element.props.type === 'checkbox', modal());
  function requestRemoval(book) {
    const view = libraryView();
    const menu = view.find(element => element.type === 'ActionMenu' && element.props.label === `Actions for ${book.title}`);
    assert.ok(menu, 'Selected fixture has an actual LibraryView action menu');
    view.find(element => element.type === 'button' && text(element) === 'Remove from library…', menu).props.onClick();
    view.cleanup(); app.render();
  }
  function submit(handler = form().props.onSubmit) {
    let prevented = false; handler({ preventDefault: () => { prevented = true; } }); assert.equal(prevented, true);
  }
  return { app, books, calls, accepted, latest, libraryView, modal, form, cancel, checkbox, requestRemoval, submit, cleanup: app.cleanup };
}

for (const deleteData of [false, true]) {
  test(`the selected card submits book_delete with deleteData=${deleteData} and accepts the native snapshot`, async () => {
    let response;
    const h = harness((_name, args, current) => {
      response = { ...current, books: { ...current.books, [args.bookId]: { ...current.books[args.bookId], removedFromLibrary: true, fixtureResponse: 'native' } } };
      return response;
    });
    h.requestRemoval(h.books.B);
    assert.ok(text(h.modal()).includes(h.books.B.title)); assert.equal(h.checkbox().props.checked, false);
    if (deleteData) { h.checkbox().props.onChange({ target: { checked: true } }); h.app.render(); }
    h.submit(); await tick(); h.app.render();
    assert.deepEqual(h.calls, [{ name: 'book_delete', args: { bookId: h.books.B.id, deleteData } }]);
    assert.equal(h.accepted[0], response); assert.equal(h.latest.current.books[h.books.A.id], h.books.A);
    assert.equal(h.modal(), undefined); h.cleanup();
  });
}

test('cancel makes no native request and a different book starts with reading-data deletion unchecked', () => {
  const h = harness(); h.requestRemoval(h.books.A);
  h.checkbox().props.onChange({ target: { checked: true } }); h.app.render();
  h.cancel().props.onClick(); h.app.render(); assert.equal(h.modal(), undefined); assert.equal(h.calls.length, 0);
  h.requestRemoval(h.books.B); assert.equal(h.checkbox().props.checked, false);
  assert.ok(text(h.modal()).includes(h.books.B.title)); h.modal().props.onClose(); h.app.render();
  assert.equal(h.modal(), undefined); assert.equal(h.calls.length, 0); h.cleanup();
});

test('a native deletion failure keeps the selected dialog and choice available for a successful retry', async () => {
  let attempts = 0;
  const h = harness((_name, _args, current) => { if (++attempts === 1) throw new Error('Fixture disk failure'); return current; });
  h.requestRemoval(h.books.B); h.checkbox().props.onChange({ target: { checked: true } }); h.app.render();
  h.submit(); await tick(); h.app.render();
  assert.equal(h.accepted.length, 0); assert.ok(h.modal()); assert.equal(h.checkbox().props.checked, true);
  assert.equal(text(h.app.find(element => element.props?.className === 'dialog-error')), 'Fixture disk failure');
  assert.equal(h.app.find(element => element.type === 'button' && element.props.type === 'submit', h.modal()).props.disabled, false);
  h.submit(); await tick(); h.app.render();
  assert.equal(h.calls.length, 2); assert.ok(h.calls.every(call => call.args.bookId === h.books.B.id && call.args.deleteData === true));
  assert.equal(h.accepted.length, 1); assert.equal(h.modal(), undefined); h.cleanup();
});

test('duplicate submits and stale close callbacks cannot dismiss or resubmit a pending deletion before rerender', async () => {
  const pending = deferred(); const h = harness(() => pending.promise); h.requestRemoval(h.books.B);
  const submit = h.form().props.onSubmit, oldClose = h.modal().props.onClose, oldCancel = h.cancel().props.onClick;
  h.submit(submit); h.submit(submit); oldClose(); oldCancel();
  assert.equal(h.calls.length, 1); h.app.render(); assert.ok(h.modal());
  assert.equal(h.checkbox().props.disabled, true); assert.equal(h.cancel().props.disabled, true);
  assert.equal(h.app.find(element => element.type === 'button' && element.props.type === 'submit', h.modal()).props.disabled, true);
  h.modal().props.onClose(); h.app.render(); assert.ok(h.modal()); assert.equal(h.accepted.length, 0);
  pending.resolve(h.latest.current); await tick(); h.app.render();
  assert.equal(h.accepted.length, 1); assert.equal(h.modal(), undefined); h.cleanup();
});

test('the actual library view counts and renders local and offline books while retaining hidden notes outside its cards', () => {
  const local = fixtureBook('local', 'Local fixture');
  const offline = fixtureBook('offline', 'Remote offline fixture', { importedRelativePath: 'Books/not-downloaded.epub' });
  const retained = fixtureBook('retained', 'Removed with notes', { removedFromLibrary: true, annotations: [{ id: 'note', note: 'Preserved thought' }] });
  const library = { ...structuredClone(model.DEFAULT_LIBRARY), books: { local, offline, retained } };
  const h = harness(undefined, library); const view = h.libraryView();
  assert.ok(text(view.find(element => element.type === 'header')).includes('2 documents'));
  const cards = view.all(element => element.type === 'article' && element.props.className === 'book-card');
  assert.equal(cards.length, 2); assert.ok(cards.some(card => text(card).includes(local.title))); assert.ok(cards.some(card => text(card).includes(offline.title)));
  assert.equal(cards.some(card => text(card).includes(retained.title)), false);
  assert.equal(h.latest.current.books.retained.annotations[0].note, 'Preserved thought');
  assert.equal(h.calls.length, 0); view.cleanup(); h.cleanup();
});
