import { useCallback, useEffect, useRef, useState } from 'react';
import { command, describeError, isNative, subscribe } from '../native';
import { DEFAULT_LIBRARY } from '../model';
import type { Book, Library } from '../types';

export function useLibrary() {
  const [library, setLibrary] = useState<Library>(DEFAULT_LIBRARY);
  const [loading, setLoading] = useState(isNative);
  const [error, setError] = useState<string | null>(null);
  const latest = useRef(library);
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const accept = useCallback((next: Library) => {
    if (!next || !next.books || !next.settings) return;
    latest.current = next; setLibrary(next);
  }, []);
  useEffect(() => {
    let alive = true;
    let unlisten: (() => void) | undefined;
    subscribe<Library>('library-changed', next => { if (alive) accept(next); }).then(stop => { if (alive) unlisten = stop; else stop(); });
    if (isNative()) command<Library>('library_get').then(next => { if (alive) accept(next); }).catch(cause => { if (alive) setError(describeError(cause)); }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; unlisten?.(); };
  }, [accept]);
  const run = useCallback(async <T,>(operation: () => Promise<T>): Promise<T | undefined> => {
    try { return await operation(); } catch (cause) { setError(describeError(cause)); return undefined; }
  }, []);
  const mutateBook = useCallback((bookId: string, change: (book: Book) => Book): Promise<Library | undefined> => {
    const operation = queue.current.catch(() => undefined).then(async () => {
      const book = latest.current.books[bookId];
      if (!book) throw new Error('This document is no longer in your library.');
      const next = await command<Library>('library_save_book', { book: change(book), base: book });
      accept(next); return next;
    });
    queue.current = operation;
    return run(() => operation);
  }, [accept, run]);
  const libraryCommand = useCallback((name: string, args?: Record<string, unknown>) => run(async () => {
    const next = await command<Library>(name, args); accept(next); return next;
  }), [accept, run]);
  return { library, latest, loading, error, setError, accept, run, mutateBook, libraryCommand };
}
