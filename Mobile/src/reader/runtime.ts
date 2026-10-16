import { Asset } from 'expo-asset';
import { Directory, File } from 'expo-file-system';

import { ensureDirectory, ensureLayout, runtimeDirectory } from '@/lib/files';

// Static asset references must be require() calls for Metro to bundle them.
/* eslint-disable @typescript-eslint/no-require-imports */
const RUNTIME_FILES = [
  { module: require('./runtime/reader.js.txt'), name: 'reader.js' },
  { module: require('./runtime/reader.css.txt'), name: 'reader.css' },
  { module: require('./runtime/bridge.js.txt'), name: 'bridge.js' },
  { module: require('./runtime/readability.js.txt'), name: 'readability.js' },
  { module: require('./runtime/readability-extract.js.txt'), name: 'readability-extract.js' },
];
/* eslint-enable @typescript-eslint/no-require-imports */

let installed: Promise<void> | null = null;

/**
 * Copies the reader runtime into the Kodi data directory so chapter files can
 * load it by file URL. Re-copied on every launch so updates ship with the app.
 */
export function ensureRuntimeInstalled(): Promise<void> {
  if (!installed) {
    installed = (async () => {
      ensureLayout();
      for (const entry of RUNTIME_FILES) {
        const asset = Asset.fromModule(entry.module);
        await asset.downloadAsync();
        if (!asset.localUri) throw new Error(`Reader runtime asset ${entry.name} is unavailable.`);
        const target = new File(runtimeDirectory, entry.name);
        if (target.exists) target.delete();
        await new File(asset.localUri).copy(target);
      }
    })().catch((error) => {
      installed = null;
      throw error;
    });
  }
  return installed;
}

export type RuntimeFileName = 'reader.js' | 'reader.css' | 'bridge.js' | 'readability.js' | 'readability-extract.js';

export function runtimeURL(name: RuntimeFileName): string {
  return new File(runtimeDirectory, name).uri;
}

type BookRuntimeFile = 'reader.js' | 'reader.css' | 'bridge.js';

/** Only these trusted assets need to be readable alongside a book's files. */
export async function ensureBookRuntimeInstalled(directory: Directory): Promise<void> {
  await ensureRuntimeInstalled();
  const target = ensureDirectory(new Directory(directory, '.kodi-runtime'));
  await Promise.all((['reader.js', 'reader.css', 'bridge.js'] as const).map((name) =>
    new File(runtimeDirectory, name).copy(new File(target, name), { overwrite: true }),
  ));
}

export function bookRuntimeURL(directory: Directory, name: BookRuntimeFile): string {
  return new File(directory, '.kodi-runtime', name).uri;
}

/** Source text of a runtime file, for injection into a page. */
export async function runtimeText(name: RuntimeFileName): Promise<string> {
  await ensureRuntimeInstalled();
  return new File(runtimeDirectory, name).text();
}
