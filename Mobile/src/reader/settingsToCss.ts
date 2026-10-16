import type { Palette } from '@/lib/theme';
import { FONT_STACKS, HIGHLIGHT_CSS, type Annotation, type ReaderSettings } from '@/lib/types';

/** Horizontal margin in points for a viewport width, clamped to stay readable. */
export function horizontalMargin(settings: ReaderSettings, width: number): number {
  const raw = width * settings.marginRatio;
  return Math.min(Math.max(raw, 20), Math.max(20, width * 0.3));
}

export function verticalMargin(settings: ReaderSettings, topInset: number, bottomInset: number): number {
  return Math.max(56, settings.fontSize * 2.6) + Math.max(topInset, bottomInset) + 8;
}

export function cssVariables(
  settings: ReaderSettings,
  palette: Palette,
  width: number,
  insets: { top: number; bottom: number },
): Record<string, string> {
  return {
    '--font-size': `${settings.fontSize}px`,
    '--line-height': `${settings.lineHeight}`,
    '--font-family': FONT_STACKS[settings.font],
    '--text-align': settings.justified ? 'justify' : 'start',
    '--hyphens': settings.hyphenated ? 'auto' : 'manual',
    '--color-text': palette.ink,
    '--color-background': palette.page,
    '--color-surface': palette.surface,
    '--color-link': palette.accent,
    '--color-selection': palette.selection,
    '--highlight-blend-mode': palette.highlightBlendMode,
    '--page-margin-x': `${horizontalMargin(settings, width)}px`,
    '--page-margin-y': `${verticalMargin(settings, insets.top, insets.bottom)}px`,
  };
}

/** Options object passed to `__reader.start` and `__reader.configure`. */
export function runtimeOptions(
  settings: ReaderSettings,
  palette: Palette,
  width: number,
  insets: { top: number; bottom: number },
): Record<string, unknown> {
  return {
    marginX: horizontalMargin(settings, width),
    marginY: verticalMargin(settings, insets.top, insets.bottom),
    twoPageSpread: false,
    twoPageMinWidth: 100000,
    edgeTapPaging: false,
    animatePageTurns: settings.animatePageTurns,
    variables: cssVariables(settings, palette, width, insets),
  };
}

/** Shape the reader runtime expects in `__reader.setHighlights`. */
export function highlightPayload(annotation: Annotation): Record<string, unknown> {
  const hasNote = Boolean(annotation.note?.trim());
  const visibleColor = hasNote && annotation.color === 'underline' ? 'yellow' : annotation.color;
  const payload: Record<string, unknown> = {
    id: annotation.id,
    color: HIGHLIGHT_CSS[visibleColor],
    style: visibleColor === 'underline' ? 'underline' : 'fill',
    text: annotation.text,
    start: annotation.locator.start,
    hasNote,
  };
  if (annotation.locator.end) payload.end = annotation.locator.end;
  if (hasNote) payload.note = annotation.note;
  return payload;
}

export function inlineStyle(variables: Record<string, string>): string {
  const declarations = Object.entries(variables)
    .map(([key, value]) => `${key}: ${value};`)
    .join(' ');
  return `:root { ${declarations} } html, body { background-color: ${variables['--color-background']} !important; } .x-ebookmaker-cover { background-color: transparent !important; }`;
}
