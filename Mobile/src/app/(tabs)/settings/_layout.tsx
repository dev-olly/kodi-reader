import { Stack } from 'expo-router';

import { usePalette } from '@/hooks/use-palette';

export default function SettingsLayout() {
  const palette = usePalette();
  return (
    <Stack
      screenOptions={{
        headerLargeTitle: true,
        headerTransparent: true,
        headerShadowVisible: false,
        headerTintColor: palette.accent,
        headerTitleStyle: { color: palette.ink },
        headerLargeTitleStyle: { color: palette.ink, fontFamily: 'ui-serif' },
        contentStyle: { backgroundColor: palette.page },
      }}
    />
  );
}
