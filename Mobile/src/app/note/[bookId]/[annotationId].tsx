import * as Haptics from 'expo-haptics';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, TextInput, View } from 'react-native';

import { GlassGroup, GlassSurface } from '@/components/GlassSurface';
import { Typography } from '@/components/Typography';
import { usePalette } from '@/hooks/use-palette';
import { deleteAnnotation, updateAnnotation, useBook } from '@/lib/store';
import { Fonts, Radius, Spacing } from '@/lib/theme';
import { FILL_COLORS, HIGHLIGHT_SWATCH, type HighlightColor } from '@/lib/types';

/** Note editor for one highlight: colour, markdown body, delete. */
export default function NoteSheet() {
  const palette = usePalette();
  const router = useRouter();
  const { bookId, annotationId, autofocus } = useLocalSearchParams<{ bookId: string; annotationId: string; autofocus?: string }>();
  const book = useBook(bookId);
  const annotation = book?.annotations.find((item) => item.id === annotationId);
  const [draft, setDraft] = useState(annotation?.note ?? '');
  const draftRef = useRef(draft);
  const dirtyRef = useRef(false);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const colors: HighlightColor[] = [...FILL_COLORS, 'underline'];

  const commit = useCallback(
    (value: string) => {
      if (!bookId || !annotationId) return;
      updateAnnotation(bookId, annotationId, { note: value.trim() ? value : undefined });
    },
    [bookId, annotationId],
  );

  const flushDraft = useCallback(() => {
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = null;
    if (!dirtyRef.current) return;
    dirtyRef.current = false;
    commit(draftRef.current);
  }, [commit]);

  useEffect(() => flushDraft, [flushDraft]);

  const onChange = (value: string) => {
    setDraft(value);
    draftRef.current = value;
    dirtyRef.current = true;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(flushDraft, 400);
  };

  const remove = () => {
    if (!bookId || !annotationId) return;
    Alert.alert('Delete highlight?', 'The highlight and its note are removed from this book.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          dirtyRef.current = false;
          if (saveTimer.current) clearTimeout(saveTimer.current);
          deleteAnnotation(bookId, annotationId);
          router.back();
        },
      },
    ]);
  };

  if (!book || !annotation) {
    return (
      <View style={[styles.missing, { backgroundColor: palette.page }]}>
        <Typography variant="body" tone="muted">
          This note no longer exists.
        </Typography>
      </View>
    );
  }

  return (
    <>
      <Stack.Screen options={{ title: 'Note' }}>
        <Stack.Toolbar placement="right" tintColor={palette.accent}>
          <Stack.Toolbar.Button
            icon="checkmark"
            variant="done"
            accessibilityLabel="Done"
            onPress={() => {
              flushDraft();
              router.back();
            }}
          />
        </Stack.Toolbar>
      </Stack.Screen>
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        keyboardDismissMode="interactive"
        contentContainerStyle={styles.content}
        style={{ backgroundColor: palette.page }}>
        <Typography variant="label" tone="muted">
          {[book.title, annotation.chapterTitle].filter(Boolean).join(' · ')}
        </Typography>
        <View style={[styles.quote, { borderLeftColor: HIGHLIGHT_SWATCH[annotation.color], backgroundColor: palette.surface }]}>
          <Typography variant="serifBody">{annotation.text}</Typography>
        </View>

        <GlassGroup style={styles.colors} spacing={8}>
          {colors.map((color) => {
            const selected = annotation.color === color;
            return (
              <GlassSurface key={color} interactive style={styles.colorGlass}>
                <Pressable
                  onPress={() => {
                    Haptics.selectionAsync().catch(() => undefined);
                    updateAnnotation(book.id, annotation.id, { color });
                  }}
                  accessibilityRole="button"
                  accessibilityLabel={`${color} highlight`}
                  accessibilityState={{ selected }}
                  style={styles.colorHit}>
                  {color === 'underline' ? (
                    <View style={[styles.underlineSwatch, { borderColor: selected ? palette.ink : 'transparent' }]}>
                      <View style={[styles.underlineBar, { backgroundColor: HIGHLIGHT_SWATCH.underline }]} />
                    </View>
                  ) : (
                    <View style={[styles.swatch, { backgroundColor: HIGHLIGHT_SWATCH[color], borderColor: selected ? palette.ink : 'transparent' }]} />
                  )}
                </Pressable>
              </GlassSurface>
            );
          })}
        </GlassGroup>

        <TextInput
          value={draft}
          onChangeText={onChange}
          multiline
          autoFocus={autofocus === '1'}
          placeholder="Write your note…"
          placeholderTextColor={palette.muted}
          scrollEnabled={false}
          textAlignVertical="top"
          style={[styles.editor, { color: palette.ink }]}
          accessibilityLabel="Note"
        />
        <Typography variant="caption" tone="muted">
          A thought worth keeping. Markdown is welcome.
        </Typography>

        <Pressable onPress={remove} accessibilityRole="button" style={({ pressed }) => [styles.delete, { opacity: pressed ? 0.6 : 1 }]}>
          <Typography variant="body" style={{ color: '#D14D4D' }}>
            Delete Highlight
          </Typography>
        </Pressable>
      </ScrollView>
    </>
  );
}

const styles = StyleSheet.create({
  missing: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  content: { padding: Spacing.lg, gap: Spacing.md, paddingBottom: 80 },
  quote: { borderLeftWidth: 3, borderRadius: Radius.sm, padding: Spacing.md },
  colors: { flexDirection: 'row', gap: 8, alignItems: 'center' },
  colorGlass: { width: 40, height: 40, borderRadius: 20 },
  colorHit: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  swatch: { width: 22, height: 22, borderRadius: 11, borderWidth: 2 },
  underlineSwatch: { width: 22, height: 22, borderRadius: 11, borderWidth: 2, alignItems: 'center', justifyContent: 'center' },
  underlineBar: { width: 12, height: 3, borderRadius: 2 },
  editor: { fontFamily: Fonts.serif, fontSize: 20, lineHeight: 30, minHeight: 160, paddingTop: Spacing.sm },
  delete: { alignSelf: 'center', paddingVertical: Spacing.md },
});
