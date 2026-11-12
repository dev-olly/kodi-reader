import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('./audioPlayback.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { audioCardPlayback } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
const focusSource = await readFile(new URL('./inputFocus.ts', import.meta.url), 'utf8');
const focusJs = ts.transpileModule(focusSource, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { focusRangeControl, ownsKeyboardInput } = await import(`data:text/javascript;base64,${Buffer.from(focusJs).toString('base64')}`);
const component = (await readFile(new URL('./components/AudioAttachment.tsx', import.meta.url), 'utf8')).replace(/^import .+\n/gm, '').replace(/^export /gm, '');
const compiled = ts.transpileModule(component, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None, jsx: ts.JsxEmit.React } }).outputText;
const path = 'Audio/fixture.m4a';
const tick = async () => { for (let n = 0; n < 12; n++) await Promise.resolve(); };
function deferred() { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; }
function harness(native) {
  const hooks = [], effects = [], listeners = new Set(), intervals = new Set(), calls = [], errors = [];
  let index = 0, tree;
  const props = { audio: { id: 'audio-A', title: 'Recording A', duration: 60, path }, bookId: 'book', annotationId: 'note', onError: error => errors.push(error), onRename() {}, onDelete() {} };
  const deps = {
    React: { createElement: (type, props, ...children) => ({ type, props: { ...props, children } }) },
    useRef(initial) { const slot = index++; return hooks[slot] ??= { current: initial }; },
    useState(initial) { const slot = index++; hooks[slot] ??= { value: typeof initial === 'function' ? initial() : initial }; return [hooks[slot].value, value => { hooks[slot].value = typeof value === 'function' ? value(hooks[slot].value) : value; }]; },
    useEffect(run, dependencies) { const slot = index++; const old = hooks[slot]; if (!old || dependencies.some((value, n) => value !== old.dependencies[n])) effects.push(() => { old?.cleanup?.(); hooks[slot] = { dependencies, cleanup: run() }; }); },
    command: async (name, args) => { calls.push({ name, args }); return native ? native(name, args) : name === 'audio_position' ? { path: null, position: 0, duration: 0 } : {}; },
    subscribe: async (_name, callback) => { listeners.add(callback); return () => listeners.delete(callback); },
    setInterval: callback => { intervals.add(callback); return callback; }, clearInterval: callback => intervals.delete(callback),
    audioCardPlayback, focusRangeControl, duration: value => String(value), chooseExport: async () => null,
    IconButton: 'IconButton', ActionMenu: 'ActionMenu', Spinner: 'Spinner', Check: 'Check', Download: 'Download', Pause: 'Pause', Play: 'Play', Sparkles: 'Sparkles', Trash2: 'Trash2',
  };
  const AudioAttachment = new Function('deps', `const { ${Object.keys(deps).join(',')} } = deps;\n${compiled}\nreturn AudioAttachment;`)(deps);
  function render() { index = 0; tree = AudioAttachment(props); for (const effect of effects.splice(0)) effect(); return tree; }
  function find(predicate, element = tree) { if (!element || typeof element !== 'object') return null; if (predicate(element)) return element; for (const child of (element.props?.children || []).flat(Infinity)) { const result = find(predicate, child); if (result) return result; } return null; }
  render();
  return { props, calls, errors, render, find, intervals, emit: status => { for (const listener of listeners) listener(status); }, cleanup: () => { for (const hook of hooks) hook?.cleanup?.(); }, playButton: () => find(element => element.type === 'IconButton' && /^(Play|Pause|Opening)/.test(element.props.label)) };
}

test('recording status belongs to its path and narration cannot own an attachment card', () => {
  assert.deepEqual(audioCardPlayback(path, { phase: 'playing', path, duration: 60, elapsed: 9 }), { active: true, paused: false, duration: 60, position: 9 });
  for (const status of [{ phase: 'playing', title: 'Listen', duration: 60 }, { phase: 'playing', path: 'Audio/other.m4a', duration: 60 }, { phase: 'idle', path }, { phase: 'playing', path, cancelled: true }]) assert.equal(audioCardPlayback(path, status).active, false);
});

test('native ownership changes deactivate the old card before its next control click', async () => {
  const h = harness(); await tick();
  h.emit({ phase: 'playing', path, duration: 60, elapsed: 9 }); h.render();
  assert.match(h.playButton().props.label, /^Pause/);
  h.emit({ phase: 'playing', title: 'Listen', duration: 100 });
  h.playButton().props.onClick(); await tick(); h.render();
  assert.equal(h.calls.filter(call => call.name === 'audio_pause').length, 0);
  assert.equal(h.calls.filter(call => call.name === 'audio_play').length, 1); h.cleanup();
});

test('a cancelled or delayed old play response cannot reactivate a card for another owner', async () => {
  for (const response of [{ phase: 'idle', cancelled: true }, { phase: 'playing', path, duration: 60 }]) {
    const started = deferred();
    const h = harness(name => name === 'audio_play' ? started.promise : { path: null, duration: 0, position: 0 }); await tick();
    const button = h.playButton(); button.props.onClick(); button.props.onClick(); await tick();
    assert.equal(h.calls.filter(call => call.name === 'audio_play').length, 1);
    h.emit({ phase: 'playing', path: 'Audio/newer.m4a', duration: 60, elapsed: 5 });
    started.resolve(response); await tick(); h.render();
    assert.match(h.playButton().props.label, /^Play/);
    assert.equal(h.find(element => element.props?.className === 'audio-seek'), null); h.cleanup();
  }
});

