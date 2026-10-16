import { useSyncExternalStore } from 'react';

/**
 * Which book the reader shows. The reader is a persistent layer above the
 * navigation stack rather than a route, so its web views (and their WebKit
 * processes) survive between books: opening a book is a page navigation, not
 * a cold start.
 */
export type ReaderRequest = {
  /** The book loaded in the reader. Kept after closing so reopening it is instant. */
  bookID: string | null;
  /** Highlight to jump to when this request opens, from the Notes tab. */
  annotationID?: string;
  visible: boolean;
  /** Changes on every open, so reopening the same book still applies the request. */
  nonce: number;
};

let request: ReaderRequest = { bookID: null, visible: false, nonce: 0 };
const listeners = new Set<() => void>();

function set(next: ReaderRequest) {
  request = next;
  for (const listener of listeners) listener();
}

export function openReader(bookID: string, annotationID?: string) {
  set({ bookID, annotationID, visible: true, nonce: request.nonce + 1 });
}

export function closeReader() {
  if (!request.visible) return;
  set({ ...request, annotationID: undefined, visible: false });
}

/** Called when a book is deleted, so the reader drops it. */
export function forgetReaderBook(bookID: string) {
  if (request.bookID === bookID) set({ bookID: null, visible: false, nonce: request.nonce + 1 });
}

export function useReaderRequest(): ReaderRequest {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => request,
    () => request,
  );
}
