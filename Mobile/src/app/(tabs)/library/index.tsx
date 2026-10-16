import * as DocumentPicker from 'expo-document-picker';
import * as Haptics from 'expo-haptics';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActionSheetIOS, Alert, Platform, ScrollView, StyleSheet, View } from 'react-native';

import { BookRow } from '@/components/BookRow';
import { Typography } from '@/components/Typography';
import { usePalette } from '@/hooks/use-palette';
import { importDocument, removeDocumentFiles } from '@/lib/epub/import';
import { forgetPublication } from '@/lib/epub/book';
import { forgetReaderBook, openReader } from '@/reader/openReader';
import { addSampleBooks } from '@/lib/samples';
import { getState, removeBook, renameBook, upsertBook, useRecents } from '@/lib/store';
import { Spacing } from '@/lib/theme';
import type { BookRecord } from '@/lib/types';

export default function LibraryScreen() {
  const palette = usePalette();
  const router = useRouter();
  const books = useRecents();
  const [busy, setBusy] = useState(false);
  const { addSamples: addSamplesParam } = useLocalSearchParams<{ addSamples?: string }>();

  const openBook = useCallback((book: BookRecord) => openReader(book.id), []);

  const pickDocument = useCallback(async () => {
    try {
      const result = await DocumentPicker.getDocumentAsync({
        type: ['application/epub+zip', 'application/pdf'],
        copyToCacheDirectory: true,
        multiple: false,
      });
      if (result.canceled || result.assets.length === 0) return;
      const asset = result.assets[0];
      setBusy(true);
      const { record } = await importDocument(asset.uri, asset.name, asset.mimeType);
      const existing = getState().books[record.id];
      upsertBook(existing ? { ...existing, lastOpenedAt: new Date().toISOString() } : record);
      await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      openBook(existing ?? record);
    } catch (error) {
      Alert.alert('Could not open', error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }, [openBook]);

  const addSamples = useCallback(async () => {
    try {
      setBusy(true);
      const added = await addSampleBooks();
      await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      if (added === 0) Alert.alert('Already here', 'The sample books are already in your library.');
    } catch (error) {
      Alert.alert('Could not add samples', error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }, []);

  // Development hook: `kodi://library?addSamples=1` imports the bundled books.
  const handledSampleLink = useRef(false);
  useEffect(() => {
    if (!__DEV__ || addSamplesParam !== '1' || handledSampleLink.current) return;
    handledSampleLink.current = true;
    addSamples().catch(() => undefined);
  }, [addSamplesParam, addSamples]);

  const confirmRemove = useCallback((book: BookRecord) => {
    Alert.alert(
      'Remove this book?',
      'This deletes the book, its highlights and notes from this device.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Remove Book and Notes',
          style: 'destructive',
          onPress: () => {
            forgetReaderBook(book.id);
            removeBook(book.id);
            forgetPublication(book.id);
            removeDocumentFiles(book);
          },
        },
      ],
    );
  }, []);

  const rename = useCallback((book: BookRecord) => {
    if (Platform.OS !== 'ios') return;
    Alert.prompt(
      'Rename Document',
      'The name appears in your library. The original file keeps its name.',
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Rename', onPress: (value?: string) => value && renameBook(book.id, value) },
      ],
      'plain-text',
      book.title,
    );
  }, []);

  const showActions = useCallback(
    (book: BookRecord) => {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => undefined);
      if (Platform.OS !== 'ios') {
        confirmRemove(book);
        return;
      }
      ActionSheetIOS.showActionSheetWithOptions(
        {
          title: book.title,
          message: book.author,
          options: ['Cancel', 'Rename…', 'Remove Book and Notes…'],
          cancelButtonIndex: 0,
          destructiveButtonIndex: 2,
        },
        (index) => {
          if (index === 1) rename(book);
          if (index === 2) confirmRemove(book);
        },
      );
    },
    [confirmRemove, rename],
  );

  const showMore = useCallback(() => {
    const openWeb = () => router.push('/web');
    if (Platform.OS !== 'ios') {
      openWeb();
      return;
    }
    ActionSheetIOS.showActionSheetWithOptions(
      { options: ['Cancel', 'Open Web Page', 'Add Sample Books'], cancelButtonIndex: 0 },
      (index) => {
        if (index === 1) openWeb();
        if (index === 2) addSamples().catch(() => undefined);
      },
    );
  }, [router, addSamples]);

  const continueReading = books.find((book) => book.progress > 0.001 && book.progress < 0.995);
  const shelf = continueReading ? books.filter((book) => book.id !== continueReading.id) : books;

  return (
    <>
      <Stack.Screen options={{ title: 'Library' }}>
        <Stack.Toolbar placement="right" tintColor={palette.accent}>
          <Stack.Toolbar.Button icon="ellipsis" accessibilityLabel="More" onPress={showMore} />
          <Stack.Toolbar.Button icon="plus" variant="prominent" tintColor={palette.accent} accessibilityLabel="Open Document" onPress={pickDocument} disabled={busy} />
        </Stack.Toolbar>
      </Stack.Screen>

      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={styles.content}
        style={{ backgroundColor: palette.page }}>
        <View style={styles.hero}>
          <Typography variant="display">{books.length === 0 ? 'A little more absorbed.' : 'Your next chapter.'}</Typography>
          <Typography variant="body" tone="muted">
            {books.length === 0 ? 'Your books. Your thoughts.' : 'Pick up where you left off.'}
          </Typography>
        </View>

        {books.length === 0 ? (
          <View style={styles.empty}>
            <SymbolView name="books.vertical" size={56} tintColor={palette.muted} weight="light" />
            <Typography variant="title" style={styles.emptyTitle}>
              Room for a good book
            </Typography>
            <Typography variant="body" tone="muted" style={styles.emptyText}>
              Open an EPUB or PDF from Files, or add the sample books from the menu.
            </Typography>
          </View>
        ) : (
          <>
            {continueReading ? (
              <View style={styles.section}>
                <Typography variant="label" tone="muted" style={styles.sectionLabel}>
                  Continue reading
                </Typography>
                <BookRow book={continueReading} onPress={() => openBook(continueReading)} onLongPress={() => showActions(continueReading)} />
              </View>
            ) : null}
            <View style={styles.section}>
              <Typography variant="label" tone="muted" style={styles.sectionLabel}>
                Your library
              </Typography>
              <View style={styles.list}>
                {shelf.map((book) => (
                  <BookRow key={book.id} book={book} onPress={() => openBook(book)} onLongPress={() => showActions(book)} />
                ))}
              </View>
            </View>
          </>
        )}
      </ScrollView>
    </>
  );
}

const styles = StyleSheet.create({
  content: { paddingHorizontal: Spacing.md, paddingBottom: 120, gap: Spacing.lg },
  hero: { gap: 6, paddingTop: Spacing.sm, paddingHorizontal: Spacing.xs },
  empty: { minHeight: 260, alignItems: 'center', justifyContent: 'center', gap: Spacing.sm, paddingHorizontal: Spacing.lg },
  emptyTitle: { textAlign: 'center', marginTop: Spacing.sm },
  emptyText: { textAlign: 'center' },
  section: { gap: Spacing.sm },
  sectionLabel: { paddingHorizontal: Spacing.xs },
  list: { gap: Spacing.sm },
});
