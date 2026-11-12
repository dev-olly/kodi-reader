import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { open, save } from '@tauri-apps/plugin-dialog';

export const isNative = () => '__TAURI_INTERNALS__' in window;
export async function command<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  if (!isNative()) throw new Error('Open Kodi Reader’s desktop application to use this feature. This browser preview cannot access your library.');
  return invoke<T>(name, args);
}
export function describeError(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  if (error && typeof error === 'object' && 'message' in error) return String(error.message);
  return 'The operation could not be completed. Please try again.';
}
export async function subscribe<T>(name: string, handler: (payload: T) => void): Promise<UnlistenFn> {
  if (!isNative()) return () => {};
  return listen<T>(name, event => handler(event.payload));
}
export async function chooseDocuments(): Promise<string[]> {
  const selected = await open({ multiple: true, directory: false, filters: [{ name: 'Books and documents', extensions: ['epub', 'pdf'] }] });
  return selected ? (Array.isArray(selected) ? selected : [selected]) : [];
}
export async function chooseExport(name: string, extension: string): Promise<string | null> {
  return save({ defaultPath: `${name.replace(/[<>:"/\\|?*\x00-\x1f]/g, '-')}.${extension}`, filters: [{ name: extension.toUpperCase(), extensions: [extension] }] });
}
export async function mediaSource(relativePath: string): Promise<string> {
  const data = await command<string>('media_read', { relativePath });
  const ext = relativePath.split('.').pop()?.toLowerCase();
  const mime = ext === 'svg' ? 'image/svg+xml' : ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : 'image/jpeg';
  return `data:${mime};base64,${data}`;
}
