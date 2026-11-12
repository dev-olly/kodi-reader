import * as pdfjs from '../vendor/pdfjs/pdf.mjs';
import { normalizePoint as normalize, pdfPoint as denormalize, quadForRect, boundsForQuad } from './geometry.js';

pdfjs.GlobalWorkerOptions.workerSrc = new URL('../vendor/pdfjs/pdf.worker.mjs', import.meta.url).href;
const boot = window.__KODI_BOOT__ || {};
const pages = document.getElementById('pages');
const message = document.getElementById('message');
let pdf;
let pageIndex = Number(boot.spineIndex ?? boot.position?.spineIndex ?? 0);
let settings = boot.settings || {};
let annotations = boot.annotations || [];
let reminders = boot.reminders || [];
let readingMarker = boot.readingMarker || null;
let placingMarker = false;
let renderEpoch = 0;
let renderedPages = [];
let renderTasks = [];
let selectionTimer;

function post(payload) {
  const event = { ...payload, documentID: boot.documentId };
  try {
    if (typeof window.__KODI_POST__ === 'function') window.__KODI_POST__(event);
    else window.__TAURI_INTERNALS__?.invoke('reader_event', { sessionId: boot.sessionId, documentId: boot.documentId, message: event }).catch(() => {});
  } catch { /* A detached view cannot report into a newer session. */ }
}
window.__kodiPost = post;
window.__kodiRefresh = function (next) {
  if (next.annotations) annotations = next.annotations;
  if (next.reminders) reminders = next.reminders;
  if ('readingMarker' in next) readingMarker = next.readingMarker;
  if (next.settings) settings = { ...settings, ...next.settings };
  paintAnnotations();
};

function reportPosition() {
  post({ type: 'pageChanged', spineIndex: pageIndex, page: pageIndex, pageCount: pdf.numPages,
    progression: pdf.numPages > 1 ? pageIndex / (pdf.numPages - 1) : 0,
    position: { elementPath: [], offset: 0 } });
}

function normalizePoint(point, page) {
  return normalize(point, page.view);
}

function pdfPoint(normalized, page) {
  return denormalize(normalized, page.view);
}

function rectToQuad(rect, rendered) {
  const box = rendered.element.getBoundingClientRect();
  return quadForRect(rect, box, rendered.viewport, rendered.page.view);
}

function selectedPageQuote(range, container) {
  const clipped = range.cloneRange();
  if (!container.contains(clipped.startContainer)) clipped.setStart(container, 0);
  if (!container.contains(clipped.endContainer)) clipped.setEnd(container, container.childNodes.length);
  return clipped.toString().trim();
}

function reportSelection() {
  const selected = window.getSelection();
  if (!selected || selected.isCollapsed || !selected.rangeCount || !selected.toString().trim()) { post({ type: 'selectionCleared' }); return; }
  const range = selected.getRangeAt(0);
  const anchors = [];
  for (const rendered of renderedPages) {
    if (!range.intersectsNode(rendered.textLayer)) continue;
    const box = rendered.element.getBoundingClientRect();
    const rects = [...range.getClientRects()].filter(rect => rect.width > 0 && rect.height > 0 && rect.right > box.left && rect.left < box.right && rect.bottom > box.top && rect.top < box.bottom);
    const quads = rects.map(rect => rectToQuad(rect, rendered)).filter(Boolean);
    if (quads.length) anchors.push({ pageIndex: rendered.index, quads, text: selectedPageQuote(range, rendered.textLayer), prefix: '', suffix: '' });
  }
  if (!anchors.length) return;
  const rect = range.getBoundingClientRect();
  const text = selected.toString().trim();
  post({ type: 'selection', spineIndex: anchors[0].pageIndex, text,
    locator: { kind: 'pdf', spineIndex: anchors[0].pageIndex, start: { elementPath: [], offset: 0 }, end: { elementPath: [], offset: 0 }, text, pdfAnchors: anchors },
    rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } });
}

function anchorRects(anchor, rendered) {
  return (anchor.quads || []).map(quad => boundsForQuad(quad, rendered.viewport, rendered.page.view)).filter(Boolean);
}

