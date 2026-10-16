import { StyleSheet, Text, type TextProps } from 'react-native';

import { usePalette } from '@/hooks/use-palette';
import { Fonts } from '@/lib/theme';

type Props = TextProps & {
  variant?: 'display' | 'title' | 'headline' | 'body' | 'serifBody' | 'caption' | 'label';
  tone?: 'ink' | 'muted' | 'accent';
};

/** App typography: New York for display and quotes, San Francisco for UI. */
export function Typography({ variant = 'body', tone = 'ink', style, ...rest }: Props) {
  const palette = usePalette();
  const color = tone === 'muted' ? palette.muted : tone === 'accent' ? palette.accent : palette.ink;
  return <Text {...rest} style={[styles[variant], { color }, style]} />;
}

const styles = StyleSheet.create({
  display: { fontFamily: Fonts.serif, fontSize: 34, lineHeight: 40, letterSpacing: -0.4 },
  title: { fontFamily: Fonts.serif, fontSize: 22, lineHeight: 28 },
  headline: { fontFamily: Fonts.sans, fontSize: 17, lineHeight: 22, fontWeight: '600' },
  body: { fontFamily: Fonts.sans, fontSize: 17, lineHeight: 22 },
  serifBody: { fontFamily: Fonts.serif, fontSize: 17, lineHeight: 24 },
  caption: { fontFamily: Fonts.sans, fontSize: 13, lineHeight: 18 },
  label: { fontFamily: Fonts.sans, fontSize: 11, lineHeight: 14, fontWeight: '600', letterSpacing: 0.8, textTransform: 'uppercase' },
});
