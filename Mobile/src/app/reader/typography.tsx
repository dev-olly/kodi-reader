import { Form, Host } from '@expo/ui/swift-ui';
import { scrollContentBackground, tint } from '@expo/ui/swift-ui/modifiers';
import { StyleSheet } from 'react-native';

import { AppearanceSections } from '@/components/AppearanceForm';
import { usePalette } from '@/hooks/use-palette';

/** Appearance sheet over the reader. Changes apply live to the page behind it. */
export default function TypographySheet() {
  const palette = usePalette();
  return (
    <Host style={[styles.host, { backgroundColor: palette.page }]} colorScheme={palette.isDark ? 'dark' : 'light'}>
      <Form modifiers={[tint(palette.accent), scrollContentBackground('hidden')]}>
        <AppearanceSections />
      </Form>
    </Host>
  );
}

const styles = StyleSheet.create({
  host: { flex: 1 },
});
