export const PENDING_SIGN_IN_KEY = 'kodi-desktop.pending-sign-in';
export const PENDING_SIGN_IN_TTL_MS = 10 * 60 * 1000;

export interface PendingSignIn { email: string; expiresAt: number }

// Email clients can add invisible formatting around or between copied digits.
// Keep the code as text so a leading zero is never lost.
export function normalizeSignInCode(value: string): string {
  return value.replace(/[\p{White_Space}\p{Default_Ignorable_Code_Point}]/gu, '');
}

export function createPendingSignIn(email: string, timestamp: number): PendingSignIn {
  return { email: email.trim(), expiresAt: timestamp + PENDING_SIGN_IN_TTL_MS };
}

export function parsePendingSignIn(serialized: string | null, timestamp: number): PendingSignIn | null {
  if (!serialized) return null;
  try {
    const value: unknown = JSON.parse(serialized);
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const { email, expiresAt } = value as Record<string, unknown>;
    if (typeof email !== 'string' || email !== email.trim() || email.length > 320 || !/^[^\s@]+@[^\s@]+$/.test(email)) return null;
    if (typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt) || expiresAt <= timestamp || expiresAt > timestamp + PENDING_SIGN_IN_TTL_MS) return null;
    // Return only the email and expiry, even if the stored object was malformed.
    return { email, expiresAt };
  } catch { return null; }
}
