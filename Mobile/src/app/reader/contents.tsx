import { useRouter } from 'expo-router';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';

import { Typography } from '@/components/Typography';
import { usePalette } from '@/hooks/use-palette';
import { flattenTOC } from '@/lib/epub/parse';
import { Radius, Spacing } from '@/lib/theme';
import { useReaderSession } from '@/reader/session';

/** Table of contents sheet. Taps navigate the open book and dismiss. */
export default function ContentsSheet() {
  const palette = usePalette();
  const router = useRouter();
  const session = useReaderSession();
  const entries = session?.publication ? flattenTOC(session.publication.toc) : [];
  const currentPath = session?.publication?.readingOrder[session.spineIndex]?.path;
  // Several entries can point into one spine file; mark only the first as current.
  const activeID = entries.find(({ entry }) => entry.path && entry.path === currentPath)?.entry.id;

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.content} style={{ backgroundColor: palette.page }}>
      {entries.length === 0 ? (
        <Typography variant="body" tone="muted" style={styles.empty}>
          This book has no table of contents.
        </Typography>
      ) : (
        entries.map(({ entry, depth }) => {
          const active = entry.id === activeID;
          const navigable = Boolean(entry.path);
          return (
            <Pressable
              key={entry.id}
              disabled={!navigable}
              onPress={() => {
                session?.goToTOC(entry.path, entry.fragment);
                router.back();
              }}
              accessibilityRole="button"
              style={({ pressed }) => [
                styles.row,
                { paddingLeft: Spacing.md + depth * 18, backgroundColor: pressed || active ? palette.surface : 'transparent' },
              ]}>
              <View style={[styles.marker, { backgroundColor: active ? palette.accent : 'transparent' }]} />
              <Typography
                variant={depth === 0 ? 'serifBody' : 'body'}
                tone={navigable ? (active ? 'accent' : 'ink') : 'muted'}
                numberOfLines={2}
                style={depth > 0 ? styles.nested : undefined}>
                {entry.title}
              </Typography>
            </Pressable>
          );
        })
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: { paddingVertical: Spacing.sm, paddingHorizontal: Spacing.sm, paddingBottom: 60 },
  empty: { padding: Spacing.lg, textAlign: 'center' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingVertical: 12,
    paddingRight: Spacing.md,
    borderRadius: Radius.sm,
  },
  marker: { width: 3, height: 18, borderRadius: 2 },
  nested: { fontSize: 15 },
});