test('pause and seek carry the expected path and paused events retain elapsed position', async () => {
  const h = harness(name => name === 'audio_pause' ? { phase: 'paused', path, paused: true } : { path: null, duration: 0, position: 0 }); await tick();
  h.emit({ phase: 'playing', path, duration: 60, elapsed: 12 }); h.render();
  h.find(element => element.props?.className === 'audio-seek').props.onChange({ target: { value: '19' } });
  assert.deepEqual(h.calls.find(call => call.name === 'audio_seek').args, { seconds: 19, path });
  h.playButton().props.onClick(); await tick(); h.render();
  assert.deepEqual(h.calls.find(call => call.name === 'audio_pause').args, { paused: true, path });
  assert.equal(h.find(element => element.props?.className === 'audio-seek').props.value, 19); h.cleanup();
});

test('an old position poll cannot reclaim a card after a newer native owner event', async () => {
  const position = deferred(); let reads = 0;
  const h = harness(name => name === 'audio_position' && ++reads > 1 ? position.promise : { path: null, position: 0, duration: 0 }); await tick();
  h.emit({ phase: 'playing', path, duration: 60, elapsed: 2 }); h.render();
  for (const poll of h.intervals) poll();
  h.emit({ phase: 'playing', path: 'Audio/newer.m4a', duration: 60, elapsed: 5 });
  position.resolve({ path, position: 3, duration: 60 }); await tick(); h.render();
  assert.match(h.playButton().props.label, /^Play/); h.cleanup();
});

test('deleting the owned recording stops only its expected path before removing metadata', async () => {
  const h = harness(); await tick(); const order = [];
  h.props.onDelete = () => { order.push('deleted'); };
  h.emit({ phase: 'playing', path, duration: 60, elapsed: 2 }); h.render();
  h.find(element => element.type === 'button' && element.props.children.some(child => child === 'Delete recording')).props.onClick(); await tick();
  assert.deepEqual(h.calls.find(call => call.name === 'audio_stop').args, { path }); assert.deepEqual(order, ['deleted']); h.cleanup();
});

test('deleting while playback is decoding awaits cancellation before removing the recording', async () => {
  const started = deferred(), stopped = deferred(); const order = [];
  const h = harness(name => name === 'audio_play' ? started.promise : name === 'audio_stop' ? (order.push('stop requested'), stopped.promise) : { path: null, position: 0, duration: 0 });
  await tick(); h.props.onDelete = () => { order.push('deleted'); };
  h.playButton().props.onClick(); await tick(); h.render();
  assert.match(h.playButton().props.label, /^Opening/);
  h.find(element => element.type === 'button' && element.props.children.includes('Delete recording')).props.onClick(); await tick();
  assert.deepEqual(h.calls.find(call => call.name === 'audio_stop').args, { path });
  assert.deepEqual(order, ['stop requested']);
  stopped.resolve({}); started.resolve({ phase: 'idle', cancelled: true }); await tick(); h.render();
  assert.deepEqual(order, ['stop requested', 'deleted']); assert.match(h.playButton().props.label, /^Play/); h.cleanup();
});

test('seeking invalidates a delayed old poll and immediate pause retains the new position', async () => {
  const oldPosition = deferred(); let reads = 0;
  const h = harness(name => name === 'audio_position' && ++reads > 1 ? oldPosition.promise : name === 'audio_pause' ? { phase: 'paused', path, paused: true } : { path: null, duration: 0, position: 0 });
  await tick(); h.emit({ phase: 'playing', path, duration: 60, elapsed: 12 }); h.render();
  for (const poll of h.intervals) poll();
  h.find(element => element.props?.className === 'audio-seek').props.onChange({ target: { value: '29' } });
  oldPosition.resolve({ path, duration: 60, position: 12, paused: false }); await tick(); h.render();
  assert.equal(h.find(element => element.props?.className === 'audio-seek').props.value, 29);
  h.playButton().props.onClick(); await tick(); h.render();
  assert.equal(h.find(element => element.props?.className === 'audio-seek').props.value, 29); h.cleanup();
});
test('the recording range keeps keyboard focus after both pointer down and click', async () => {
  const h = harness(); await tick();
  h.emit({ phase: 'paused', path, duration: 60, elapsed: 12 }); h.render();
  const range = h.find(element => element.props?.className === 'audio-seek');
  const body = { tagName: 'BODY', matches: () => false };
  let activeElement = body;
  const input = { tagName: 'INPUT', disabled: false, matches: selector => selector.split(', ').includes('input'), focus() { activeElement = this; } };
  for (const phase of ['onPointerDown', 'onClick']) {
    activeElement = body;
    range.props[phase]({ currentTarget: input });
    for (const key of ['ArrowLeft', 'ArrowRight']) {
      const event = { key, target: activeElement };
      assert.equal(event.target.tagName, 'INPUT');
      assert.equal(ownsKeyboardInput(event.target), true);
    }
  }
  assert.equal(h.calls.some(call => call.name === 'reader_action'), false); h.cleanup();
});
