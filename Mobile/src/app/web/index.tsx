import * as Haptics from 'expo-haptics';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { useCallback, useRef, useState } from 'react';
import { ActivityIndicator, Alert, Keyboard, Pressable, StyleSheet, TextInput, View } from 'react-native';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

import { GlassSurface } from '@/components/GlassSurface';
import { Typography } from '@/components/Typography';
import { usePalette } from '@/hooks/use-palette';
import { importDocument } from '@/lib/epub/import';
import { getState, upsertBook } from '@/lib/store';
import { Fonts, Spacing } from '@/lib/theme';
import { buildArticleEPUB, normalizedWebURL, type ArticleContent } from '@/lib/web/article';
import { openReader } from '@/reader/openReader';
import { runtimeText } from '@/reader/runtime';

const START_PAGE = 'https://www.gutenberg.org/';

type ExtractMessage =
  | { type: 'article'; payload: { error?: string; title?: string; byline?: string; content?: string; lang?: string } }
  | { type: string };

/**
 * In-app browser. Load any page, then save it as a reader-mode book: the
 * Mac app's Readability extraction runs inside the page and the result is
 * packaged as a single-chapter EPUB.
 */
export default function WebScreen() {
  const palette = usePalette();
  const router = useRouter();
  const { url: initialURL } = useLocalSearchParams<{ url?: string }>();
  const webViewRef = useRef<WebView>(null);
  const [address, setAddress] = useState(initialURL ?? '');
  const [currentURL, setCurrentURL] = useState<string>(initialURL ?? START_PAGE);
  const [pageTitle, setPageTitle] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [canGoBack, setCanGoBack] = useState(false);
  const [canGoForward, setCanGoForward] = useState(false);
  const pendingSave = useRef<((article: ArticleContent) => void) | null>(null);

  const submit = useCallback(() => {
    const normalized = normalizedWebURL(address);
    if (!normalized) {
      Alert.alert('Not a web address', 'Type or paste a full address, like example.com/article.');
      return;
    }
    Keyboard.dismiss();
    setCurrentURL(normalized);
  }, [address]);

  const onMessage = useCallback((event: WebViewMessageEvent) => {
    let body: ExtractMessage;
    try {
      body = JSON.parse(event.nativeEvent.data);
    } catch {
      return;
    }
    if (body.type !== 'article' || !('payload' in body)) return;
    const resolve = pendingSave.current;
    pendingSave.current = null;
    if (!resolve) return;
    const { payload } = body;
    if (payload.error || !payload.content) {
      setSaving(false);
      Alert.alert('Could not save', payload.error ?? 'Could not extract an article from this page.');
      return;
    }
    resolve({
      title: payload.title ?? '',
      byline: payload.byline,
      sourceURL: currentURL,
      contentHTML: payload.content,
      language: payload.lang,
    });
  }, [currentURL]);

  const saveAsBook = useCallback(async () => {
    if (saving) return;
    setSaving(true);
    try {
      const [readability, extractor] = await Promise.all([runtimeText('readability.js'), runtimeText('readability-extract.js')]);
      const runner = extractor.trim().replace(/;\s*$/, '');
      const script = `(function () {
        try { ${readability} } catch (error) {}
        var result = ${runner};
        window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'article', payload: JSON.parse(result) }));
      })(); true;`;

      const article = await new Promise<ArticleContent>((resolve, reject) => {
        pendingSave.current = resolve;
        webViewRef.current?.injectJavaScript(script);
        setTimeout(() => {
          if (pendingSave.current === resolve) {
            pendingSave.current = null;
            reject(new Error('The page did not respond. Try again once it has finished loading.'));
          }
        }, 15000);
      });

      const { uri, fileName } = await buildArticleEPUB(article);
      const { record } = await importDocument(uri, fileName, 'application/epub+zip');
      const existing = getState().books[record.id];
      const saved = {
        ...(existing ?? record),
        title: record.title,
        author: record.author,
        sourceURL: article.sourceURL,
        lastOpenedAt: new Date().toISOString(),
      };
      upsertBook(saved);
      await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      router.back();
      openReader(saved.id);
    } catch (error) {
      Alert.alert('Could not save', error instanceof Error ? error.message : String(error));
    } finally {
      setSaving(false);
    }
  }, [saving, router]);

  return (
    <View style={[styles.screen, { backgroundColor: palette.page }]}>
      <Stack.Screen options={{ title: pageTitle || 'Web' }}>
        <Stack.Toolbar placement="right" tintColor={palette.accent}>
          <Stack.Toolbar.Button
            icon="text.book.closed"
            variant="prominent"
            tintColor={palette.accent}
            accessibilityLabel="Save as Book"
            disabled={saving || loading}
            onPress={() => saveAsBook().catch(() => undefined)}
          />
        </Stack.Toolbar>
        <Stack.Toolbar placement="bottom" tintColor={palette.accent}>
          <Stack.Toolbar.Button icon="chevron.left" accessibilityLabel="Back" disabled={!canGoBack} onPress={() => webViewRef.current?.goBack()} />
          <Stack.Toolbar.Button icon="chevron.right" accessibilityLabel="Forward" disabled={!canGoForward} onPress={() => webViewRef.current?.goForward()} />
          <Stack.Toolbar.Spacer />
          <Stack.Toolbar.Button icon="arrow.clockwise" accessibilityLabel="Reload" onPress={() => webViewRef.current?.reload()} />
          <Stack.Toolbar.Button icon="xmark" accessibilityLabel="Close" onPress={() => router.back()} />
        </Stack.Toolbar>
      </Stack.Screen>

      <View style={styles.addressRow}>
        <GlassSurface style={styles.addressPill}>
          <View style={styles.addressInner}>
            <SymbolView name="globe" size={16} tintColor={palette.muted} />
            <TextInput
              value={address}
              onChangeText={setAddress}
              onSubmitEditing={submit}
              placeholder="Paste or type a URL"
              placeholderTextColor={palette.muted}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              returnKeyType="go"
              clearButtonMode="while-editing"
              selectTextOnFocus
              style={[styles.addressInput, { color: palette.ink }]}
              accessibilityLabel="Web address"
            />
            <Pressable onPress={submit} accessibilityRole="button" accessibilityLabel="Open address" hitSlop={8}>
              <View style={[styles.goButton, { backgroundColor: address.trim() ? palette.accent : palette.border }]}>
                <SymbolView name="arrow.right" size={12} tintColor={address.trim() ? palette.page : palette.muted} weight="bold" />
              </View>
            </Pressable>
          </View>
        </GlassSurface>
      </View>

      <WebView
        ref={webViewRef}
        source={{ uri: currentURL }}
        onMessage={onMessage}
        onLoadStart={() => setLoading(true)}
        onLoadEnd={() => setLoading(false)}
        onNavigationStateChange={(state) => {
          setCanGoBack(state.canGoBack);
          setCanGoForward(state.canGoForward);
          if (state.url && !state.loading) {
            setCurrentURL((previous) => (previous === state.url ? previous : state.url));
            setAddress(state.url);
          }
          if (state.title) setPageTitle(state.title);
        }}
        allowsBackForwardNavigationGestures
        allowsLinkPreview={false}
        style={styles.webView}
      />

      {saving ? (
        <View style={styles.saving} pointerEvents="none">
          <GlassSurface style={styles.savingPill}>
            <ActivityIndicator color={palette.accent} />
            <Typography variant="caption">Saving as book…</Typography>
          </GlassSurface>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1 },
  addressRow: { paddingHorizontal: Spacing.md, paddingVertical: Spacing.sm },
  addressPill: { borderRadius: 22, minHeight: 44, justifyContent: 'center' },
  addressInner: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingLeft: 14, paddingRight: 8 },
  addressInput: { flex: 1, fontFamily: Fonts.sans, fontSize: 16, paddingVertical: 10 },
  goButton: { width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center' },
  webView: { flex: 1 },
  saving: { position: 'absolute', left: 0, right: 0, bottom: 100, alignItems: 'center' },
  savingPill: { flexDirection: 'row', alignItems: 'center', gap: 10, borderRadius: 24, paddingHorizontal: 18, paddingVertical: 12 },
});
