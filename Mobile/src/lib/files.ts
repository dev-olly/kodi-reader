import { Directory, File, Paths } from 'expo-file-system';

/**
 * On-disk layout, all under the app's document directory:
 *
 *   Kodi/
 *     library.json          reading positions, annotations, settings
 *     Books/<id>.epub|pdf   durable copies of imported documents
 *     Extracted/<id>/...    unzipped EPUB contents, served to the web view
 *     Covers/<id>.<ext>     cover images for the library
 *     runtime/              reader.js, reader.css, bridge.js
 *
 * Reader web views only get access to their own extraction directory. Trusted
 * runtime files are copied into each book; library.json stays outside it.
 */
export const rootDirectory = new Directory(Paths.document, 'Kodi');
export const booksDirectory = new Directory(rootDirectory, 'Books');
export const extractedDirectory = new Directory(rootDirectory, 'Extracted');
export const coversDirectory = new Directory(rootDirectory, 'Covers');
export const runtimeDirectory = new Directory(rootDirectory, 'runtime');
export const libraryFile = new File(rootDirectory, 'library.json');

export function ensureDirectory(directory: Directory) {
  if (!directory.exists) {
    directory.create({ intermediates: true });
  }
  return directory;
}

export function ensureLayout() {
  ensureDirectory(rootDirectory);
  ensureDirectory(booksDirectory);
  ensureDirectory(extractedDirectory);
  ensureDirectory(coversDirectory);
  ensureDirectory(runtimeDirectory);
}

/** A file under the Kodi root, addressed by its stored relative path. */
export function fileAt(relativePath: string): File {
  return new File(rootDirectory, ...relativePath.split('/'));
}

export function directoryAt(relativePath: string): Directory {
  return new Directory(rootDirectory, ...relativePath.split('/'));
}

/** Only alphanumerics, dash, underscore and dot survive into a file name. */
export function sanitizedFileName(id: string): string {
  const cleaned = id.replace(/[^A-Za-z0-9\-_.]/g, '-');
  const name = (cleaned || 'book').slice(0, 120);
  return name === '.' || name === '..' ? 'book' : name;
}

/** Decoded, trailing-slash-free file URL for a directory. */
export function directoryURL(directory: Directory): string {
  return directory.uri.replace(/\/$/, '');
}
