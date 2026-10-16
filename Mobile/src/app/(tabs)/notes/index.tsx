import { Stack } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { useCallback, useMemo } from 'react';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';

import { Typography } from '@/components/Typography';
import { usePalette } from '@/hooks/use-palette';
import { shareNotes } from '@/lib/export';
import { openReader } from '@/reader/openReader';
import { useRecents } from '@/lib/store';
import { Radius, Spacing } from '@/lib/theme';
import { HIGHLIGHT_SWATCH, type Annotation, type BookRecord } from '@/lib/types';

function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export default function NotesScreen() {
  const palette = usePalette();
  const books = useRecents();
  const annotated = useMemo(() => books.filter((book) => book.annotations.length > 0), [books]);
  const total = useMemo(() => annotated.reduce((sum, book) => sum + book.annotations.length, 0), [annotated]);

  const open = useCallback((book: BookRecord, annotation: Annotation) => openReader(book.id, annotation.id), []);

  return (
    <>
      <Stack.Screen options={{ title: 'Notes' }}>
        <Stack.Toolbar placement="right" tintColor={palette.accent}>
          <Stack.Toolbar.Button
            icon="square.and.arrow.up"
            accessibilityLabel="Export notes"
            disabled={total === 0}
            onPress={() => shareNotes(annotated).catch(() => undefined)}
          />
        </Stack.Toolbar>
      </Stack.Screen>
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.content} style={{ backgroundColor: palette.page }}>
        <View style={styles.hero}>
          <Typography variant="display">Your margin.</Typography>
          <Typography variant="body" tone="muted">
            {total === 0 ? 'Highlights and notes from every book land here.' : `${total} ${total === 1 ? 'note' : 'notes'} across ${annotated.length} ${annotated.length === 1 ? 'book' : 'books'}.`}
          </Typography>
        </View>
        {annotated.length === 0 ? (
          <View style={styles.empty}>
            <SymbolView name="highlighter" size={56} tintColor={palette.muted} weight="light" />
            <Typography variant="title" style={styles.emptyTitle}>
              Nothing highlighted yet
            </Typography>
            <Typography variant="body" tone="muted" style={styles.emptyText}>
              Select a passage while reading to highlight it or attach a note.
            </Typography>
          </View>
        ) : (
          annotated.map((book) => (
            <View key={book.id} style={styles.section}>
              <Typography variant="label" tone="muted" style={styles.sectionLabel}>
                {book.title}
              </Typography>
              <View style={styles.list}>
                {[...book.annotations]
                  .sort((a, b) => a.locator.spineIndex - b.locator.spineIndex)
                  .map((annotation) => (
                    <Pressable
                      key={annotation.id}
                      onPress={() => open(book, annotation)}
                      accessibilityRole="button"
                      style={({ pressed }) => [styles.card, { backgroundColor: pressed ? palette.border : palette.surface }]}>
                      <View style={[styles.bar, { backgroundColor: HIGHLIGHT_SWATCH[annotation.color] }]} />
                      <View style={styles.cardBody}>
                        <Typography variant="serifBody" numberOfLines={3}>
                          {annotation.text}
                        </Typography>
                        {annotation.note?.trim() ? (
                          <Typography variant="body" tone="muted" numberOfLines={2} style={styles.note}>
                            {annotation.note.trim()}
                          </Typography>
                        ) : null}
                        <Typography variant="caption" tone="muted">
                          {[annotation.chapterTitle, formatDate(annotation.createdAt)].filter(Boolean).join(' · ')}
                        </Typography>
                      </View>
                    </Pressable>
                  ))}
              </View>
            </View>
          ))
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
  card: { flexDirection: 'row', borderRadius: Radius.md, overflow: 'hidden' },
  bar: { width: 4 },
  cardBody: { flex: 1, padding: Spacing.md, gap: 6 },
  note: { fontSize: 15, lineHeight: 20 },
});
