import { Asset } from 'expo-asset';

import { importDocument } from './epub/import';
import { getState, upsertBook } from './store';

// Static asset references must be require() calls for Metro to bundle them.
/* eslint-disable @typescript-eslint/no-require-imports */
const SAMPLES = [
  { module: require('@/assets/samples/alice.epub'), name: 'alice.epub' },
  { module: require('@/assets/samples/frankenstein.epub'), name: 'frankenstein.epub' },
];
/* eslint-enable @typescript-eslint/no-require-imports */

/** Adds the bundled Project Gutenberg books. Books already in the library are kept as they are. */
export async function addSampleBooks(): Promise<number> {
  let added = 0;
  for (const sample of SAMPLES) {
    const asset = Asset.fromModule(sample.module);
    await asset.downloadAsync();
    if (!asset.localUri) continue;
    const { record } = await importDocument(asset.localUri, sample.name, 'application/epub+zip');
    if (getState().books[record.id]) continue;
    upsertBook(record);
    added += 1;
  }
  return added;
}
