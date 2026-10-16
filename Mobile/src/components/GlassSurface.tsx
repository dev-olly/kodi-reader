import { GlassContainer, GlassView, isGlassEffectAPIAvailable, isLiquidGlassAvailable } from 'expo-glass-effect';
import type { PropsWithChildren } from 'react';
import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';

import { usePalette } from '@/hooks/use-palette';

export const glassAvailable = isLiquidGlassAvailable() && isGlassEffectAPIAvailable();

type SurfaceProps = PropsWithChildren<{
  style?: StyleProp<ViewStyle>;
  interactive?: boolean;
  tint?: string;
  /** `clear` lets more of the page show through; `regular` is the default. */
  variant?: 'regular' | 'clear';
}>;

/**
 * Liquid Glass on iOS 26, with a translucent fallback that keeps the same
 * geometry on older systems and in Reduce Transparency.
 */
export function GlassSurface({ style, interactive, tint, variant = 'regular', children }: SurfaceProps) {
  const palette = usePalette();
  if (glassAvailable) {
    return (
      <GlassView style={style} isInteractive={interactive} tintColor={tint} glassEffectStyle={variant}>
        {children}
      </GlassView>
    );
  }
  return (
    <View
      style={[
        style,
        styles.fallback,
        { backgroundColor: palette.isDark ? 'rgba(40, 46, 42, 0.92)' : 'rgba(255, 255, 255, 0.92)', borderColor: palette.border },
      ]}>
      {children}
    </View>
  );
}

type GroupProps = PropsWithChildren<{ style?: StyleProp<ViewStyle>; spacing?: number }>;

/** Groups neighbouring glass surfaces so they merge as they move together. */
export function GlassGroup({ style, spacing = 12, children }: GroupProps) {
  if (glassAvailable) {
    return (
      <GlassContainer spacing={spacing} style={style}>
        {children}
      </GlassContainer>
    );
  }
  return <View style={style}>{children}</View>;
}

const styles = StyleSheet.create({
  fallback: {
    borderWidth: StyleSheet.hairlineWidth,
  },
});
