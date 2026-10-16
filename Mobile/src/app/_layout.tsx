import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo } from 'react';
import { Appearance, AppState } from 'react-native';

import { usePalette } from '@/hooks/use-palette';
import { flush, loadLibrary, useSettings } from '@/lib/store';
import { ReaderOverlay } from '@/reader/ReaderOverlay';
import { ensureRuntimeInstalled } from '@/reader/runtime';

SplashScreen.preventAutoHideAsync().catch(() => undefined);

// Read the library before the first render so screens never flash empty.
loadLibrary();

export default function RootLayout() {
  const palette = usePalette();
  const theme = useSettings().theme;

  // An explicit Light/Dark choice also drives the native chrome: tab bar,
  // glass, sheets and alerts all follow the app's interface style.
  useEffect(() => {
    Appearance.setColorScheme(theme === 'system' ? 'unspecified' : theme);
  }, [theme]);

  useEffect(() => {
    ensureRuntimeInstalled()
      .catch((error) => console.warn('Reader runtime install failed', error))
      .finally(() => SplashScreen.hideAsync().catch(() => undefined));
    const subscription = AppState.addEventListener('change', (state) => {
      if (state !== 'active') flush();
    });
    return () => subscription.remove();
  }, []);

  const navigationTheme = useMemo(() => {
    const base = palette.isDark ? DarkTheme : DefaultTheme;
    return {
      ...base,
      colors: {
        ...base.colors,
        primary: palette.accent,
        background: palette.page,
        card: palette.page,
        text: palette.ink,
        border: palette.border,
        notification: palette.accent,
      },
    };
  }, [palette]);

  return (
    <ThemeProvider value={navigationTheme}>
      <StatusBar style={palette.isDark ? 'light' : 'dark'} />
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: palette.page } }}>
        <Stack.Screen name="(tabs)" />
        <Stack.Screen
          name="web/index"
          options={{
            presentation: 'modal',
            headerShown: true,
            headerShadowVisible: false,
            headerStyle: { backgroundColor: palette.page },
            headerTintColor: palette.accent,
            headerTitleStyle: { color: palette.ink },
            title: 'Web',
          }}
        />
        <Stack.Screen
          name="reader/contents"
          options={{
            presentation: 'formSheet',
            sheetAllowedDetents: [0.55, 1],
            sheetGrabberVisible: true,
            sheetCornerRadius: 28,
            headerShown: true,
            title: 'Contents',
          }}
        />
        <Stack.Screen
          name="reader/typography"
          options={{
            presentation: 'formSheet',
            sheetAllowedDetents: [0.72, 1],
            sheetGrabberVisible: true,
            sheetCornerRadius: 28,
            headerShown: true,
            title: 'Appearance',
          }}
        />
        <Stack.Screen
          name="note/[bookId]/[annotationId]"
          options={{
            presentation: 'formSheet',
            sheetAllowedDetents: [0.6, 1],
            sheetGrabberVisible: true,
            sheetCornerRadius: 28,
            headerShown: true,
            title: 'Note',
          }}
        />
      </Stack>
      {/* The reader lives above the stack for the whole session, so its web views stay warm. */}
      <ReaderOverlay />
    </ThemeProvider>
  );
}
