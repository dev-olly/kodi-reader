import { lazy, Suspense, useCallback, useEffect, useRef, useState } from 'react';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { AlertCircle, BookOpen, Check, ChevronRight, FileText, Flame, Link, LoaderCircle, Plus, Search, Settings, X } from 'lucide-react';
import { useLibrary } from './hooks/useLibrary';
import { flushEditors, registerEditor } from './editorLifecycle';
import { openReaderPublication, pdfPageTarget, resolveEpubHref, runReaderCommand } from './readerLifecycle';
import { chooseDocuments, chooseExport, command, describeError, isNative, subscribe } from './native';
import { currentStreak, localDay, locatorFromMessage, newAnnotation, now, uuid } from './model';
import type { Annotation, AudioState, Book, ChatThread, ExportFormat, Inspector, Library, Locator, Publication, ReaderActionOutcome, ReaderEvent, ReaderMessage, ReaderSession, ReaderSettings, Reminder, Route } from './types';
import { IconButton, Modal, Spinner } from './components/Primitives';

const LibraryView = lazy(() => import('./components/LibraryView').then(module => ({ default: module.LibraryView })));
const ReaderView = lazy(() => import('./components/ReaderView').then(module => ({ default: module.ReaderView })));
const GlobalNotes = lazy(() => import('./components/NotesPanel').then(module => ({ default: module.GlobalNotes })));
const RemindersView = lazy(() => import('./components/RemindersView').then(module => ({ default: module.RemindersView })));
const SettingsView = lazy(() => import('./components/SettingsView').then(module => ({ default: module.SettingsView })));

type Dialog = { type: 'url' } | { type: 'rename' | 'delete'; book: Book } | { type: 'reminder'; bookId: string; locator: Locator; annotationId?: string; reminderId?: string } | null;
interface OpenOptions { locator?: Locator; noteId?: string; reference?: boolean; fragment?: string; chapterEnd?: boolean }

