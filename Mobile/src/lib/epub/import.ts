import { Directory, File } from 'expo-file-system';
import { randomUUID } from 'expo-crypto';
import { unzipSync } from 'fflate';

import { directorySource } from './book';
import { documentID } from './identity';
import { extensionOf } from './path';
import { parsePublication } from './parse';
import { booksDirectory, coversDirectory, directoryAt, ensureDirectory, ensureLayout, extractedDirectory, fileAt, sanitizedFileName } from '../files';
import type { BookRecord, DocumentKind } from '../types';

function kindFor(name: string, mimeType?: string | null): DocumentKind {
  if (mimeType === 'application/pdf' || extensionOf(name) === 'pdf') return 'pdf';
  return 'epub';
}

function utf8(bytes: Uint8Array): string {
  // Hermes ships TextDecoder; fall back to a manual decode just in case.
  if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(bytes);
  let out = '';
  for (let i = 0; i < bytes.length; i += 1) out += String.fromCharCode(bytes[i]);
  return decodeURIComponent(escape(out));
}

function extractEPUB(bytes: Uint8Array, bookID: string): Directory {
  let entries: Record<string, Uint8Array>;
  try {
    entries = unzipSync(bytes);
  } catch {
    throw new Error('This file is not a readable EPUB archive.');
  }
  const target = new Directory(extractedDirectory, sanitizedFileName(bookID));
  if (target.exists) target.delete();
  target.create({ intermediates: true });

  for (const [path, data] of Object.entries(entries)) {
    if (path.endsWith('/')) continue;
    const segments = path.split('/').filter(Boolean);
    if (segments.some((segment) => segment === '..')) continue;
    const fileName = segments.pop();
    if (!fileName) continue;
    const parent = segments.length > 0 ? new Directory(target, ...segments) : target;
    ensureDirectory(parent);
    const file = new File(parent, fileName);
    file.write(data);
  }
  return target;
}

/**
 * Copies a picked document into the library, unzips EPUBs, parses metadata,
 * and returns a record ready to persist. Existing records with the same id
 * keep their reading data; the caller decides whether to merge.
 */
export async function importDocument(
  uri: string,
  displayName: string,
  mimeType?: string | null,
): Promise<{ record: BookRecord; existingID?: string }> {
  ensureLayout();
  const source = new File(uri);
  if (!source.exists) throw new Error('The chosen file could not be read.');
  const kind = kindFor(displayName, mimeType);
  const bytes = await source.bytes();
  const baseName = displayName.replace(/\.(epub|pdf)$/i, '');
  const now = new Date().toISOString();

  if (kind === 'pdf') {
    const id = await documentID(kind, bytes);
    const destination = new File(booksDirectory, `${sanitizedFileName(id)}.pdf`);
    if (!destination.exists) await source.copy(destination);
    return {
      record: {
        id,
        title: baseName,
        author: 'PDF document',
        kind,
        importedRelativePath: `Books/${sanitizedFileName(id)}.pdf`,
        addedAt: now,
        lastOpenedAt: now,
        progress: 0,
        annotations: [],
      },
    };
  }

  // Extract under a provisional id, parse, then rename to the stable id.
  const provisionalID = `tmp-${randomUUID()}`;
  const extracted = extractEPUB(bytes, provisionalID);
  let publication;
  try {
    publication = parsePublication(directorySource(extracted));
  } catch (error) {
    extracted.delete();
    throw error;
  }
  // Hash the complete identifier (or document bytes), never a truncated slug.
  const safeID = await documentID(kind, bytes, publication.identifier);
  const id = safeID;

  // A book that is already in the library keeps its extraction and copy, so
  // re-importing (or re-adding the samples) never disturbs an open reader.
  const finalDirectory = new Directory(extractedDirectory, safeID);
  if (!finalDirectory.uri.startsWith(extractedDirectory.uri.replace(/\/$/, '') + '/')) {
    extracted.delete();
    throw new Error('The book storage directory is outside the library extraction directory.');
  }
  const destination = new File(booksDirectory, `${safeID}.epub`);
  if (finalDirectory.exists && destination.exists) {
    extracted.delete();
  } else {
    if (finalDirectory.exists) finalDirectory.delete();
    await extracted.move(finalDirectory);
    if (destination.exists) destination.delete();
    await source.copy(destination);
  }

  let coverRelativePath: string | undefined;
  if (publication.coverPath) {
    try {
      const coverSource = new File(finalDirectory, ...publication.coverPath.split('/'));
      const extension = extensionOf(publication.coverPath) || 'jpg';
      const coverTarget = new File(coversDirectory, `${safeID}.${extension}`);
      if (!coverTarget.exists) await coverSource.copy(coverTarget);
      coverRelativePath = `Covers/${safeID}.${extension}`;
    } catch (error) {
      console.warn('Cover copy failed for', safeID, publication.coverPath, error);
    }
  }

  return {
    record: {
      id,
      title: publication.title || baseName,
      author: publication.creators.length > 0 ? publication.creators.join(', ') : 'Unknown Author',
      kind,
      importedRelativePath: `Books/${safeID}.epub`,
      extractedRelativePath: `Extracted/${safeID}`,
      coverRelativePath,
      addedAt: now,
      lastOpenedAt: now,
      progress: 0,
      annotations: [],
    },
  };
}

export function removeDocumentFiles(record: BookRecord) {
  const tryDelete = (target: File | Directory) => {
    try {
      if (target.exists) target.delete();
    } catch {
      /* best effort */
    }
  };
  tryDelete(fileAt(record.importedRelativePath));
  if (record.extractedRelativePath) tryDelete(directoryAt(record.extractedRelativePath));
  if (record.coverRelativePath) tryDelete(fileAt(record.coverRelativePath));
}

export { utf8 };
