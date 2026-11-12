export type DocumentKind = 'epub' | 'pdf';
export type Theme = 'light' | 'sepia' | 'dark' | 'system';
export interface TextPosition { elementPath: number[]; offset: number }
export interface Locator {
  kind: DocumentKind; spineIndex: number; start: TextPosition; end?: TextPosition | null;
  text?: string | null; totalProgression?: number | null; pdfAnchors?: unknown;
  [key: string]: unknown;
}
export interface Sketch { id: string; title?: string; createdAt?: number; modifiedAt?: number; [key: string]: unknown }
export interface AudioNote { id: string; title?: string; duration?: number; createdAt?: number; transcript?: string | null; path?: string; waveform?: number[]; [key: string]: unknown }
export interface Annotation {
  id: string; locator: Locator; text: string; note?: string | null; color: string;
  chapterTitle?: string | null; createdAt: number; modifiedAt: number;
  sketches: Sketch[]; audioRecordings: AudioNote[]; [key: string]: unknown;
}
export interface Bookmark { id: string; locator: Locator; title: string; createdAt: number }
export interface Reminder { id: string; locator: Locator; title: string; completed: boolean; createdAt: number; modifiedAt: number; annotationId?: string | null; [key: string]: unknown }
export interface ChatMessage { id?: string; role: 'user' | 'assistant'; text: string; createdAt?: number; references?: unknown[]; [key: string]: unknown }
export interface ChatThread { id: string; title: string; messages: ChatMessage[]; createdAt: number; modifiedAt: number; [key: string]: unknown }
export interface Book {
  id: string; kind: DocumentKind; title: string; author: string; importedRelativePath: string;
  coverPath?: string | null; addedAt: number; lastOpenedAt: number; progress: number;
  position?: Locator | null; annotations: Annotation[]; bookmarks: Bookmark[]; reminders: Reminder[];
  chats: ChatThread[]; readingMarker?: Locator | null; sourceUrl?: string | null;
  removedFromLibrary?: boolean;
  [key: string]: unknown;
}
export interface ReaderSettings {
  theme: Theme; fontFamily: string; fontSize: number; lineHeight: number; margin: number;
  twoPageSpread: boolean; showReadingGoal: boolean; analyticsEnabled: boolean;
  [key: string]: unknown;
}
export interface Library {
  schemaVersion: number; books: Record<string, Book>; settings: ReaderSettings;
  readingHistory: Record<string, number>; goalMinutes: number; deviceId: string;
  completedReadingDays?: string[];
  [key: string]: unknown;
}
export interface TocEntry { title: string; href: string; children: TocEntry[] }
export interface Publication { title: string; author: string; readingOrder: { href: string; mediaType: string; title?: string | null }[]; toc: TocEntry[]; coverHref?: string | null }
export type ReaderActionOutcome = 'applied' | 'superseded';
export interface ReaderSession { sessionId: string; bookId: string; documentId: string; url: string; kind: DocumentKind; spineIndex: number; totalSpines: number }
export interface ReaderMessage {
  type: string; text?: string; id?: string; spineIndex?: number; page?: number; pageCount?: number;
  progression?: number; position?: TextPosition; locator?: Partial<Locator>; start?: TextPosition;
  rect?: { x: number; y: number; width: number; height: number }; href?: string;
  message?: string; title?: string; results?: unknown[]; [key: string]: unknown;
}
export interface ReaderEvent { sessionId: string; bookId: string; documentId: string; message: ReaderMessage }
export type Route = 'library' | 'notes' | 'reminders' | 'settings';
export type Inspector = 'notes' | 'contents' | 'ai' | 'appearance' | null;
export interface AuthStatus { configured?: boolean; signedIn?: boolean; email?: string | null; userId?: string | null; secureStorage?: boolean; paymentsEnabled?: boolean; [key: string]: unknown }
export interface DriveStatus { connected?: boolean; email?: string | null; phase?: string; message?: string | null; mode?: 'notesOnly' | 'booksAndNotes'; syncAIHistory?: boolean; lastSuccessfulSync?: number; [key: string]: unknown }
export interface AudioState { phase?: string; kind?: 'narration'; hasEstimatedDuration?: boolean; passageIndex?: number; voice?: string; rate?: number; recording?: boolean; paused?: boolean; duration?: number; elapsed?: number; error?: string | null; title?: string; [key: string]: unknown }
export interface ModelStatus { kind: string; installed: boolean; downloading?: boolean; progress?: number; size?: number; [key: string]: unknown }
export type ExportFormat = 'markdown' | 'html' | 'docx' | 'notion';