export function App() {
  const { library, latest, loading, error, setError, accept, run, mutateBook, libraryCommand } = useLibrary();
  const [route, setRoute] = useState<Route>('library');
  const [session, setSession] = useState<ReaderSession | null>(null);
  const [publication, setPublication] = useState<Publication | null>(null);
  const [inspector, setInspector] = useState<Inspector>(null);
  const [noteId, setNoteId] = useState<string | null>(null);
  const [selection, setSelection] = useState<ReaderMessage | null>(null);
  const [page, setPage] = useState(0);
  const [pageCount, setPageCount] = useState(1);
  const [opening, setOpening] = useState(false);
  const [transitionMessage, setTransitionMessage] = useState('Opening your book…');
  const [dialog, setDialog] = useState<Dialog>(null);
  const [draft, setDraft] = useState('');
  const [dialogBusy, setDialogBusy] = useState(false);
  const dialogSubmission = useRef(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [reminderCompleted, setReminderCompleted] = useState(false);
  const [deleteData, setDeleteData] = useState(false);
  const [toast, setToast] = useState('');
  const [audio, setAudio] = useState<AudioState>({});
  const [referenceStack, setReferenceStack] = useState<Locator[]>([]);
  const currentSession = useRef<ReaderSession | null>(null);
  const currentDialog = useRef(dialog); currentDialog.current = dialog;
  const openEpoch = useRef(0);
  const latestInput = useRef(Date.now());
  const settingsTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const settingsToSave = useRef<{ settings: ReaderSettings; goalMinutes: number } | null>(null);
  const savingSettings = useRef<Promise<void> | null>(null);
  const onError = useCallback((cause: unknown) => setError(describeError(cause)), [setError]);
  const readerAction = useCallback((target: ReaderSession, action: string, payload: unknown = null) => {
    const epoch = openEpoch.current;
    return runReaderCommand(
      () => command<ReaderActionOutcome>('reader_action', { sessionId: target.sessionId, action, payload }),
      () => epoch === openEpoch.current && currentSession.current?.sessionId === target.sessionId && currentSession.current?.documentId === target.documentId,
    );
  }, []);
  const activeBook = session ? library.books[session.bookId] : null;
  const openExistingReminder = useCallback((id: string) => {
    const current = currentSession.current;
    const book = current ? latest.current.books[current.bookId] : null;
    const reminder = book?.reminders.find(item => item.id.toLowerCase() === id.toLowerCase());
    if (!book || !reminder) throw new Error('This research reminder is no longer available.');
    setDraft(reminder.title); setReminderCompleted(reminder.completed);
    setDialog({ type: 'reminder', bookId: book.id, locator: reminder.locator, annotationId: reminder.annotationId || undefined, reminderId: reminder.id });
  }, [latest]);

  useEffect(() => {
    const media = matchMedia('(prefers-color-scheme: dark)');
    const update = () => { document.documentElement.dataset.theme = library.settings.theme === 'system' ? media.matches ? 'dark' : 'light' : library.settings.theme; };
    update(); media.addEventListener('change', update); return () => media.removeEventListener('change', update);
  }, [library.settings.theme]);
  useEffect(() => { if (!toast) return; const timer = setTimeout(() => setToast(''), 5000); return () => clearTimeout(timer); }, [toast]);
  useEffect(() => { setDialogError(null); }, [dialog]);
  useEffect(() => {
    if (!isNative()) return;
    let alive = true;
    let unlisten: (() => void) | undefined;
    getCurrentWebview().onDragDropEvent(event => {
      if (alive && event.payload.type === 'drop') void libraryCommand('import_documents', { paths: event.payload.paths });
    }).then(stop => { if (alive) unlisten = stop; else stop(); }).catch(onError);
    return () => { alive = false; unlisten?.(); };
  }, [libraryCommand, onError]);
  useEffect(() => {
    if (!isNative()) return;
    let alive = true; let stop: (() => void) | undefined; let closing = false;
    getCurrentWindow().onCloseRequested(async event => {
      event.preventDefault();
      if (closing) return;
      closing = true;
      setTransitionMessage('Saving your changes…'); setOpening(true);
      try { await flushEditors(); await getCurrentWindow().destroy(); }
      catch (cause) { closing = false; setOpening(false); onError(cause); }
    }).then(unlisten => { if (alive) stop = unlisten; else unlisten(); }).catch(onError);
    return () => { alive = false; stop?.(); };
  }, [onError]);
  useEffect(() => {
    const updateInput = () => { latestInput.current = Date.now(); };
    for (const name of ['pointerdown', 'keydown', 'wheel'] as const) window.addEventListener(name, updateInput, { passive: true });
    const interval = setInterval(() => {
      if (!currentSession.current || currentDialog.current || document.visibilityState !== 'visible' || Date.now() - latestInput.current > 300000 || !isNative()) return;
      void getCurrentWindow().isFocused().then(focused => {
        if (focused) return command<Library>('read_activity', { seconds: 15 }).then(accept);
      }).catch(() => {});
    }, 15000);
    return () => { clearInterval(interval); for (const name of ['pointerdown', 'keydown', 'wheel'] as const) window.removeEventListener(name, updateInput); };
  }, [accept]);

  const openBook = useCallback(async (book: Book, options: OpenOptions = {}) => {
    const epoch = ++openEpoch.current;
    setTransitionMessage('Opening your book…'); setOpening(true); setSelection(null); setPage(0); setPageCount(1);
    try {
      await flushEditors();
      if (epoch !== openEpoch.current) return;
      const opened = await openReaderPublication(
        () => command<ReaderSession>('open_book', { bookId: book.id, spineIndex: options.locator?.spineIndex ?? book.position?.spineIndex ?? 0, initialLocator: options.locator ? { ...options.locator, ...(options.chapterEnd ? { desktopChapterEnd: true } : {}) } : null, fragment: options.fragment || null }),
        () => command<Publication>('publication_get', { bookId: book.id }),
        () => epoch === openEpoch.current,
      );
      if (!opened) return;
      const next = opened.session; const nextPublication = opened.publication;
      setSession(next); currentSession.current = next; setPublication(nextPublication); latestInput.current = Date.now();
      if (options.noteId) { setInspector('notes'); setNoteId(options.noteId); }
      else setNoteId(null);
      // If ready arrived before the session/publication replies, recover its
      // page count now; otherwise the runtime's normal ready path reports it.
      void readerAction(next, 'notifyState').catch(onError);
    } catch (cause) { if (epoch === openEpoch.current) onError(cause); }
    finally { if (epoch === openEpoch.current) setOpening(false); }
  }, [onError, readerAction]);
  const openRef = useRef(openBook); openRef.current = openBook;
  useEffect(() => {
    let alive = true;
    const events = [
      subscribe<ReaderEvent>('reader-event', event => {
        const current = currentSession.current;
        if (!alive || !current || event.sessionId !== current.sessionId || event.bookId !== current.bookId || event.documentId !== current.documentId) return;
        const message = event.message;
        if (['pageChanged', 'selection', 'readingMarkerPlaced', 'activity'].includes(message.type)) latestInput.current = Date.now();
        if (message.type === 'pageChanged') {
          setPage(message.page || 0); setPageCount(message.pageCount || 1);
          if (current.kind === 'pdf' && Number.isInteger(message.spineIndex) && Number.isInteger(message.pageCount) && (message.spineIndex ?? -1) >= 0 && (message.spineIndex ?? 0) < (message.pageCount ?? 0)) {
            const next = { ...current, spineIndex: message.spineIndex!, totalSpines: message.pageCount! };
            currentSession.current = next; setSession(next);
          }
        }
        if (message.type === 'selection') setSelection(message);
        // Keep the captured quote while chrome resizing or note/AI focus clears
        // the native DOM selection. Dismiss and navigation clear it explicitly.
        if (message.type === 'highlightTapped' && message.id) { void flushEditors().then(() => { setInspector('notes'); setNoteId(message.id!); setSelection(null); }).catch(onError); }
        if (message.type === 'reminderTapped' && message.id) {
          const book = latest.current.books[current.bookId];
          const reminder = book?.reminders.find(item => item.id === message.id);
          if (reminder) { setDraft(reminder.title); setReminderCompleted(reminder.completed); setDialog({ type: 'reminder', bookId: current.bookId, locator: reminder.locator, annotationId: reminder.annotationId || undefined, reminderId: reminder.id }); }
        }
        if (message.type === 'readingMarkerRequested') {
          const book = latest.current.books[current.bookId];
          const marker = book?.readingMarker;
          if (marker) {
            setSelection(null);
            if (marker.spineIndex !== current.spineIndex) void openRef.current(book, { locator: marker });
            else void readerAction(current, 'goToPosition', marker).catch(onError);
          }
        }
        if (message.type === 'reachedEnd' || message.type === 'reachedStart') {
          const index = current.spineIndex + (message.type === 'reachedEnd' ? 1 : -1);
          const book = latest.current.books[current.bookId];
          if (book && index >= 0 && index < current.totalSpines) void openRef.current(book, { locator: { kind: book.kind, spineIndex: index, start: { elementPath: [], offset: 0 } }, chapterEnd: message.type === 'reachedStart' });
        }
        if (message.type === 'error') onError(message.message || 'This part of the document could not be displayed.');
      }),
      subscribe<AudioState>('audio-state', state => { if (alive) { setAudio(state); if (state.error) onError(state.error); } }),
      subscribe<string>('native-error', message => { if (alive) onError(message); }),
      subscribe<ReaderSession>('reader-session', next => {
        const current = currentSession.current;
        if (!alive || !current || next.bookId !== current.bookId || next.kind !== 'epub') return;
        currentSession.current = next; setSession(next); setSelection(null); setPage(0); setPageCount(1);
      }),
    ];
    return () => { alive = false; for (const event of events) void event.then(stop => stop()); };
  }, [latest, onError, readerAction]);

  const clearSelection = useCallback(() => { setSelection(null); if (currentSession.current) void readerAction(currentSession.current, 'clearSelection').catch(onError); }, [onError, readerAction]);
  const closeReader = useCallback(async () => {
    setTransitionMessage('Saving your changes…'); setOpening(true);
    try {
      await flushEditors();
      const current = currentSession.current;
      if (current) await readerAction(current, 'close');
      ++openEpoch.current;
      setSession(null); currentSession.current = null; setPublication(null); setSelection(null); setReferenceStack([]); setOpening(false);
      void command('narration_stop').catch(() => {});
      return true;
    } catch (cause) { setOpening(false); onError(cause); return false; }
  }, [onError, readerAction]);
  const goRoute = (next: Route) => { void (async () => { if (session && !await closeReader()) return; setRoute(next); })(); };
  const importBooks = async () => { await run(async () => { const paths = await chooseDocuments(); if (paths.length) await libraryCommand('import_documents', { paths }); }); };
  const navigate = useCallback((locator: Locator) => {
    const current = currentSession.current;
    const book = current ? latest.current.books[current.bookId] : null;
    if (!current || !book) return;
    setSelection(null);
    if (locator.spineIndex !== current.spineIndex) void openBook(book, { locator });
    else void readerAction(current, 'goToPosition', locator).catch(onError);
  }, [latest, onError, openBook, readerAction]);
  const navigateHref = (href: string, source: 'publication' | 'chapter' = 'publication') => {
    if (!session || !activeBook || !publication) return;
    if (/^https?:/i.test(href)) { void command('open_external', { url: href }).catch(onError); return; }
    if (activeBook.kind === 'pdf') {
      const pageIndex = pdfPageTarget(href, session.totalSpines);
      if (pageIndex === null) { onError('This PDF outline points to an unavailable page.'); return; }
      if (activeBook.position) setReferenceStack(stack => [...stack, activeBook.position!]);
      navigate({ kind: 'pdf', spineIndex: pageIndex, start: { elementPath: [], offset: 0 } });
      return;
    }
    const resolved = resolveEpubHref(href, publication.readingOrder, session.spineIndex, source);
    if (!resolved) { onError('This reference is not in the book’s reading order.'); return; }
    const index = resolved.spineIndex; const fragment = resolved.fragment || undefined;
    if (activeBook.position) setReferenceStack(stack => [...stack, activeBook.position!]);
    void (async () => {
      if (index !== session.spineIndex) { await openBook(activeBook, { locator: { kind: activeBook.kind, spineIndex: index, start: { elementPath: [], offset: 0 } }, reference: true, fragment }); return; }
      const target = currentSession.current;
      if (fragment && target) await readerAction(target, 'goToFragment', fragment);
    })().catch(onError);
  };
  const hrefRef = useRef(navigateHref); hrefRef.current = navigateHref;
  useEffect(() => {
    const listener = subscribe<ReaderEvent>('reader-event', event => {
      const current = currentSession.current;
      if (current && event.sessionId === current.sessionId && event.documentId === current.documentId && event.message.type === 'link' && event.message.href) hrefRef.current(event.message.href, 'chapter');
    });
    return () => { void listener.then(stop => stop()); };
  }, []);

  const highlight = async (color: string, withNote = false) => {
    if (!session || !selection?.text) return;
    const annotation = newAnnotation(session, selection, color);
    const result = await mutateBook(session.bookId, book => ({ ...book, annotations: [...book.annotations, annotation] }));
    if (result) { clearSelection(); if (withNote) { setInspector('notes'); setNoteId(annotation.id); } }
  };
  const updateNote = useCallback((id: string, changes: Partial<Annotation>) => {
    const current = currentSession.current;
    if (!current) return Promise.resolve(undefined);
    return mutateBook(current.bookId, book => ({ ...book, annotations: book.annotations.map(annotation => annotation.id === id ? { ...annotation, ...changes } : annotation) }));
  }, [mutateBook]);
  const addReminder = (title = '', annotation?: Annotation) => {
    if (!session || !activeBook) return;
    const locator = annotation?.locator || (selection ? locatorFromMessage(session, selection) : activeBook.position || { kind: activeBook.kind, spineIndex: session.spineIndex, start: { elementPath: [], offset: 0 } });
    setDraft(title || selection?.text?.slice(0, 90) || ''); setReminderCompleted(false); setDialog({ type: 'reminder', bookId: activeBook.id, locator, annotationId: annotation?.id });
  };
  const saveThread = async (thread: ChatThread) => session ? mutateBook(session.bookId, book => ({ ...book, chats: [...book.chats.filter(item => item.id !== thread.id), thread] })) : undefined;
  const bookmark = async () => {
    if (!activeBook || !session) return;
    const locator = activeBook.position || { kind: activeBook.kind, spineIndex: session.spineIndex, start: { elementPath: [], offset: 0 } };
    await mutateBook(activeBook.id, book => ({ ...book, bookmarks: [...book.bookmarks, { id: uuid(), locator, title: `${book.kind === 'pdf' ? 'Page' : 'Chapter'} ${session.spineIndex + 1} · ${new Date().toLocaleDateString()}`, createdAt: now() }] }));
    setToast('Bookmark saved');
  };
  const exportNotes = async (format: ExportFormat, annotationId?: string) => {
    if (!activeBook) return;
    await run(async () => {
      await flushEditors();
      const extension = format === 'docx' ? 'docx' : format === 'html' ? 'html' : 'md';
      const destination = await chooseExport(`${activeBook.title} — ${annotationId ? 'Note' : 'Notes'}`, extension);
      if (!destination) return;
      await command('export_notes', { bookId: activeBook.id, annotationId: annotationId || null, format, destination }); setToast('Notes exported');
    });
  };
  const flushSettings = useCallback(() => {
    if (savingSettings.current) return savingSettings.current;
    if (settingsTimer.current) { clearTimeout(settingsTimer.current); settingsTimer.current = null; }
    savingSettings.current = (async () => {
      while (settingsToSave.current) {
        const args = settingsToSave.current;
        const next = await command<Library>('settings_save', args);
        accept(next);
        if (settingsToSave.current === args) settingsToSave.current = null;
      }
    })().finally(() => { savingSettings.current = null; });
    return savingSettings.current;
  }, [accept]);
  useEffect(() => registerEditor(flushSettings), [flushSettings]);
  const saveSettings = useCallback((settings: ReaderSettings, goalMinutes?: number) => {
    const goal = goalMinutes ?? latest.current.goalMinutes;
    accept({ ...latest.current, settings, goalMinutes: goal }); settingsToSave.current = { settings, goalMinutes: goal };
    if (settingsTimer.current) clearTimeout(settingsTimer.current);
    settingsTimer.current = setTimeout(() => { void flushSettings().catch(onError); }, 250);
  }, [accept, latest, flushSettings, onError]);
  const toggleReminder = (book: Book, reminder: Reminder) => { void mutateBook(book.id, current => ({ ...current, reminders: current.reminders.map(item => item.id === reminder.id ? { ...item, completed: !item.completed, modifiedAt: now() } : item) })); };
  const deleteReminder = (book: Book, reminder: Reminder) => { void mutateBook(book.id, current => ({ ...current, reminders: current.reminders.filter(item => item.id !== reminder.id) })); };
  const submitDialog = async () => {
    if (!dialog || dialogSubmission.current) return;
    dialogSubmission.current = true; setDialogBusy(true); setDialogError(null);
    try {
      if (dialog.type === 'url') { const url = new URL(draft.trim()); if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Enter an HTTP or HTTPS webpage address.'); const next = await command<Library>('source_url_import', { url: url.toString() }); accept(next); }
      if (dialog.type === 'rename') { const title = draft.trim(); if (!title) throw new Error('Enter a document title.'); const next = await command<Library>('book_rename', { bookId: dialog.book.id, title }); accept(next); }
      if (dialog.type === 'delete') { const next = await command<Library>('book_delete', { bookId: dialog.book.id, deleteData }); accept(next); }
      if (dialog.type === 'reminder') {
        const title = draft.trim(); if (!title) throw new Error('Enter a research topic.');
        const previous = latest.current.books[dialog.bookId]?.reminders.find(item => item.id === dialog.reminderId);
        const reminder: Reminder = { ...previous, id: dialog.reminderId || uuid(), locator: dialog.locator, title, completed: dialog.reminderId ? reminderCompleted : false, createdAt: previous?.createdAt || now(), modifiedAt: now(), annotationId: dialog.annotationId };
        const result = await mutateBook(dialog.bookId, book => ({ ...book, reminders: [...book.reminders.filter(item => item.id !== reminder.id), reminder], annotations: dialog.annotationId && !dialog.reminderId ? book.annotations.map(annotation => annotation.id === dialog.annotationId ? { ...annotation, note: `${annotation.note || ''}\n\n[${title.replace(/[\[\]\\]/g, '\\$&')}](kodi-reminder://${reminder.id})\n`, modifiedAt: now() } : annotation) : book.annotations }));
        if (!result) return; setToast(dialog.reminderId ? 'Research reminder updated' : 'Research reminder added');
      }
      setDialog(null);
    } catch (cause) { setDialogError(describeError(cause)); } finally { dialogSubmission.current = false; setDialogBusy(false); }
  };
  const dismissDialog = () => { if (!dialogSubmission.current) setDialog(null); };
  const books = Object.values(library.books);
  const todayMinutes = Math.floor((library.readingHistory[localDay()] || 0) / 60);
  const openReminders = books.reduce((sum, book) => sum + book.reminders.filter(item => !item.completed).length, 0);
  return <div className={`app-shell${session ? ' reading' : ''}`}>
    {!session ? <aside className="app-sidebar"><button className="brand" onClick={() => goRoute('library')} aria-label="Kodi Reader home"><span className="brand-mark"><img src="/kodi-logo.svg" alt="" /></span><span>Kodi<span className="brand-reader">reader</span></span></button><div className="sidebar-section-label">YOUR SPACE</div><nav className="primary-nav" aria-label="Main navigation">{([{ id: 'library', label: 'Library', icon: BookOpen }, { id: 'notes', label: 'Notes', icon: FileText }, { id: 'reminders', label: 'Reminders', icon: Search }] as const).map(item => <button key={item.id} className={route === item.id ? 'selected' : ''} aria-current={route === item.id ? 'page' : undefined} onClick={() => goRoute(item.id)}><item.icon size={17} /><span>{item.label}</span>{item.id === 'reminders' && openReminders > 0 ? <small>{openReminders}</small> : null}</button>)}</nav><div className="sidebar-spacer" />{library.settings.showReadingGoal ? <div className="sidebar-goal"><span><Flame size={14} />{currentStreak(library)} day streak</span><strong>{todayMinutes}<small> / {library.goalMinutes} min</small></strong><div className="progress-track"><i style={{ width: `${Math.min(100, todayMinutes / library.goalMinutes * 100)}%` }} /></div><p>A few pages make a day.</p></div> : <div className="sidebar-quote"><span>“</span><p>A book is a dream<br />you hold in your hands.</p><small>NEIL GAIMAN</small></div>}<button className={`sidebar-settings${route === 'settings' ? ' selected' : ''}`} onClick={() => goRoute('settings')}><Settings size={17} />Settings</button><div className="sidebar-local"><i />Your library, on this device</div></aside> : null}
    <div className="main-shell" inert={opening}>{!isNative() ? <div className="preview-banner"><AlertCircle size={14} /><span>Interface preview · Open the desktop app to import books and use native features.</span></div> : null}{error ? <div className="error-banner" role="alert"><AlertCircle size={17} /><span>{error}</span><IconButton label="Dismiss error" onClick={() => setError(null)}><X size={16} /></IconButton></div> : null}
    <Suspense fallback={<div className="center-loading"><Spinner label="Opening your reading space…" /></div>}>{session && activeBook ? <ReaderView book={activeBook} library={library} session={session} publication={publication} inspector={inspector} onInspector={next => { void flushEditors().then(() => setInspector(next)).catch(onError); }} selectedNoteId={noteId} onSelectedNote={id => { void flushEditors().then(() => setNoteId(id)).catch(onError); }} selection={selection} onClearSelection={clearSelection} page={page} pageCount={pageCount} obscured={Boolean(dialog) || opening} audio={audio} onClose={closeReader} onNavigate={navigate} onHighlight={(color, note) => void highlight(color, note)} onRemind={addReminder} onOpenReminder={openExistingReminder} onBookmark={() => void bookmark()} onRemoveBookmark={id => { void mutateBook(activeBook.id, book => ({ ...book, bookmarks: book.bookmarks.filter(item => item.id !== id) })); }} onUpdateNote={updateNote} onDeleteNote={id => { void mutateBook(activeBook.id, book => ({ ...book, annotations: book.annotations.filter(item => item.id !== id) })); setNoteId(null); }} onExport={(format, id) => void exportNotes(format, id)} onSettings={saveSettings} onSaveThread={saveThread} onError={onError} onNavigateHref={navigateHref} onSeek={spineIndex => void openBook(activeBook, { locator: { kind: activeBook.kind, spineIndex, start: { elementPath: [], offset: 0 } } })} hasReference={referenceStack.length > 0} onBackReference={() => { const previous = referenceStack.at(-1); if (previous) { setReferenceStack(stack => stack.slice(0, -1)); navigate(previous); } }} /> : route === 'library' ? <LibraryView library={library} loading={loading} onOpen={book => void openBook(book)} onImport={() => void importBooks()} onRename={book => { setDraft(book.title); setDialog({ type: 'rename', book }); }} onDelete={book => { setDeleteData(false); setDialog({ type: 'delete', book }); }} onAddURL={() => { setDraft(''); setDialog({ type: 'url' }); }} /> : route === 'notes' ? <GlobalNotes books={books} onOpen={(book, annotation) => void openBook(book, { locator: annotation.locator, noteId: annotation.id })} /> : route === 'reminders' ? <RemindersView books={books} onToggle={toggleReminder} onDelete={deleteReminder} onEdit={(book, reminder) => { setDraft(reminder.title); setReminderCompleted(reminder.completed); setDialog({ type: 'reminder', bookId: book.id, locator: reminder.locator, annotationId: reminder.annotationId || undefined, reminderId: reminder.id }); }} onOpen={(book, reminder) => void openBook(book, { locator: reminder.locator, noteId: reminder.annotationId || undefined })} /> : <SettingsView library={library} onChange={saveSettings} onError={onError} />}</Suspense>
    {opening ? <div className="opening-overlay" role="status"><LoaderCircle size={25} className="spin" /><span>{transitionMessage}</span></div> : null}
    </div>{toast ? <div className="toast" role="status"><Check size={16} />{toast}<IconButton label="Dismiss notification" onClick={() => setToast('')}><X size={13} /></IconButton></div> : null}
    {dialog ? <Modal title={dialog.type === 'url' ? 'Save a webpage' : dialog.type === 'rename' ? 'Rename document' : dialog.type === 'delete' ? 'Remove document' : dialog.type === 'reminder' && dialog.reminderId ? 'Edit research reminder' : 'Add research reminder'} onClose={dismissDialog}><form onSubmit={event => { event.preventDefault(); void submitDialog(); }}><div className="modal-content">{dialogError ? <p className="dialog-error" role="alert">{dialogError}</p> : null}{dialog.type === 'delete' ? <><p>Remove <strong>{dialog.book.title}</strong> from your library on this device?</p><label className="toggle-setting delete-data-choice"><span>Also delete its reading data<small>Deletes its notes, highlights, and synced record. Existing research reminders are removed with the book.</small></span><input type="checkbox" disabled={dialogBusy} checked={deleteData} onChange={event => setDeleteData(event.target.checked)} /></label>{!deleteData ? <p className="setting-help">Your notes and reading data are kept. You can import the same file again to return to them.</p> : null}</> : <><label className="field-label">{dialog.type === 'url' ? 'Webpage address' : dialog.type === 'rename' ? 'Title' : 'What would you like to research?'}<input autoFocus required type={dialog.type === 'url' ? 'url' : 'text'} value={draft} onChange={event => setDraft(event.target.value)} placeholder={dialog.type === 'url' ? 'https://…' : dialog.type === 'reminder' ? 'A question to come back to…' : ''} /></label>{dialog.type === 'url' ? <p className="setting-help">The article is converted locally into a book for offline reading.</p> : dialog.type === 'reminder' && dialog.locator.text ? <blockquote className="reminder-context">{dialog.locator.text}</blockquote> : null}{dialog.type === 'reminder' && dialog.reminderId ? <label className="toggle-setting"><span>Completed</span><input type="checkbox" checked={reminderCompleted} onChange={event => setReminderCompleted(event.target.checked)} /></label> : null}</>}</div><div className="modal-actions"><button type="button" className="button" disabled={dialogBusy} onClick={dismissDialog}>Cancel</button><button type="submit" className={`button ${dialog.type === 'delete' && deleteData ? 'danger' : 'primary'}`} disabled={dialogBusy}>{dialogBusy ? <Spinner label="Working…" /> : dialog.type === 'url' ? 'Save for reading' : dialog.type === 'delete' ? 'Remove document' : dialog.type === 'rename' ? 'Save title' : dialog.type === 'reminder' && dialog.reminderId ? 'Save reminder' : 'Add reminder'}</button></div></form></Modal> : null}
  </div>;
}
