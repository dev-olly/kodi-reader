/**
 * Shared data model. Mirrors the shapes in the macOS app's EpubKit so a
 * library file could, in principle, round-trip between the two.
 */

export type DocumentKind = 'epub' | 'pdf';

/** A point inside a spine document: childNode indices from <body>, plus a character offset. */
export type TextPosition = {
  elementPath: number[];
  offset: number;
};

export type Locator = {
  kind: DocumentKind;
  /** Index into the reading order (EPUB) or the zero-based page (PDF). */
  spineIndex: number;
  start: TextPosition;
  end?: TextPosition;
  totalProgression?: number;
  text?: string;
};

export type HighlightColor = 'yellow' | 'green' | 'blue' | 'pink' | 'purple' | 'underline';

export const FILL_COLORS: HighlightColor[] = ['yellow', 'green', 'blue', 'pink', 'purple'];

export const HIGHLIGHT_CSS: Record<HighlightColor, string> = {
  yellow: 'rgba(255, 214, 69, 0.45)',
  green: 'rgba(126, 217, 87, 0.40)',
  blue: 'rgba(88, 172, 250, 0.38)',
  pink: 'rgba(255, 138, 178, 0.40)',
  purple: 'rgba(191, 143, 249, 0.40)',
  underline: 'rgba(229, 165, 10, 0.95)',
};

/** Opaque swatch colors for native UI (dots in the palette, list accents). */
export const HIGHLIGHT_SWATCH: Record<HighlightColor, string> = {
  yellow: '#FFD645',
  green: '#7ED957',
  blue: '#58ACFA',
  pink: '#FF8AB2',
  purple: '#BF8FF9',
  underline: '#E5A50A',
};

export type Annotation = {
  id: string;
  locator: Locator;
  /** The highlighted text, which doubles as the note's title. */
  text: string;
  note?: string;
  color: HighlightColor;
  chapterTitle?: string;
  createdAt: string;
  modifiedAt: string;
};

export type BookRecord = {
  id: string;
  title: string;
  author: string;
  kind: DocumentKind;
  /** Path of the imported file relative to the Kodi data directory. */
  importedRelativePath: string;
  /** Extracted archive directory, relative to the Kodi data directory (EPUB only). */
  extractedRelativePath?: string;
  /** Cover image relative to the Kodi data directory, when the book has one. */
  coverRelativePath?: string;
  /** Original page address for books saved from the web. */
  sourceURL?: string;
  addedAt: string;
  lastOpenedAt: string;
  position?: Locator;
  /** 0...1 through the whole document. */
  progress: number;
  annotations: Annotation[];
};

export type ReaderTheme = 'light' | 'dark' | 'system';

export type ReaderFont = 'system' | 'serif' | 'georgia' | 'palatino' | 'charter' | 'sansSerif';

export type ReaderSettings = {
  theme: ReaderTheme;
  font: ReaderFont;
  fontSize: number;
  lineHeight: number;
  /** Fraction of the viewport width used as the side margin, per side. */
  marginRatio: number;
  justified: boolean;
  hyphenated: boolean;
  animatePageTurns: boolean;
};

export const DEFAULT_SETTINGS: ReaderSettings = {
  theme: 'system',
  font: 'serif',
  fontSize: 19,
  lineHeight: 1.6,
  marginRatio: 0.07,
  justified: false,
  hyphenated: true,
  animatePageTurns: true,
};

export const SETTINGS_RANGES = {
  fontSize: { min: 12, max: 32, step: 1 },
  lineHeight: { min: 1.2, max: 2.4, step: 0.1 },
  marginRatio: { min: 0.03, max: 0.2, step: 0.01 },
} as const;

export const FONT_LABELS: Record<ReaderFont, string> = {
  system: 'San Francisco',
  serif: 'New York',
  georgia: 'Georgia',
  palatino: 'Palatino',
  charter: 'Charter',
  sansSerif: 'Helvetica',
};

export const FONT_STACKS: Record<ReaderFont, string> = {
  system: '-apple-system, "SF Pro Text", system-ui, sans-serif',
  serif: '"New York", "Iowan Old Style", Georgia, serif',
  georgia: 'Georgia, "Times New Roman", serif',
  palatino: '"Palatino", "Palatino Linotype", "Book Antiqua", serif',
  charter: '"Charter", "Bitstream Charter", Georgia, serif',
  sansSerif: '"Helvetica Neue", Helvetica, Arial, sans-serif',
};

// EPUB publication model --------------------------------------------------

export type ManifestItem = {
  id: string;
  /** Path within the archive, resolved against the package document. */
  path: string;
  mediaType: string;
  properties: Set<string>;
};

export type SpineItem = {
  idref: string;
  path: string;
  mediaType: string;
  isLinear: boolean;
};

export type TOCEntry = {
  id: string;
  title: string;
  /** Path within the archive, without the fragment. Empty for grouping headings. */
  path: string;
  fragment?: string;
  children: TOCEntry[];
};

export type Publication = {
  title: string;
  creators: string[];
  identifier?: string;
  language?: string;
  manifest: Record<string, ManifestItem>;
  /** Linear reading order. */
  readingOrder: SpineItem[];
  toc: TOCEntry[];
  coverPath?: string;
  packagePath: string;
  pageProgression: 'ltr' | 'rtl';
  /** Uncompressed byte sizes of each reading-order document, for progress weighting. */
  weights: number[];
};
