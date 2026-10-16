import { File } from 'expo-file-system';
import { randomUUID } from 'expo-crypto';
import { forwardRef, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';
import { Linking, StyleSheet, useWindowDimensions, View } from 'react-native';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

import { bookRuntimeURL, ensureBookRuntimeInstalled } from './runtime';
import { injectChapterHead } from './chapterDocument';
import { highlightPayload, inlineStyle, cssVariables, runtimeOptions } from './settingsToCss';
import { chapterTitle as chapterTitleFor, spineIndexForPath } from '@/lib/epub/parse';
import { extensionOf, resolveHref, splitFragment } from '@/lib/epub/path';
import { directoryAt, directoryURL } from '@/lib/files';
import type { Palette } from '@/lib/theme';
import type { Annotation, BookRecord, Locator, Publication, ReaderSettings, TextPosition } from '@/lib/types';

export type ReaderSelection = {
  text: string;
  locator: Locator;
  rect: { x: number; y: number; width: number; height: number };
};

export type ReaderMeta = {
  spineIndex: number;
  page: number;
  pageCount: number;
  chapterTitle?: string;
  progress: number;
};

export type ReaderHandle = {
  nextPage(): void;
  previousPage(): void;
  nextChapter(): void;
  previousChapter(): void;
  goToLocator(locator: Locator): void;
  goToPath(path: string, fragment?: string): void;
  goToPage(page: number): void;
  clearSelection(): void;
};

type Props = {
  /** Without a book the reader idles on a blank page, which keeps WebKit warm. */
  book?: BookRecord;
  publication?: Publication;
  settings: ReaderSettings;
  palette: Palette;
  annotations: Annotation[];
  insets: { top: number; bottom: number };
  initialLocator?: Locator;
  onMeta: (meta: ReaderMeta, locator: Locator | null) => void;
  onSelection: (selection: ReaderSelection | null) => void;
  onHighlightTapped: (id: string, rect: ReaderSelection['rect']) => void;
  onTap: () => void;
  onLoadingChange: (loading: boolean) => void;
  onError: (message: string) => void;
};

type Target = { position?: TextPosition; fragment?: string; goToEnd?: boolean };

/** One of the two web views: the chapter on screen, or the next one preloading behind it. */
type Slot = {
  spineIndex: number;
  ready: boolean;
  /** Runtime options the chapter booted with, to detect settings changed while it loaded. */
  bootKey: string;
  /** Annotations array the chapter booted with, to detect highlights changed while it loaded. */
  annotations: Annotation[] | null;
  generation: number;
  documentToken: string;
};

type SlotIndex = 0 | 1;
type Source = { uri: string } | { html: string } | null;
const BLANK: Source = { html: '<!doctype html><html><head><title>Kodi</title></head><body></body></html>' };
const other = (slot: SlotIndex): SlotIndex => (slot === 0 ? 1 : 0);

/** Wait this long after a chapter appears before preloading the next one, so they never compete. */
const PRELOAD_DELAY_MS = 400;

// Flip on to log per-stage chapter load timings in development.
const DEBUG_TIMING = false;
let loadStartedAt = 0;
function mark(stage: string) {
  if (!__DEV__ || !DEBUG_TIMING) return;
  if (stage.startsWith('load')) loadStartedAt = Date.now();
  console.log(`[timing] ${stage} +${Date.now() - loadStartedAt}ms`);
}

/** JSON that is safe inside a <script> element of an XHTML document. */
function scriptJSON(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026');
}

/**
 * Hosts the book in WKWebViews running the Kodi reader runtime. All page-turn,
 * selection, and highlight logic lives in reader.js; this component relays
 * messages and decides which chapter loads where.
 *
 * Speed comes from three things:
 * - Each chapter file carries its own boot data (options, position,
 *   highlights), so it lays itself out without round trips to the JS thread.
 * - A second web view preloads the next chapter behind the visible one, so
 *   reading past a chapter end is an instant swap instead of a page load.
 * - Chapters always navigate to a fresh file name instead of reloading.
 */
export const ReaderWebView = forwardRef<ReaderHandle, Props>(function ReaderWebView(
  { book, publication, settings, palette, annotations, insets, initialLocator, onMeta, onSelection, onHighlightTapped, onTap, onLoadingChange, onError },
  ref,
) {
  const { width } = useWindowDimensions();
  const webViewRefs = [useRef<WebView>(null), useRef<WebView>(null)] as const;
  const [sources, setSources] = useState<[Source, Source]>([BLANK, null]);
  const [active, setActive] = useState<SlotIndex>(0);
  const [runtimeBookID, setRuntimeBookID] = useState<string | null>(null);
  const bookID = book?.id;
  const activeRef = useRef<SlotIndex>(0);
  const slotsRef = useRef<[Slot, Slot]>([
    { spineIndex: -1, ready: false, bootKey: '', annotations: null, generation: 0, documentToken: '' },
    { spineIndex: -1, ready: false, bootKey: '', annotations: null, generation: 0, documentToken: '' },
  ]);
  const preloadTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const configureTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const extractedDirectory = useMemo(() => directoryAt(book?.extractedRelativePath ?? ''), [book?.extractedRelativePath]);
  const readingOrder = useMemo(() => publication?.readingOrder ?? [], [publication]);
  const weights = useMemo(() => publication?.weights ?? [], [publication]);
  const readAccessURL = useMemo(() => directoryURL(extractedDirectory) + '/', [extractedDirectory]);
  const totalWeight = useMemo(() => weights.reduce((sum, weight) => sum + weight, 0), [weights]);

  const overallProgress = useCallback(
    (spineIndex: number, withinChapter: number) => {
      if (totalWeight <= 0) return 0;
      let before = 0;
      for (let i = 0; i < spineIndex; i += 1) before += weights[i] ?? 0;
      const current = weights[spineIndex] ?? 0;
      return Math.min(1, Math.max(0, (before + current * withinChapter) / totalWeight));
    },
    [weights, totalWeight],
  );

  const evaluateIn = useCallback(
    (slot: SlotIndex, script: string) => {
      webViewRefs[slot].current?.injectJavaScript(`${script}; true;`);
    },
    // The refs are stable for the component's lifetime.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );
  const evaluate = useCallback((script: string) => evaluateIn(activeRef.current, script), [evaluateIn]);

  const currentOptions = useCallback(() => runtimeOptions(settings, palette, width, insets), [settings, palette, width, insets]);

  const highlightsFor = useCallback(
    (spineIndex: number) => annotations.filter((annotation) => annotation.locator.spineIndex === spineIndex).map(highlightPayload),
    [annotations],
  );

  const pushHighlights = useCallback(
    (slot: SlotIndex) => {
      const state = slotsRef.current[slot];
      if (!state.ready) return;
      state.annotations = annotations;
      evaluateIn(slot, `window.__reader && __reader.setHighlights(${scriptJSON(highlightsFor(state.spineIndex))})`);
    },
    [annotations, evaluateIn, highlightsFor],
  );

  /**
   * Writes a copy of the chapter with the runtime and its boot data in <head>,
   * then points the slot's web view at it.
   */
  const writeAndLoad = useCallback(
    (slot: SlotIndex, index: number, target: Target) => {
      const path = readingOrder[index].path;
      const segments = path.split('/');
      const fileName = segments.pop() ?? path;
      let html = new File(extractedDirectory, ...segments, fileName).textSync();

      const options = currentOptions();
      const state = slotsRef.current[slot];
      state.spineIndex = index;
      state.ready = false;
      state.bootKey = JSON.stringify(options);
      state.annotations = annotations;
      state.generation += 1;

      const nonce = randomUUID();
      state.documentToken = nonce;
      const boot = { documentToken: nonce, options: { ...options, spineIndex: index }, target, highlights: highlightsFor(index) };
      const tags = [
        '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/>',
        `<style id="kodi-boot">${inlineStyle(cssVariables(settings, palette, width, insets))}</style>`,
        `<link rel="stylesheet" type="text/css" href="${bookRuntimeURL(extractedDirectory, 'reader.css')}"/>`,
        `<script nonce="${nonce}">window.__kodiBoot = ${scriptJSON(boot)};</script>`,
        `<script nonce="${nonce}" src="${bookRuntimeURL(extractedDirectory, 'reader.js')}"></script>`,
        `<script nonce="${nonce}" src="${bookRuntimeURL(extractedDirectory, 'bridge.js')}"></script>`,
      ].join('\n');

      html = injectChapterHead(html, tags, nonce);

      // Alternate between two names per slot so every load is a navigation to a
      // new URL. Reloading the same file URL is far slower in WKWebView.
      const extension = extensionOf(fileName) || 'xhtml';
      const stem = fileName.replace(/\.[^.]+$/, '');
      const injected = new File(extractedDirectory, ...segments, `${stem}.kodi-${slot}${state.generation % 2}.${extension}`);
      if (injected.exists) injected.delete();
      injected.write(html);

      setSources((current) => {
        const next: [Source, Source] = [...current];
        next[slot] = { uri: injected.uri };
        return next;
      });
    },
    [readingOrder, extractedDirectory, currentOptions, annotations, highlightsFor, settings, palette, width, insets],
  );

  const preloadNext = useCallback(() => {
    const visible = activeRef.current;
    const hidden = other(visible);
    const next = slotsRef.current[visible].spineIndex + 1;
    if (next <= 0 || next >= readingOrder.length) return;
    if (slotsRef.current[hidden].spineIndex === next) return;
    try {
      mark(`preload ${next}`);
      writeAndLoad(hidden, next, {});
    } catch {
      slotsRef.current[hidden].spineIndex = -1;
    }
  }, [readingOrder.length, writeAndLoad]);

  const schedulePreload = useCallback(() => {
    if (preloadTimer.current) clearTimeout(preloadTimer.current);
    preloadTimer.current = setTimeout(preloadNext, PRELOAD_DELAY_MS);
  }, [preloadNext]);

  /** Brings a chapter on screen in the visible web view. */
  const loadSpine = useCallback(
    (index: number, target: Target = {}) => {
      if (index < 0 || index >= readingOrder.length) return;
      mark(`load ${index}`);
      onSelection(null);
      onLoadingChange(true);
      try {
        writeAndLoad(activeRef.current, index, target);
      } catch (error) {
        onLoadingChange(false);
        onError(error instanceof Error ? error.message : String(error));
      }
    },
    [readingOrder.length, onSelection, onLoadingChange, writeAndLoad, onError],
  );

  /** Swaps the preloaded web view to the front, then reuses the old one for the next preload. */
  const promote = useCallback(
    (slot: SlotIndex, target: Target = {}) => {
      const previous = activeRef.current;
      activeRef.current = slot;
      setActive(slot);
      onSelection(null);
      evaluateIn(previous, 'window.__reader && __reader.clearSelection()');

      const state = slotsRef.current[slot];
      if (state.bootKey !== JSON.stringify(currentOptions())) {
        evaluateIn(slot, `__reader.configure(${scriptJSON(currentOptions())}, true)`);
        state.bootKey = JSON.stringify(currentOptions());
      }
      if (state.annotations !== annotations) pushHighlights(slot);
      if (target.goToEnd) evaluateIn(slot, '__reader.goToEnd()');
      else if (target.fragment) evaluateIn(slot, `__reader.goToFragment(${scriptJSON(target.fragment)}, false)`);
      else if (target.position?.elementPath.length) evaluateIn(slot, `__reader.goToPosition(${scriptJSON(target.position)}, false)`);
      // Reports the page so the chrome, progress, and saved position follow the swap.
      evaluateIn(slot, '__reader.notifyState()');
      onLoadingChange(false);
      mark(`promoted ${state.spineIndex}`);
      schedulePreload();
    },
    [onSelection, evaluateIn, currentOptions, annotations, pushHighlights, onLoadingChange, schedulePreload],
  );

  /** Shows a chapter, from the preloaded web view when it already holds it. */
  const showChapter = useCallback(
    (index: number, target: Target = {}) => {
      const hidden = other(activeRef.current);
      const preloaded = slotsRef.current[hidden];
      if (preloaded.spineIndex === index && preloaded.ready) promote(hidden, target);
      else loadSpine(index, target);
    },
    [promote, loadSpine],
  );

  // Install trusted scripts inside the book before restricting WebKit's read access.
  useEffect(() => {
    let cancelled = false;
    setRuntimeBookID(null);
    if (!bookID) return;
    onLoadingChange(true);
    ensureBookRuntimeInstalled(extractedDirectory).then(() => {
      if (!cancelled) setRuntimeBookID(bookID);
    }).catch((error) => {
      if (cancelled) return;
      onLoadingChange(false);
      onError(error instanceof Error ? error.message : String(error));
    });
    return () => { cancelled = true; };
  }, [bookID, extractedDirectory, onLoadingChange, onError]);

  // Each new book reuses the same web views: forget what they held, then load.
  useEffect(() => {
    if (preloadTimer.current) clearTimeout(preloadTimer.current);
    for (const state of slotsRef.current) {
      state.spineIndex = -1;
      state.ready = false;
      state.documentToken = '';
    }
    if (!book || runtimeBookID !== book.id || readingOrder.length === 0) return;
    const locator = initialLocator && initialLocator.kind !== 'pdf' ? initialLocator : undefined;
    const index = Math.min(Math.max(locator?.spineIndex ?? 0, 0), readingOrder.length - 1);
    loadSpine(index, { position: locator?.start.elementPath.length ? locator.start : undefined });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book?.id, publication, runtimeBookID]);

  useEffect(
    () => () => {
      if (preloadTimer.current) clearTimeout(preloadTimer.current);
      if (configureTimer.current) clearTimeout(configureTimer.current);
    },
    [],
  );

  // Settings or viewport changes reflow both chapters around their positions.
  const lastOptionsKey = useRef<string | null>(null);
  useEffect(() => {
    const key = JSON.stringify(currentOptions());
    if (lastOptionsKey.current === key) return;
    lastOptionsKey.current = key;
    if (configureTimer.current) clearTimeout(configureTimer.current);
    configureTimer.current = setTimeout(() => {
      const options = currentOptions();
      for (const slot of [0, 1] as const) {
        const state = slotsRef.current[slot];
        if (!state.ready) continue;
        state.bootKey = JSON.stringify(options);
        evaluateIn(slot, `window.__reader && __reader.configure(${scriptJSON(options)}, true)`);
      }
    }, 120);
  }, [currentOptions, evaluateIn]);

  useEffect(() => {
    pushHighlights(0);
    pushHighlights(1);
  }, [pushHighlights]);

  const reportMeta = useCallback(
    (page: number, pageCount: number, withinChapter: number, position: TextPosition | null) => {
      const spineIndex = slotsRef.current[activeRef.current].spineIndex;
      const progress = overallProgress(spineIndex, withinChapter);
      const locator: Locator | null = position ? { kind: 'epub', spineIndex, start: position, totalProgression: progress } : null;
      onMeta({ spineIndex, page, pageCount, chapterTitle: publication ? chapterTitleFor(publication, spineIndex) : undefined, progress }, locator);
    },
    [overallProgress, onMeta, publication],
  );

  const handleLink = useCallback(
    (href: string) => {
      const lower = href.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('mailto:') || lower.startsWith('tel:')) {
        Linking.openURL(href).catch(() => undefined);
        return;
      }
      if (!publication) return;
      const { path, fragment } = splitFragment(href);
      const current = slotsRef.current[activeRef.current].spineIndex;
      if (!path) {
        if (fragment) evaluate(`__reader.goToFragment(${scriptJSON(fragment)}, true)`);
        return;
      }
      const resolved = resolveHref(path, readingOrder[current]?.path ?? '');
      const index = spineIndexForPath(publication, resolved);
      if (index < 0) return;
      if (index === current) {
        if (fragment) evaluate(`__reader.goToFragment(${scriptJSON(fragment)}, true)`);
        return;
      }
      showChapter(index, { fragment });
    },
    [publication, readingOrder, evaluate, showChapter],
  );

  const handleMessage = useCallback(
    (slot: SlotIndex, event: WebViewMessageEvent) => {
      let body: Record<string, any>;
      try {
        body = JSON.parse(event.nativeEvent.data);
      } catch {
        return;
      }
      const state = slotsRef.current[slot];
      if (!state.documentToken || body.documentToken !== state.documentToken) return;
      const isActive = slot === activeRef.current;

      if (body.type === 'booted') {
        state.ready = true;
        mark(`booted ${state.spineIndex}${isActive ? '' : ' (preloaded)'}`);
        // Settings or highlights may have changed while this chapter was loading.
        if (state.bootKey !== JSON.stringify(currentOptions())) {
          state.bootKey = JSON.stringify(currentOptions());
          evaluateIn(slot, `__reader.configure(${scriptJSON(currentOptions())}, true)`);
        }
        if (state.annotations !== annotations) pushHighlights(slot);
        if (isActive) {
          onLoadingChange(false);
          schedulePreload();
        }
        return;
      }
      if (body.type === 'error') {
        onError(`${body.context ?? 'reader'}: ${body.message ?? 'unknown error'}`);
        return;
      }
      // Everything else is interaction with the visible chapter.
      if (!isActive) return;

      switch (body.type) {
        case 'pageChanged': {
          const position = body.position && Array.isArray(body.position.elementPath) ? (body.position as TextPosition) : null;
          onSelection(null);
          reportMeta(Number(body.page ?? 0), Math.max(1, Number(body.pageCount ?? 1)), Number(body.progression ?? 0), position);
          break;
        }
        case 'reachedEnd':
          if (state.spineIndex + 1 < readingOrder.length) showChapter(state.spineIndex + 1);
          break;
        case 'reachedStart':
          if (state.spineIndex > 0) showChapter(state.spineIndex - 1, { goToEnd: true });
          break;
        case 'selection': {
          const locatorBody = body.locator ?? {};
          const start = locatorBody.start as TextPosition | undefined;
          if (!start || typeof body.text !== 'string') break;
          onSelection({
            text: body.text,
            locator: { kind: 'epub', spineIndex: state.spineIndex, start, end: locatorBody.end, text: body.text },
            rect: body.rect ?? { x: 0, y: 0, width: 0, height: 0 },
          });
          break;
        }
        case 'selectionCleared':
          onSelection(null);
          break;
        case 'highlightTapped':
          if (typeof body.id === 'string') onHighlightTapped(body.id, body.rect ?? { x: 0, y: 0, width: 0, height: 0 });
          break;
        case 'tap':
          onTap();
          break;
        case 'link':
          if (typeof body.href === 'string') handleLink(body.href);
          break;
        default:
          break;
      }
    },
    [currentOptions, evaluateIn, annotations, pushHighlights, onLoadingChange, schedulePreload, onError, onSelection, reportMeta, readingOrder.length, showChapter, onHighlightTapped, onTap, handleLink],
  );

  const onMessage0 = useCallback((event: WebViewMessageEvent) => handleMessage(0, event), [handleMessage]);
  const onMessage1 = useCallback((event: WebViewMessageEvent) => handleMessage(1, event), [handleMessage]);

  useImperativeHandle(
    ref,
    () => ({
      nextPage: () => evaluate('if (window.__reader && !__reader.nextPage()) window.ReactNativeWebView.postMessage(JSON.stringify({ type: "reachedEnd", documentToken: window.__kodiBoot.documentToken }))'),
      previousPage: () => evaluate('if (window.__reader && !__reader.previousPage()) window.ReactNativeWebView.postMessage(JSON.stringify({ type: "reachedStart", documentToken: window.__kodiBoot.documentToken }))'),
      nextChapter: () => showChapter(slotsRef.current[activeRef.current].spineIndex + 1),
      previousChapter: () => showChapter(slotsRef.current[activeRef.current].spineIndex - 1),
      goToLocator: (locator) => {
        const state = slotsRef.current[activeRef.current];
        if (locator.spineIndex === state.spineIndex && state.ready) {
          evaluate(`__reader.goToPosition(${scriptJSON(locator.start)}, true)`);
        } else {
          showChapter(locator.spineIndex, { position: locator.start });
        }
      },
      goToPath: (path, fragment) => {
        if (!publication) return;
        const index = spineIndexForPath(publication, path);
        if (index < 0) return;
        const state = slotsRef.current[activeRef.current];
        if (index === state.spineIndex && state.ready) {
          if (fragment) evaluate(`__reader.goToFragment(${scriptJSON(fragment)}, true)`);
          else evaluate('__reader.goToPage(0, true)');
        } else {
          showChapter(index, { fragment });
        }
      },
      goToPage: (page) => evaluate(`__reader.goToPage(${Math.round(page)}, false)`),
      clearSelection: () => evaluate('window.__reader && __reader.clearSelection()'),
    }),
    [evaluate, showChapter, publication],
  );

  const renderSlot = (slot: SlotIndex) => {
    const source = sources[slot];
    if (!source) return null;
    const visible = slot === active;
    return (
      <View
        key={slot}
        style={[StyleSheet.absoluteFill, { zIndex: visible ? 1 : 0, backgroundColor: palette.page }]}
        pointerEvents={visible ? 'auto' : 'none'}
        accessibilityElementsHidden={!visible}
        importantForAccessibility={visible ? 'auto' : 'no-hide-descendants'}>
        <WebView
          ref={webViewRefs[slot]}
          source={source}
          // Only local book files load in place. Anything else is handed to the
          // OS by the WebView itself, with no per-navigation round trip to JS.
          originWhitelist={['file://*', 'about:*']}
          allowingReadAccessToURL={readAccessURL}
          allowFileAccess
          onMessage={slot === 0 ? onMessage0 : onMessage1}
          scrollEnabled={false}
          bounces={false}
          overScrollMode="never"
          contentInsetAdjustmentBehavior="never"
          automaticallyAdjustContentInsets={false}
          allowsLinkPreview={false}
          dataDetectorTypes="none"
          menuItems={[]}
          suppressMenuItems={['cut', 'copy', 'paste', 'replace', 'bold', 'italic', 'underline', 'select', 'selectAll', 'translate', 'lookup', 'share']}
          hideKeyboardAccessoryView
          webviewDebuggingEnabled={__DEV__}
          style={[styles.webView, { backgroundColor: palette.page }]}
          containerStyle={{ backgroundColor: palette.page }}
          onError={(event) => onError(event.nativeEvent.description)}
        />
      </View>
    );
  };

  return (
    <View style={[styles.container, { backgroundColor: palette.page }]}>
      {renderSlot(0)}
      {renderSlot(1)}
    </View>
  );
});

const styles = StyleSheet.create({
  // The slots order themselves with zIndex; isolation keeps that ordering inside
  // this component instead of lifting a web view above the reader chrome.
  container: { flex: 1, isolation: 'isolate' },
  webView: { flex: 1, opacity: 0.99 },
});
