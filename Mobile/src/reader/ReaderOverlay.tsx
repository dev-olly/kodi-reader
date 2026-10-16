import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';
import { useRouter } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Alert, BackHandler, Pressable, StyleSheet, useWindowDimensions, View } from 'react-native';
import Animated, { Easing, FadeIn, FadeInDown, FadeInUp, FadeOut, useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { WebView } from 'react-native-webview';

import { closeReader, useReaderRequest } from './openReader';
import { ReaderWebView, type ReaderHandle, type ReaderMeta, type ReaderSelection } from './ReaderWebView';
import { setReaderSession, updateReaderSession } from './session';
import { GlassGroup, GlassSurface } from '@/components/GlassSurface';
import { HighlightPalette } from '@/components/HighlightPalette';
import { Typography } from '@/components/Typography';
import { usePalette } from '@/hooks/use-palette';
import { loadPublication } from '@/lib/epub/book';
import { fileAt } from '@/lib/files';
import { addAnnotation, deleteAnnotation, makeID, savePosition, touchBook, updateAnnotation, useBook, useSettings } from '@/lib/store';
import { Fonts, Spacing } from '@/lib/theme';
import type { Annotation, HighlightColor, Locator, Publication } from '@/lib/types';

const PALETTE_WIDTH = 330;
const PALETTE_WIDTH_WITH_DELETE = 372;
const PALETTE_HEIGHT = 46;
const SLIDE_MS = 280;

function ChromeButton({ icon, label, onPress, color, size = 44 }: { icon: string; label: string; onPress: () => void; color: string; size?: number }) {
  return (
    <GlassSurface interactive style={{ width: size, height: size, borderRadius: size / 2 }}>
      <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={label} style={styles.buttonHit} hitSlop={6}>
        <SymbolView name={icon as never} size={19} tintColor={color} weight="medium" />
      </Pressable>
    </GlassSurface>
  );
}

/**
 * The reader, as a layer above the navigation stack. It stays mounted for the
 * whole app session so its web views never have to cold-start: opening a book
 * slides this layer up and navigates the already-running web view.
 */
export function ReaderOverlay() {
  const router = useRouter();
  const request = useReaderRequest();
  const book = useBook(request.bookID ?? undefined);
  const settings = useSettings();
  const palette = usePalette();
  const insets = useSafeAreaInsets();
  // Stable identity: a fresh object every render would re-run the reader's configure effect.
  const readerInsets = useMemo(() => ({ top: insets.top, bottom: insets.bottom }), [insets.top, insets.bottom]);
  const { width, height } = useWindowDimensions();
  const readerRef = useRef<ReaderHandle>(null);

  const visible = request.visible && Boolean(book);
  const [chromeVisible, setChromeVisible] = useState(true);
  const [loading, setLoading] = useState(false);
  const [meta, setMeta] = useState<ReaderMeta | null>(null);
  const [selection, setSelection] = useState<ReaderSelection | null>(null);
  const [activeHighlight, setActiveHighlight] = useState<{ id: string; rect: ReaderSelection['rect'] } | null>(null);

  // Each open starts with fresh chrome and no stale selection; a different book also drops the old page info.
  const [seen, setSeen] = useState({ nonce: request.nonce, bookID: request.bookID });
  if (seen.nonce !== request.nonce) {
    setSeen({ nonce: request.nonce, bookID: request.bookID });
    setChromeVisible(true);
    setSelection(null);
    setActiveHighlight(null);
    if (seen.bookID !== request.bookID) setMeta(null);
  }

  const { publication, publicationError } = useMemo<{ publication: Publication | null; publicationError: string | null }>(() => {
    if (!book || book.kind !== 'epub') return { publication: null, publicationError: null };
    try {
      return { publication: loadPublication(book), publicationError: null };
    } catch (error) {
      return { publication: null, publicationError: error instanceof Error ? error.message : String(error) };
    }
  }, [book]);

  // Where a newly loaded book opens: the requested highlight, else the saved position.
  const initialLocator = useMemo<Locator | undefined>(() => {
    if (!book) return undefined;
    const target = request.annotationID ? book.annotations.find((item) => item.id === request.annotationID) : undefined;
    return target?.locator ?? book.position;
    // Only a new book decides where to open; later position saves must not re-run this.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book?.id]);

  // Slide in and out. The layer stays mounted; only its position changes.
  const offset = useSharedValue(height);
  useEffect(() => {
    offset.value = withTiming(visible ? 0 : height, { duration: SLIDE_MS, easing: visible ? Easing.out(Easing.cubic) : Easing.in(Easing.cubic) });
  }, [visible, height, offset]);
  const slideStyle = useAnimatedStyle(() => ({ transform: [{ translateY: offset.value }] }));

  // Each open marks the book recent; reopening the loaded book jumps to a requested highlight.
  const loadedBookRef = useRef<string | null>(null);
  useEffect(() => {
    if (!request.visible || !request.bookID) return;
    touchBook(request.bookID);
    const sameBook = loadedBookRef.current === request.bookID;
    loadedBookRef.current = request.bookID;
    if (!sameBook) return;
    const target = request.annotationID ? book?.annotations.find((item) => item.id === request.annotationID) : undefined;
    if (target) readerRef.current?.goToLocator(target.locator);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [request.nonce]);

  // A deleted book closes the reader.
  useEffect(() => {
    if (request.visible && request.bookID && !book) closeReader();
  }, [request.visible, request.bookID, book]);

  useEffect(() => {
    if (!visible) return;
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      closeReader();
      return true;
    });
    return () => subscription.remove();
  }, [visible]);

  // Expose navigation to the contents sheet while a book is on screen.
  useEffect(() => {
    if (!visible || !book) return;
    setReaderSession({
      bookID: book.id,
      publication,
      spineIndex: meta?.spineIndex ?? initialLocator?.spineIndex ?? 0,
      chapterTitle: meta?.chapterTitle,
      goToTOC: (path, fragment) => readerRef.current?.goToPath(path, fragment),
      goToLocator: (locator) => readerRef.current?.goToLocator(locator),
      nextChapter: () => readerRef.current?.nextChapter(),
      previousChapter: () => readerRef.current?.previousChapter(),
    });
    return () => setReaderSession(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible, book?.id, publication]);

  const onMeta = useCallback((next: ReaderMeta, locator: Locator | null) => {
    setMeta(next);
    setActiveHighlight(null);
    updateReaderSession({ spineIndex: next.spineIndex, chapterTitle: next.chapterTitle });
    const bookID = loadedBookRef.current;
    if (locator && bookID) savePosition(bookID, locator, next.progress);
  }, []);

  const onSelection = useCallback((next: ReaderSelection | null) => {
    setSelection(next);
    if (next) setActiveHighlight(null);
  }, []);

  const onHighlightTapped = useCallback((highlightID: string, rect: ReaderSelection['rect']) => {
    Haptics.selectionAsync().catch(() => undefined);
    setSelection(null);
    setActiveHighlight({ id: highlightID, rect });
  }, []);

  const onTap = useCallback(() => {
    if (selection || activeHighlight) {
      readerRef.current?.clearSelection();
      setSelection(null);
      setActiveHighlight(null);
      return;
    }
    setChromeVisible((shown) => !shown);
  }, [selection, activeHighlight]);

  const onError = useCallback((message: string) => {
    console.warn('[reader]', message);
  }, []);

  const addHighlight = useCallback(
    (color: HighlightColor, withNote: boolean) => {
      if (!book || !selection) return;
      const now = new Date().toISOString();
      const annotation: Annotation = {
        id: makeID(),
        locator: selection.locator,
        text: selection.text,
        color,
        chapterTitle: meta?.chapterTitle,
        createdAt: now,
        modifiedAt: now,
      };
      addAnnotation(book.id, annotation);
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => undefined);
      readerRef.current?.clearSelection();
      setSelection(null);
      if (withNote) {
        router.push({ pathname: '/note/[bookId]/[annotationId]', params: { bookId: book.id, annotationId: annotation.id, autofocus: '1' } });
      }
    },
    [book, selection, meta?.chapterTitle, router],
  );

  const copyText = useCallback(async (text: string) => {
    await Clipboard.setStringAsync(text);
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined);
  }, []);

  const activeAnnotation = activeHighlight ? book?.annotations.find((item) => item.id === activeHighlight.id) : undefined;

  const palettePosition = useCallback(
    (rect: ReaderSelection['rect'], paletteWidth = PALETTE_WIDTH) => {
      const left = Math.min(Math.max(12, rect.x + rect.width / 2 - paletteWidth / 2), width - paletteWidth - 12);
      const below = rect.y + rect.height + 12;
      const top = below + PALETTE_HEIGHT < height - insets.bottom - 20 ? below : Math.max(insets.top + 12, rect.y - PALETTE_HEIGHT - 12);
      return { left, top, width: paletteWidth };
    },
    [width, height, insets.top, insets.bottom],
  );

  const percent = Math.round((meta?.progress ?? book?.progress ?? 0) * 100);
  const chromeColor = palette.ink;
  const showUI = visible && book;

  return (
    <Animated.View
      style={[StyleSheet.absoluteFill, styles.layer, { backgroundColor: palette.page }, slideStyle]}
      pointerEvents={visible ? 'auto' : 'none'}
      accessibilityElementsHidden={!visible}
      importantForAccessibility={visible ? 'auto' : 'no-hide-descendants'}
      accessibilityViewIsModal={visible}>
      <ReaderWebView
        ref={readerRef}
        book={book?.kind === 'epub' ? book : undefined}
        publication={publication ?? undefined}
        settings={settings}
        palette={palette}
        annotations={book?.annotations ?? EMPTY}
        insets={readerInsets}
        initialLocator={initialLocator}
        onMeta={onMeta}
        onSelection={onSelection}
        onHighlightTapped={onHighlightTapped}
        onTap={onTap}
        onLoadingChange={setLoading}
        onError={onError}
      />

      {showUI && book.kind === 'pdf' ? (
        <WebView
          source={{ uri: fileAt(book.importedRelativePath).uri }}
          allowingReadAccessToURL={fileAt(book.importedRelativePath).uri}
          allowFileAccess
          originWhitelist={['*']}
          style={[StyleSheet.absoluteFill, { backgroundColor: palette.page }]}
          containerStyle={StyleSheet.absoluteFill}
          contentInsetAdjustmentBehavior="never"
          onError={(event) => Alert.alert('Could not open', event.nativeEvent.description)}
        />
      ) : null}

      {showUI && book.kind === 'epub' && !publication ? (
        <View style={[StyleSheet.absoluteFill, styles.center, { backgroundColor: palette.page }]}>
          <Typography variant="body" tone="muted" style={styles.errorText}>
            {publicationError ?? 'This document could not be opened.'}
          </Typography>
        </View>
      ) : null}

      {/* Top chrome */}
      {showUI && chromeVisible ? (
        <Animated.View entering={FadeInDown.duration(180)} exiting={FadeOut.duration(140)} style={[styles.topBar, { top: insets.top + 8 }]} pointerEvents="box-none">
          <ChromeButton icon="chevron.left" label="Back to Library" color={chromeColor} onPress={closeReader} />
          <GlassSurface style={styles.titlePill}>
            <Typography variant="caption" numberOfLines={1} style={[styles.titleText, { color: chromeColor }]}>
              {book.title}
            </Typography>
            {meta?.chapterTitle && meta.chapterTitle.trim() !== book.title.trim() ? (
              <Typography variant="caption" tone="muted" numberOfLines={1} style={styles.chapterText}>
                {meta.chapterTitle}
              </Typography>
            ) : null}
          </GlassSurface>
          {book.kind === 'epub' ? (
            <GlassGroup style={styles.buttonGroup} spacing={10}>
              <ChromeButton icon="list.bullet" label="Contents" color={chromeColor} onPress={() => router.push('/reader/contents')} />
              <ChromeButton icon="textformat.size" label="Appearance" color={chromeColor} onPress={() => router.push('/reader/typography')} />
            </GlassGroup>
          ) : null}
        </Animated.View>
      ) : null}

      {/* Bottom chrome */}
      {showUI && chromeVisible && book.kind === 'epub' ? (
        <Animated.View entering={FadeInUp.duration(180)} exiting={FadeOut.duration(140)} style={[styles.bottomBar, { bottom: insets.bottom + 10 }]} pointerEvents="box-none">
          <GlassSurface style={styles.progressPill}>
            <View style={styles.progressRow}>
              <Pressable onPress={() => readerRef.current?.previousPage()} accessibilityLabel="Previous page" hitSlop={8} style={styles.pageButton}>
                <SymbolView name="chevron.left" size={16} tintColor={chromeColor} weight="semibold" />
              </Pressable>
              <View style={styles.progressCenter}>
                <View style={[styles.track, { backgroundColor: palette.border }]}>
                  <View style={[styles.trackFill, { backgroundColor: palette.accent, width: `${percent}%` }]} />
                </View>
                <Typography variant="caption" tone="muted" numberOfLines={1} style={styles.progressText}>
                  {meta ? `Page ${meta.page + 1} of ${meta.pageCount}` : 'Opening…'}
                  {'  ·  '}
                  {percent}%
                </Typography>
              </View>
              <Pressable onPress={() => readerRef.current?.nextPage()} accessibilityLabel="Next page" hitSlop={8} style={styles.pageButton}>
                <SymbolView name="chevron.right" size={16} tintColor={chromeColor} weight="semibold" />
              </Pressable>
            </View>
          </GlassSurface>
        </Animated.View>
      ) : null}

      {/* Selection palette */}
      {showUI && selection ? (
        <Animated.View entering={FadeIn.duration(120)} exiting={FadeOut.duration(100)} style={[styles.palette, palettePosition(selection.rect)]}>
          <HighlightPalette
            onPick={(color) => addHighlight(color, false)}
            onNote={() => addHighlight('yellow', true)}
            onCopy={() => {
              copyText(selection.text).catch(() => undefined);
              readerRef.current?.clearSelection();
            }}
          />
        </Animated.View>
      ) : null}

      {showUI && activeHighlight && activeAnnotation ? (
        <Animated.View entering={FadeIn.duration(120)} exiting={FadeOut.duration(100)} style={[styles.palette, palettePosition(activeHighlight.rect, PALETTE_WIDTH_WITH_DELETE)]}>
          <HighlightPalette
            currentColor={activeAnnotation.color}
            hasNote={Boolean(activeAnnotation.note?.trim())}
            onPick={(color) => {
              updateAnnotation(book.id, activeAnnotation.id, { color });
              setActiveHighlight(null);
            }}
            onNote={() => {
              setActiveHighlight(null);
              router.push({ pathname: '/note/[bookId]/[annotationId]', params: { bookId: book.id, annotationId: activeAnnotation.id, autofocus: activeAnnotation.note ? '0' : '1' } });
            }}
            onCopy={() => {
              copyText(activeAnnotation.text).catch(() => undefined);
              setActiveHighlight(null);
            }}
            onDelete={() => {
              deleteAnnotation(book.id, activeAnnotation.id);
              setActiveHighlight(null);
            }}
          />
        </Animated.View>
      ) : null}

      {showUI && loading ? (
        <View style={styles.loading} pointerEvents="none">
          <GlassSurface style={styles.loadingPill}>
            <ActivityIndicator color={palette.accent} />
          </GlassSurface>
        </View>
      ) : null}
    </Animated.View>
  );
}

const EMPTY: Annotation[] = [];

const styles = StyleSheet.create({
  layer: { zIndex: 10 },
  center: { alignItems: 'center', justifyContent: 'center', gap: Spacing.md, padding: Spacing.lg },
  errorText: { textAlign: 'center' },
  topBar: {
    position: 'absolute',
    left: Spacing.md,
    right: Spacing.md,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  buttonHit: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  titlePill: { flex: 1, borderRadius: 22, paddingHorizontal: 14, paddingVertical: 6, minHeight: 44, justifyContent: 'center' },
  titleText: { fontWeight: '600', fontSize: 13 },
  chapterText: { fontSize: 12, lineHeight: 15 },
  buttonGroup: { flexDirection: 'row', gap: 8 },
  bottomBar: { position: 'absolute', left: Spacing.md, right: Spacing.md, alignItems: 'center' },
  progressPill: { borderRadius: 26, paddingHorizontal: 10, paddingVertical: 6, width: '100%' },
  progressRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  pageButton: { width: 36, height: 36, alignItems: 'center', justifyContent: 'center' },
  progressCenter: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 6 },
  track: { width: '100%', height: 3, borderRadius: 2, overflow: 'hidden', marginBottom: 6 },
  trackFill: { height: 3, borderRadius: 2 },
  progressText: { fontFamily: Fonts.mono, fontSize: 11, lineHeight: 14, fontVariant: ['tabular-nums'] },
  palette: { position: 'absolute' },
  loading: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, alignItems: 'center', justifyContent: 'center' },
  loadingPill: { width: 56, height: 56, borderRadius: 28, alignItems: 'center', justifyContent: 'center' },
});
