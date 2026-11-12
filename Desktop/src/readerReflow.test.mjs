import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../public/vendor/reader/reader.js', import.meta.url), 'utf8');

// Run the actual reader with deterministic layout/animation boundaries. The
// synthetic DOM has one durable text anchor per page; configure still uses the
// real asynchronous relayout, navigation and position restoration code.
function runtime(pageCount = 2) {
  let timerId = 0;
  const timers = new Map();
  const styleValues = new Map();
  const style = { setProperty: (key, value) => styleValues.set(key, value), getPropertyValue: key => styleValues.get(key) || '' };
  const element = () => ({ nodeType: 1, style, childNodes: [], classList: { remove() {}, contains: () => false }, addEventListener() {}, querySelectorAll: () => [], contains(node) { return this.childNodes.includes(node); }, appendChild(node) { node.parentNode = this; this.childNodes.push(node); } });
  const root = { ...element(), clientWidth: 800, offsetWidth: 800, scrollWidth: pageCount * 800, scrollLeft: 0, scrollTop: 0, scrollTo({ left }) { this.scrollLeft = left; } };
  const body = element();
  function setPageCount(count) {
    root.scrollWidth = count * 800;
    const chrome = body.childNodes.filter(node => node.nodeType !== 3);
    body.childNodes = Array.from({ length: count }, (_, index) => ({ nodeType: 3, parentNode: body, worldX: index * 800 + 72, textContent: `Page ${index + 1} text`, length: 11 }));
    body.childNodes.push(...chrome);
  }
  setPageCount(pageCount);
  function range() {
    return {
      startContainer: body.childNodes[0], startOffset: 0,
      selectNodeContents(node) { this.startContainer = node; },
      setStart(node, offset) { this.startContainer = node; this.startOffset = offset; }, setEnd() {},
      getBoundingClientRect() { const left = this.startContainer.worldX - root.scrollLeft; return { left, right: left + 100, top: 72, bottom: 92, width: 100, height: 20 }; },
      getClientRects() { return [this.getBoundingClientRect()]; },
    };
  }
  const document = {
    readyState: 'complete', title: 'Reflow fixture', documentElement: root, body, scrollingElement: root,
    addEventListener() {}, querySelectorAll: () => [], createElement: element,
    getElementById: id => body.childNodes.find(node => node.id === id) || null,
    createRange: range,
    createTreeWalker(_node, kind) { const nodes = body.childNodes.filter(node => kind === 4 ? node.nodeType === 3 : node.nodeType === 1); let index = 0; return { nextNode: () => nodes[index++] || null }; },
    caretRangeFromPoint() { const result = range(); result.startContainer = body.childNodes[Math.min(Math.floor(root.scrollLeft / 800), body.childNodes.length - 1)]; return result; },
  };
  const getComputedStyle = () => ({ ...style, marginLeft: '0px', marginRight: '0px', paddingLeft: '72px', paddingRight: '72px', columnGap: '144px' });
  const window = { innerWidth: 800, innerHeight: 600, getComputedStyle, addEventListener() {}, __kodiPost() {} };
  vm.runInNewContext(source, { window, document, getComputedStyle, Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 }, NodeFilter: { SHOW_TEXT: 4, SHOW_ELEMENT: 1 }, setTimeout: callback => { const id = ++timerId; timers.set(id, callback); return id; }, clearTimeout: id => timers.delete(id), requestAnimationFrame: callback => { const id = ++timerId; timers.set(id, callback); return id; } });
  window.__reader.start({ twoPageSpread: false, animatePageTurns: false });
  function settle() {
    for (let attempts = 0; timers.size && attempts < 30; attempts++) { const pending = [...timers.entries()]; timers.clear(); for (const [, callback] of pending) callback(); }
    assert.equal(timers.size, 0, 'layout should settle');
  }
  return { reader: window.__reader, root, setPageCount, settle };
}

test('chapter-end navigation survives a configure restore captured at the chapter start', () => {
  const view = runtime();
  view.reader.configure({ marginX: 48 });
  view.reader.goToEnd();
  assert.equal(view.reader.state().page, 1);
  view.settle();
  assert.equal(view.reader.state().page, 1);
});

test('overlapping startup layouts restore the final page using the final page count', () => {
  const view = runtime();
  view.reader.configure({ marginX: 48 }); view.reader.goToEnd();
  view.reader.configure({ marginX: 56 });
  view.setPageCount(3); view.root.scrollLeft = 0;
  view.settle();
  assert.equal(view.reader.state().page, 2);
});

test('deliberate navigation clears the chapter-end intent before later typography changes', () => {
  const view = runtime(3);
  view.reader.configure({ marginX: 48 }); view.reader.goToEnd(); view.settle();
  view.reader.previousPage();
  view.reader.configure({ marginX: 56 }); view.settle();
  assert.equal(view.reader.state().page, 1);
  view.reader.goToPosition({ elementPath: [0], offset: 0 }, false);
  view.reader.configure({ marginX: 64 }); view.settle();
  assert.equal(view.reader.state().page, 0);
});
