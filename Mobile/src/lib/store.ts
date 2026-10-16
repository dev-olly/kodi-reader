import { useSyncExternalStore } from 'react';

import { ensureLayout, fileAt, libraryFile, sanitizedFileName } from './files';
import { DEFAULT_SETTINGS, type Annotation, type BookRecord, type Locator, type ReaderSettings } from './types';

/**
 * The whole library is one JSON file: reading positions, annotations, and
 * settings. A few hundred kilobytes at most, written atomically and debounced
 * so page turns do not thrash the disk.
 */
type LibraryState = {
  version: number;
  books: Record<string, BookRecord>;
  settings: ReaderSettings;
  loaded: boolean;
};

const CURRENT_VERSION = 1;

let state: LibraryState = { version: CURRENT_VERSION, books: {}, settings: DEFAULT_SETTINGS, loaded: false };
const listeners = new Set<() => void>();
let saveTimer: ReturnType<typeof setTimeout> | null = null;

function emit() {
  for (const listener of listeners) listener();
}

function setState(next: Partial<LibraryState>) {
  state = { ...state, ...next };
  emit();
  scheduleSave();
}

function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(flush, 600);
}

export function flush() {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  try {
    ensureLayout();
    const payload = { version: state.version, books: state.books, settings: state.settings };
    libraryFile.write(JSON.stringify(payload, null, 2));
  } catch (error) {
    console.warn('Could not save the library', error);
  }
}

/** Books imported before the cover-path fix may have a cover on disk but no path recorded. */
function withRecoveredCovers(books: Record<string, BookRecord>): Record<string, BookRecord> {
  const next: Record<string, BookRecord> = {};
  for (const [id, book] of Object.entries(books)) {
    if (book.coverRelativePath || book.kind !== 'epub') {
      next[id] = book;
      continue;
    }
    const stem = sanitizedFileName(id);
    const found = ['jpg', 'jpeg', 'png', 'gif', 'webp'].map((ext) => `Covers/${stem}.${ext}`).find((path) => fileAt(path).exists);
    next[id] = found ? { ...book, coverRelativePath: found } : book;
  }
  return next;
}

export function loadLibrary() {
  if (state.loaded) return;
  try {
    ensureLayout();
    if (libraryFile.exists) {
      const parsed = JSON.parse(libraryFile.textSync()) as Partial<LibraryState>;
      state = {
        version: CURRENT_VERSION,
        books: withRecoveredCovers(parsed.books ?? {}),
        settings: { ...DEFAULT_SETTINGS, ...(parsed.settings ?? {}) },
        loaded: true,
      };
    } else {
      state = { ...state, loaded: true };
    }
  } catch (error) {
    console.warn('Could not read the library; starting empty', error);
    state = { ...state, loaded: true };
  }
  emit();
}

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function getState() {
  return state;
}

// Hooks ----------------------------------------------------------------------

export function useLibraryState() {
  return useSyncExternalStore(subscribe, getState, getState);
}

export function useSettings(): ReaderSettings {
  return useSyncExternalStore(subscribe, () => state.settings, () => state.settings);
}

export function useBook(id: string | undefined): BookRecord | undefined {
  return useSyncExternalStore(
    subscribe,
    () => (id ? state.books[id] : undefined),
    () => (id ? state.books[id] : undefined),
  );
}

let recentsCache: { books: Record<string, BookRecord>; list: BookRecord[] } | null = null;

export function selectRecents(): BookRecord[] {
  if (recentsCache && recentsCache.books === state.books) return recentsCache.list;
  const list = Object.values(state.books).sort((a, b) => b.lastOpenedAt.localeCompare(a.lastOpenedAt));
  recentsCache = { books: state.books, list };
  return list;
}

export function useRecents(): BookRecord[] {
  return useSyncExternalStore(subscribe, selectRecents, selectRecents);
}

// Mutations ------------------------------------------------------------------

export function updateSettings(patch: Partial<ReaderSettings>) {
  setState({ settings: { ...state.settings, ...patch } });
}

export function upsertBook(record: BookRecord) {
  setState({ books: { ...state.books, [record.id]: record } });
}

export function updateBook(id: string, transform: (record: BookRecord) => BookRecord) {
  const existing = state.books[id];
  if (!existing) return;
  setState({ books: { ...state.books, [id]: transform(existing) } });
}

export function removeBook(id: string) {
  const { [id]: _removed, ...rest } = state.books;
  setState({ books: rest });
}

export function touchBook(id: string) {
  updateBook(id, (record) => ({ ...record, lastOpenedAt: new Date().toISOString() }));
}

export function savePosition(id: string, position: Locator, progress: number) {
  updateBook(id, (record) => ({ ...record, position, progress }));
}

export function renameBook(id: string, title: string) {
  const name = title.trim();
  if (!name) return;
  updateBook(id, (record) => ({ ...record, title: name }));
}

export function addAnnotation(id: string, annotation: Annotation) {
  updateBook(id, (record) => ({ ...record, annotations: [...record.annotations, annotation] }));
}

export function updateAnnotation(id: string, annotationID: string, patch: Partial<Annotation>) {
  updateBook(id, (record) => ({
    ...record,
    annotations: record.annotations.map((annotation) =>
      annotation.id === annotationID ? { ...annotation, ...patch, modifiedAt: new Date().toISOString() } : annotation,
    ),
  }));
}

export function deleteAnnotation(id: string, annotationID: string) {
  updateBook(id, (record) => ({
    ...record,
    annotations: record.annotations.filter((annotation) => annotation.id !== annotationID),
  }));
}

export function makeID(): string {
  const hex = () => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0');
  return `${hex()}${hex()}-${hex()}-4${hex().slice(1)}-${hex()}-${hex()}${hex()}${hex()}`.toUpperCase();
}
