type StorageReader = Pick<Storage, 'getItem'>;
type StorageWriter = Pick<Storage, 'setItem'>;

export function readPreference(key: string, choices: readonly string[], fallback: string, storage?: StorageReader): string {
  try { const value = (storage ?? localStorage).getItem(key); return value && choices.includes(value) ? value : fallback; }
  catch { return fallback; }
}

export function savePreference(key: string, value: string, storage?: StorageWriter): void {
  try { (storage ?? localStorage).setItem(key, value); } catch { /* Preferences remain usable for this session when storage is unavailable. */ }
}

export function readSavedPrompts(storage?: StorageReader): string[] {
  try {
    const value: unknown = JSON.parse((storage ?? localStorage).getItem('kodi-desktop.prompts') || '[]');
    return Array.isArray(value) ? [...new Set(value.filter((prompt): prompt is string => typeof prompt === 'string' && Boolean(prompt.trim())))] : [];
  } catch { return []; }
}
