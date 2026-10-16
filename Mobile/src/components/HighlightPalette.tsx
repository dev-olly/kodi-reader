import { SymbolView } from 'expo-symbols';
import { Pressable, StyleSheet, View } from 'react-native';

import { GlassSurface } from './GlassSurface';
import { usePalette } from '@/hooks/use-palette';
import { FILL_COLORS, HIGHLIGHT_SWATCH, type HighlightColor } from '@/lib/types';

type Props = {
  currentColor?: HighlightColor;
  hasNote?: boolean;
  onPick: (color: HighlightColor) => void;
  onNote: () => void;
  onCopy: () => void;
  onDelete?: () => void;
};

/** Floating glass palette shown over a text selection or a tapped highlight. */
export function HighlightPalette({ currentColor, hasNote, onPick, onNote, onCopy, onDelete }: Props) {
  const palette = usePalette();
  const colors: HighlightColor[] = [...FILL_COLORS, 'underline'];
  return (
    <GlassSurface style={styles.pill} interactive>
      <View style={styles.row}>
        {colors.map((color) => {
          const selected = currentColor === color;
          return (
            <Pressable
              key={color}
              onPress={() => onPick(color)}
              accessibilityRole="button"
              accessibilityLabel={`${color} highlight`}
              hitSlop={6}
              style={styles.swatchHit}>
              {color === 'underline' ? (
                <View style={[styles.underlineSwatch, { borderColor: selected ? palette.ink : 'transparent' }]}>
                  <View style={[styles.underlineBar, { backgroundColor: HIGHLIGHT_SWATCH.underline }]} />
                </View>
              ) : (
                <View
                  style={[
                    styles.swatch,
                    { backgroundColor: HIGHLIGHT_SWATCH[color], borderColor: selected ? palette.ink : 'transparent' },
                  ]}
                />
              )}
            </Pressable>
          );
        })}
        <View style={[styles.divider, { backgroundColor: palette.border }]} />
        <IconButton name={hasNote ? 'note.text' : 'square.and.pencil'} label="Note" onPress={onNote} color={palette.ink} />
        <IconButton name="doc.on.doc" label="Copy" onPress={onCopy} color={palette.ink} />
        {onDelete ? <IconButton name="trash" label="Delete" onPress={onDelete} color="#D14D4D" /> : null}
      </View>
    </GlassSurface>
  );
}

function IconButton({ name, label, onPress, color }: { name: string; label: string; onPress: () => void; color: string }) {
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={label} hitSlop={6} style={styles.iconHit}>
      <SymbolView name={name as never} size={18} tintColor={color} weight="medium" />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  pill: { borderRadius: 999, paddingHorizontal: 10, paddingVertical: 8, alignSelf: 'flex-start' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  swatchHit: { width: 30, height: 30, alignItems: 'center', justifyContent: 'center' },
  swatch: { width: 22, height: 22, borderRadius: 11, borderWidth: 2 },
  underlineSwatch: { width: 22, height: 22, borderRadius: 11, borderWidth: 2, alignItems: 'center', justifyContent: 'center' },
  underlineBar: { width: 12, height: 3, borderRadius: 2 },
  divider: { width: StyleSheet.hairlineWidth, height: 20, marginHorizontal: 4 },
  iconHit: { width: 32, height: 30, alignItems: 'center', justifyContent: 'center' },
});
