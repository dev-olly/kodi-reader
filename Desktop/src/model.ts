import type { Annotation, AudioState, Book, Library, Locator, ReaderMessage, ReaderSession } from './types';

export const now = () => Date.now() / 1000;
export const uuid = () => crypto.randomUUID();
export const DEFAULT_LIBRARY: Library = {
  schemaVersion: 1, books: {}, deviceId: '', readingHistory: {}, goalMinutes: 20,
  settings: { theme: 'system', fontFamily: 'Georgia', fontSize: 19, lineHeight: 1.65, margin: 56, twoPageSpread: true, showReadingGoal: false, analyticsEnabled: false },
};
export const HIGHLIGHTS = [
  { id: 'yellow', label: 'Yellow', css: '#efd279' },
  { id: 'green', label: 'Green', css: '#b3d2b2' },
  { id: 'blue', label: 'Blue', css: '#afcce5' },
  { id: 'pink', label: 'Pink', css: '#eab7c5' },
  { id: 'purple', label: 'Purple', css: '#c9b8dc' },
  { id: 'underline', label: 'Underline', css: 'transparent' },
] as const;
export function percent(value: number): number { return Math.min(100, Math.max(0, Math.round((Number.isFinite(value) ? value : 0) * 100))); }
export function duration(value = 0): string { return `${Math.floor(Math.max(0, value) / 60)}:${Math.floor(Math.max(0, value) % 60).toString().padStart(2, '0')}`; }
export function narrationPlaybackAction(audio: AudioState): 'start' | 'pause' | 'resume' {
  if (audio.kind !== 'narration') return 'start';
  return audio.phase === 'playing' || audio.phase === 'preparing' ? 'pause' : audio.phase === 'paused' ? 'resume' : 'start';
}
export function localDay(date = new Date()): string { return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`; }
export function currentStreak(library: Library): number {
  const date = new Date(); let streak = 0;
  const completed = new Set(library.completedReadingDays || []);
  const reached = () => completed.has(localDay(date)) || (library.readingHistory[localDay(date)] || 0) >= library.goalMinutes * 60;
  if (!reached()) date.setDate(date.getDate() - 1);
  while (reached()) { streak++; date.setDate(date.getDate() - 1); }
  return streak;
}
export function locatorFromMessage(session: ReaderSession, message: ReaderMessage): Locator {
  return { ...message.locator, kind: session.kind, spineIndex: message.spineIndex ?? session.spineIndex,
    start: message.locator?.start ?? message.position ?? message.start ?? { elementPath: [], offset: 0 }, text: message.text ?? message.locator?.text };
}
export function newAnnotation(session: ReaderSession, message: ReaderMessage, color = 'yellow'): Annotation {
  return { id: uuid(), locator: locatorFromMessage(session, message), text: message.text || '', note: null, color,
    createdAt: now(), modifiedAt: now(), sketches: [], audioRecordings: [] };
}
export function isLibraryBook(book: Book): boolean { return book.removedFromLibrary !== true; }
export function matchingBooks(books: Book[], query: string, filter: string, sort: string, descending: boolean): Book[] {
  const normalized = query.trim().toLocaleLowerCase();
  return books.filter(book => isLibraryBook(book) && (!normalized || `${book.title}\n${book.author}`.toLocaleLowerCase().includes(normalized)) &&
    (filter === 'all' || filter === 'recent' && book.lastOpenedAt >= now() - 7 * 86400 || filter === 'unread' && book.progress <= 0 ||
      filter === 'progress' && book.progress > 0 && book.progress < 0.99 || filter === 'finished' && book.progress >= 0.99))
    .sort((a, b) => {
      const order = sort === 'title' ? a.title.localeCompare(b.title) : sort === 'added' ? a.addedAt - b.addedAt : a.lastOpenedAt - b.lastOpenedAt;
      return (descending ? -order : order) || a.id.localeCompare(b.id);
    });
}
