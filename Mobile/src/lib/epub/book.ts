import { Directory, File } from 'expo-file-system';

import { parsePublication, type EntrySource } from './parse';
import { directoryAt } from '../files';
import type { BookRecord, Publication } from '../types';

/** Entry source backed by an extracted archive directory. */
export function directorySource(directory: Directory): EntrySource {
  const fileFor = (path: string) => new File(directory, ...path.split('/'));
  return {
    exists: (path) => {
      try {
        return fileFor(path).exists;
      } catch {
        return false;
      }
    },
    text: (path) => fileFor(path).textSync(),
    size: (path) => {
      try {
        return fileFor(path).size ?? 1;
      } catch {
        return 1;
      }
    },
  };
}

const cache = new Map<string, Publication>();

/** Parses (and caches) the publication for an imported EPUB. */
export function loadPublication(record: BookRecord): Publication {
  const cached = cache.get(record.id);
  if (cached) return cached;
  if (!record.extractedRelativePath) {
    throw new Error('This document has no extracted contents. Remove it and import it again.');
  }
  const directory = directoryAt(record.extractedRelativePath);
  const publication = parsePublication(directorySource(directory));
  cache.set(record.id, publication);
  return publication;
}

export function forgetPublication(bookID: string) {
  cache.delete(bookID);
}
