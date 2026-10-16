import { useColorScheme } from 'react-native';

import { useSettings } from '@/lib/store';
import { resolvePalette, type Palette } from '@/lib/theme';

/** The active Kodi palette, honouring the reader theme setting and the system scheme. */
export function usePalette(): Palette {
  const settings = useSettings();
  const scheme = useColorScheme();
  return resolvePalette(settings.theme, scheme === 'dark' ? 'dark' : 'light');
}
