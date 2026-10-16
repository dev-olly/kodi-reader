import { Image } from 'expo-image';
import { Pressable, StyleSheet, View } from 'react-native';

import { Typography } from './Typography';
import { usePalette } from '@/hooks/use-palette';
import { fileAt } from '@/lib/files';
import { Fonts, Radius, Spacing } from '@/lib/theme';
import type { BookRecord } from '@/lib/types';

type Props = {
  book: BookRecord;
  onPress: () => void;
  onLongPress?: () => void;
};

export function BookCover({ book, width = 48, height = 70 }: { book: BookRecord; width?: number; height?: number }) {
  const palette = usePalette();
  const uri = book.coverRelativePath ? fileAt(book.coverRelativePath).uri : undefined;
  return (
    <View style={[styles.cover, { width, height, backgroundColor: palette.isDark ? '#3A443E' : '#DCE7DF' }]}>
      {uri ? (
        <Image source={{ uri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={150} />
      ) : (
        <Typography variant="title" tone="accent" style={{ fontSize: height * 0.42, lineHeight: height * 0.5 }}>
          {book.title.trim().charAt(0).toUpperCase() || '·'}
        </Typography>
      )}
    </View>
  );
}

export function BookRow({ book, onPress, onLongPress }: Props) {
  const palette = usePalette();
  const percent = Math.round(book.progress * 100);
  return (
    <Pressable
      onPress={onPress}
      onLongPress={onLongPress}
      accessibilityRole="button"
      accessibilityLabel={`${book.title}, ${book.author}`}
      accessibilityValue={{ text: `${percent} percent read` }}
      style={({ pressed }) => [styles.row, { backgroundColor: pressed ? palette.border : palette.surface }]}>
      <BookCover book={book} />
      <View style={styles.text}>
        <View style={styles.titleLine}>
          <Typography variant="headline" numberOfLines={1} style={styles.title}>
            {book.title}
          </Typography>
          {book.kind === 'pdf' || book.sourceURL ? (
            <View style={[styles.badge, { backgroundColor: palette.border }]}>
              <Typography variant="label" tone="muted" style={styles.badgeText}>
                {book.sourceURL ? 'Web' : 'PDF'}
              </Typography>
            </View>
          ) : null}
        </View>
        <Typography variant="caption" tone="muted" numberOfLines={1}>
          {book.author}
        </Typography>
        <View style={[styles.track, { backgroundColor: palette.border }]}>
          <View style={[styles.fill, { backgroundColor: palette.accent, width: `${Math.max(0, Math.min(100, percent))}%` }]} />
        </View>
      </View>
      {percent > 0 ? (
        <Typography variant="caption" tone="muted" style={styles.percent}>
          {percent}%
        </Typography>
      ) : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.md,
    paddingHorizontal: Spacing.md,
    paddingVertical: 12,
    borderRadius: Radius.md,
  },
  cover: {
    borderRadius: 5,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: { flex: 1, gap: 3 },
  titleLine: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  title: { flexShrink: 1 },
  badge: { paddingHorizontal: 6, paddingVertical: 1, borderRadius: Radius.pill },
  badgeText: { fontSize: 10, lineHeight: 13 },
  track: { height: 3, borderRadius: 2, marginTop: 8, overflow: 'hidden' },
  fill: { height: 3, borderRadius: 2 },
  percent: { fontFamily: Fonts.mono, fontVariant: ['tabular-nums'] },
});
