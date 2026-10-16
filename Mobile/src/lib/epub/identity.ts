import { CryptoDigestAlgorithm, digest, digestStringAsync } from 'expo-crypto';

import type { DocumentKind } from '../types';

/** Storage names never contain publisher-controlled path components. */
export async function documentID(kind: DocumentKind, bytes: Uint8Array, identifier?: string): Promise<string> {
  const original = identifier?.trim();
  if (original) {
    return `${kind}-${await digestStringAsync(CryptoDigestAlgorithm.SHA256, original)}`;
  }
  const hash = new Uint8Array(await digest(CryptoDigestAlgorithm.SHA256, new Uint8Array(bytes)));
  return `${kind}-${Array.from(hash, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}
