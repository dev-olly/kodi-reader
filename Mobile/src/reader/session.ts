import { useSyncExternalStore } from 'react';

import type { Locator, Publication } from '@/lib/types';

/**
 * The reader screen registers itself here so sheets presented on top of it
 * (contents, typography, notes) can drive it without prop drilling through
 * the router.
 */
export type ReaderSession = {
  bookID: string;
  publication: Publication | null;
  spineIndex: number;
  chapterTitle?: string;
  goToTOC(path: string, fragment?: string): void;
  goToLocator(locator: Locator): void;
  nextChapter(): void;
  previousChapter(): void;
};

let current: ReaderSession | null = null;
const listeners = new Set<() => void>();

export function setReaderSession(session: ReaderSession | null) {
  current = session;
  for (const listener of listeners) listener();
}

export function updateReaderSession(patch: Partial<ReaderSession>) {
  if (!current) return;
  current = { ...current, ...patch };
  for (const listener of listeners) listener();
}

export function getReaderSession() {
  return current;
}

export function useReaderSession() {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => current,
    () => current,
  );
}
