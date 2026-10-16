import { Platform } from 'react-native';

import type { ReaderSettings } from './types';

/**
 * Kodi palette, shared between native chrome and the web renderer so page
 * backgrounds match across both. Values come from the macOS ReaderAppearance.
 */
export type Palette = {
  isDark: boolean;
  ink: string;
  page: string;
  surface: string;
  accent: string;
  muted: string;
  border: string;
  selection: string;
  highlightBlendMode: 'multiply' | 'screen';
};

export const LIGHT: Palette = {
  isDark: false,
  ink: '#192A24',
  page: '#FFFFFF',
  surface: '#F0F5F1',
  accent: '#245744',
  muted: '#59675F',
  border: '#D9E2DC',
  selection: 'rgba(114, 165, 124, 0.25)',
  highlightBlendMode: 'multiply',
};

export const DARK: Palette = {
  isDark: true,
  ink: '#E9EEE9',
  page: '#202522',
  surface: '#282E2A',
  accent: '#ACD5B4',
  muted: '#AFBEB4',
  border: '#46544B',
  selection: 'rgba(172, 213, 180, 0.30)',
  highlightBlendMode: 'screen',
};

export const BRAND_GREEN = '#245744';

export function resolvePalette(theme: ReaderSettings['theme'], systemScheme: 'light' | 'dark' | null | undefined): Palette {
  if (theme === 'dark') return DARK;
  if (theme === 'light') return LIGHT;
  return systemScheme === 'dark' ? DARK : LIGHT;
}

export const Fonts = {
  /** iOS "New York" via the system serif design. */
  serif: Platform.select({ ios: 'ui-serif', default: 'serif' }),
  sans: Platform.select({ ios: 'system-ui', default: 'sans-serif' }),
  mono: Platform.select({ ios: 'ui-monospace', default: 'monospace' }),
};

export const Spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
  xxl: 48,
} as const;

export const Radius = {
  sm: 8,
  md: 14,
  lg: 22,
  pill: 999,
} as const;