function positionElement(element, rect) { Object.assign(element.style, { left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` }); }

function paintAnnotations() {
  for (const rendered of renderedPages) {
    const layer = rendered.highlightLayer; layer.replaceChildren();
    for (const annotation of annotations) {
      const anchors = annotation.locator?.pdfAnchors || annotation.pdfAnchors || [];
      for (const anchor of Array.isArray(anchors) ? anchors : []) {
        if (anchor.pageIndex !== rendered.index) continue;
        for (const rect of anchorRects(anchor, rendered)) {
          const mark = document.createElement('button'); mark.className = `pdf-highlight${annotation.style === 'underline' || annotation.color === 'underline' ? ' underline' : ''}`;
          const colors = { yellow: '#efd279', green: '#b3d2b2', blue: '#afcce5', pink: '#eab7c5', purple: '#c9b8dc' };
          mark.style.setProperty('--highlight', colors[annotation.color] || (/^#[0-9a-f]{3,8}$/i.test(annotation.color) ? annotation.color : '#efd279'));
          mark.setAttribute('aria-label', annotation.text ? `Open note: ${annotation.text}` : 'Open note'); positionElement(mark, rect);
          mark.addEventListener('click', () => post({ type: 'highlightTapped', id: annotation.id, spineIndex: rendered.index })); layer.append(mark);
        }
      }
    }
    for (const reminder of reminders) {
      const anchors = reminder.locator?.pdfAnchors || [];
      const anchor = Array.isArray(anchors) ? anchors.find(value => value.pageIndex === rendered.index) : null;
      const rect = anchor ? anchorRects(anchor, rendered)[0] : null;
      if (!rect) continue;
      const marker = document.createElement('button'); marker.className = 'pdf-reminder'; marker.textContent = '?'; marker.setAttribute('aria-label', 'Research reminder');
      marker.style.left = `${Math.max(0, rect.left - 23)}px`; marker.style.top = `${rect.top}px`;
      marker.addEventListener('click', () => post({ type: 'reminderTapped', id: reminder.id, spineIndex: rendered.index })); layer.append(marker);
    }
    if (readingMarker?.spineIndex === rendered.index) {
      const marker = document.createElement('div'); marker.className = 'pdf-marker';
      const point = readingMarker.pdfPoint || { x: 0.02, y: 0.03 };
      const converted = rendered.viewport.convertToViewportPoint(...pdfPoint([point.x, point.y], rendered.page));
      marker.style.left = `${converted[0]}px`; marker.style.top = `${converted[1]}px`; layer.append(marker);
    }
  }
}

async function render() {
  if (!pdf) return;
  const epoch = ++renderEpoch;
  renderTasks.forEach(task => task.cancel()); renderTasks = [];
  const previousNodes = [...pages.children];
  const spread = settings.twoPageSpread !== false && window.innerWidth >= 1100;
  const indexes = spread && pageIndex + 1 < pdf.numPages ? [pageIndex, pageIndex + 1] : [pageIndex];
  const pageObjects = await Promise.all(indexes.map(index => pdf.getPage(index + 1)));
  if (epoch !== renderEpoch) return;
  const fragment = document.createDocumentFragment(); const nextRendered = [];
  for (let i = 0; i < pageObjects.length; i++) {
    const page = pageObjects[i]; const baseViewport = page.getViewport({ scale: 1 });
    const availableWidth = (window.innerWidth - 48 - (indexes.length - 1) * 20) / indexes.length;
    const scale = Number.isFinite(settings.zoom) ? Math.min(4, Math.max(.25, settings.zoom)) : Math.max(.15, Math.min((window.innerHeight - 48) / baseViewport.height, availableWidth / baseViewport.width));
    const viewport = page.getViewport({ scale });
    const element = document.createElement('section'); element.className = 'pdf-page'; element.setAttribute('aria-label', `Page ${indexes[i] + 1}`); element.dataset.page = indexes[i];
    element.style.width = `${viewport.width}px`; element.style.height = `${viewport.height}px`; element.style.setProperty('--scale-factor', scale); element.style.setProperty('--user-unit', page.userUnit || 1); element.style.setProperty('--total-scale-factor', scale);
    const canvas = document.createElement('canvas'); const pixelRatio = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.floor(viewport.width * pixelRatio); canvas.height = Math.floor(viewport.height * pixelRatio); element.append(canvas);
    const textLayer = document.createElement('div'); textLayer.className = 'textLayer'; element.append(textLayer);
    const highlightLayer = document.createElement('div'); highlightLayer.className = 'highlight-layer'; element.append(highlightLayer);
    const task = page.render({ canvasContext: canvas.getContext('2d'), canvas, viewport, transform: pixelRatio !== 1 ? [pixelRatio, 0, 0, pixelRatio, 0, 0] : undefined }); renderTasks.push(task);
    task.promise.catch(error => { if (error.name !== 'RenderingCancelledException' && epoch === renderEpoch) post({ type: 'error', message: error.message }); });
    const text = await page.getTextContent(); if (epoch !== renderEpoch) return;
    await new pdfjs.TextLayer({ textContentSource: text, container: textLayer, viewport }).render(); if (epoch !== renderEpoch) return;
    element.addEventListener('click', event => {
      if (!placingMarker) return;
      const box = element.getBoundingClientRect();
      const [x, y] = normalizePoint(viewport.convertToPdfPoint(event.clientX - box.left, event.clientY - box.top), page);
      readingMarker = { kind: 'pdf', spineIndex: indexes[i], start: { elementPath: [], offset: 0 }, pdfPoint: { x, y } };
      setReadingMarkerPlacement(false); paintAnnotations();
      post({ type: 'readingMarkerPlaced', spineIndex: indexes[i], start: readingMarker.start, locator: readingMarker });
    });
    nextRendered.push({ index: indexes[i], page, viewport, element, textLayer, highlightLayer }); fragment.append(element);
  }
  if (epoch !== renderEpoch) return;
  previousNodes.forEach(node => node.remove()); pages.append(fragment); renderedPages = nextRendered;
  const contentWidth = nextRendered.reduce((sum, value) => sum + value.viewport.width, 0) + 48 + (nextRendered.length - 1) * 20;
  pages.style.justifyContent = contentWidth > window.innerWidth ? 'flex-start' : 'center';
  pages.style.alignItems = nextRendered.some(value => value.viewport.height + 48 > window.innerHeight) ? 'flex-start' : 'center';
  paintAnnotations(); reportPosition(); message.textContent = '';
}

function goToPage(index) { if (!pdf) return false; const target = Math.max(0, Math.min(pdf.numPages - 1, Number(index))); if (!Number.isFinite(target)) return false; pageIndex = target; void render().catch(fail); return true; }
function nextPage() { if (!pdf || pageIndex >= pdf.numPages - 1) return false; return goToPage(pageIndex + (settings.twoPageSpread !== false && window.innerWidth >= 1100 ? 2 : 1)); }
function previousPage() { if (!pdf || pageIndex === 0) return false; return goToPage(pageIndex - (settings.twoPageSpread !== false && window.innerWidth >= 1100 ? 2 : 1)); }
function setReadingMarkerPlacement(value) { placingMarker = Boolean(value); document.body.classList.toggle('placing-marker', placingMarker); }
function fail(error) { message.textContent = `This PDF could not be opened. ${error?.message || error}`; post({ type: 'error', message: message.textContent }); }

window.__reader = {
  nextPage, previousPage, goToPage,
  goToPosition(locator) { return goToPage(locator?.spineIndex ?? pageIndex); },
  configure(next) { settings = { ...settings, ...next }; const variables = next?.variables || {}; if (variables['--color-background']) document.documentElement.style.setProperty('--paper', variables['--color-background']); void render().catch(fail); },
  setHighlights(values) { annotations = values || []; paintAnnotations(); },
  setReminders(values) { reminders = values || []; paintAnnotations(); },
  setReadingMarker(value) { readingMarker = value; paintAnnotations(); },
  setReadingMarkerPlacement,
  clearSelection() { window.getSelection()?.removeAllRanges(); post({ type: 'selectionCleared' }); },
  notifyState() { if (pdf) reportPosition(); },
  goToFragment() { return false; },
  narrationPassages() { return '[]'; },
};

document.addEventListener('selectionchange', () => { clearTimeout(selectionTimer); selectionTimer = setTimeout(reportSelection, 160); });
document.addEventListener('keydown', event => {
  if (event.key === 'ArrowRight' || event.key === 'PageDown') { event.preventDefault(); if (!nextPage()) post({ type: 'reachedEnd' }); }
  if (event.key === 'ArrowLeft' || event.key === 'PageUp') { event.preventDefault(); if (!previousPage()) post({ type: 'reachedStart' }); }
  if (event.key === 'Escape') setReadingMarkerPlacement(false);
  if (event.key.toLowerCase() === 'm' && !event.ctrlKey && !event.metaKey) {
    if (event.shiftKey && readingMarker) goToPage(readingMarker.spineIndex); else setReadingMarkerPlacement(true);
  }
});
new ResizeObserver(() => { void render().catch(fail); }).observe(document.body);
try {
  if (!boot.pdfUrl) throw new Error('The reader did not receive a document resource.');
  pdf = await pdfjs.getDocument({ url: boot.pdfUrl, isEvalSupported: false, enableXfa: false, disableRange: true,
    cMapUrl: new URL('../vendor/pdfjs/cmaps/', import.meta.url).href, cMapPacked: true,
    standardFontDataUrl: new URL('../vendor/pdfjs/standard_fonts/', import.meta.url).href,
    wasmUrl: new URL('../vendor/pdfjs/wasm/', import.meta.url).href }).promise;
  pageIndex = Math.max(0, Math.min(pdf.numPages - 1, pageIndex)); await render();
  post({ type: 'ready', spineIndex: pageIndex, pageCount: pdf.numPages });
} catch (error) { fail(error); }
