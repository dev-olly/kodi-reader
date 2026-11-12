import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ArrowLeft, Bookmark, Check, ChevronLeft, ChevronRight, FileText, Headphones, List, MapPin, Pause, Play, RotateCcw, RotateCw, Search, Sparkles, Trash2, Type, X } from 'lucide-react';
import { command } from '../native';
import { runReaderCommand } from '../readerLifecycle';
import { readPreference, savePreference } from '../preferences';
import { focusRangeControl, ownsKeyboardInput } from '../inputFocus';
import { HIGHLIGHTS, duration, locatorFromMessage, narrationPlaybackAction, percent } from '../model';
import type { Annotation, AudioState, Book, ExportFormat, Inspector, Library, Publication, ReaderActionOutcome, ReaderMessage, ReaderSession, ReaderSettings, TocEntry } from '../types';
import { AIPanel } from './AIPanel';
import { AppearanceControls } from './SettingsView';
import { NoteEditor, NoteList } from './NotesPanel';
import { IconButton } from './Primitives';

function TocTree({ entries, onNavigate, depth = 0 }: { entries: TocEntry[]; onNavigate: (href: string) => void; depth?: number }) {
  return <ol className="toc-list">{entries.map((entry, index) => <li key={`${entry.href}:${index}`}><button style={{ paddingLeft: `${18 + depth * 15}px` }} onClick={() => onNavigate(entry.href)}>{entry.title || 'Untitled section'}</button>{entry.children?.length ? <TocTree entries={entry.children} onNavigate={onNavigate} depth={depth + 1} /> : null}</li>)}</ol>;
}

export function ReaderView({ book, library, session, publication, inspector, onInspector, selectedNoteId, onSelectedNote, selection, onClearSelection, page, pageCount, obscured, audio: playbackAudio,
  onClose, onNavigate, onHighlight, onRemind, onOpenReminder, onBookmark, onRemoveBookmark, onUpdateNote, onDeleteNote, onExport, onSettings, onSaveThread, onError, onNavigateHref, onSeek, onBackReference, hasReference,
}: {
  book: Book; library: Library; session: ReaderSession; publication: Publication | null; inspector: Inspector; onInspector: (inspector: Inspector) => void;
  selectedNoteId: string | null; onSelectedNote: (id: string | null) => void; selection: ReaderMessage | null; onClearSelection: () => void;
  page: number; pageCount: number; obscured: boolean; audio: AudioState; onClose: () => void;
  onNavigate: (locator: Annotation['locator']) => void; onHighlight: (color: string, withNote?: boolean) => void; onRemind: (title?: string, annotation?: Annotation) => void; onOpenReminder: (id: string) => Promise<void> | void; onBookmark: () => void; onRemoveBookmark: (id: string) => void;
  onUpdateNote: (id: string, changes: Partial<Annotation>) => Promise<unknown>; onDeleteNote: (id: string) => void; onExport: (format: ExportFormat, annotationId?: string) => void;
  onSettings: (settings: ReaderSettings) => void; onSaveThread: React.ComponentProps<typeof AIPanel>['onSaveThread']; onError: (error: unknown) => void;
  onNavigateHref: (href: string) => void; onSeek: (spine: number) => void; onBackReference: () => void; hasReference: boolean;
}) {
  const viewport = useRef<HTMLDivElement>(null);
  const audio = playbackAudio.kind === 'narration' ? playbackAudio : {};
  const [narrationOpen, setNarrationOpen] = useState(false);
  const [voice, setVoice] = useState(() => readPreference('kodi-desktop.narration-voice', ['anna', 'azelma', 'charles', 'george'], 'anna'));
  const [rate, setRate] = useState(() => Number(readPreference('kodi-desktop.narration-rate', ['0.75', '1', '1.25', '1.5', '1.75', '2'], '1')));
  const narrationPreferences = useRef({ voice, rate });
  const narrationChanges = useRef<Promise<unknown>>(Promise.resolve());
  const narrationEpoch = useRef(0);
  const [pdfZoom, setPdfZoom] = useState('fit');
  const [narrationSeek, setNarrationSeek] = useState<number | null>(null);
  const pendingNarrationSeek = useRef<number | null>(null);
  useEffect(() => { savePreference('kodi-desktop.narration-voice', voice); savePreference('kodi-desktop.narration-rate', String(rate)); }, [voice, rate]);
  const annotation = book.annotations.find(item => item.id === selectedNoteId);
  const activeReader = useRef<{ session: ReaderSession; enabled: boolean } | null>(null);
  useLayoutEffect(() => {
    activeReader.current = { session, enabled: !obscured };
    return () => { activeReader.current = null; };
  }, [session, obscured]);
  const action = useCallback((name: string, payload: unknown = null) => runReaderCommand(
    () => command<ReaderActionOutcome>('reader_action', { sessionId: session.sessionId, action: name, payload }),
    () => !obscured && activeReader.current?.enabled === true && activeReader.current.session.sessionId === session.sessionId && activeReader.current.session.documentId === session.documentId,
  ), [session.sessionId, session.documentId, obscured]);
  useLayoutEffect(() => {
    const element = viewport.current;
    if (!element) return;
    let frame = 0;
    const update = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const rect = element.getBoundingClientRect();
        void command('reader_bounds', { sessionId: session.sessionId, bounds: obscured ? { x: 0, y: 0, width: 0, height: 0 } : { x: rect.x, y: rect.y, width: rect.width, height: rect.height } }).catch(onError);
      });
    };
    const resize = new ResizeObserver(update); resize.observe(element);
    window.addEventListener('resize', update); update();
    return () => { resize.disconnect(); window.removeEventListener('resize', update); cancelAnimationFrame(frame); };
  }, [session.sessionId, inspector, selection?.text, narrationOpen, obscured, onError]);
  useEffect(() => () => { void command('reader_bounds', { sessionId: session.sessionId, bounds: { x: 0, y: 0, width: 0, height: 0 } }).catch(() => {}); }, [session.sessionId]);
  useEffect(() => {
    const localAnnotations = book.kind === 'pdf' ? book.annotations : book.annotations.filter(item => item.locator.spineIndex === session.spineIndex);
    const highlights = localAnnotations.map(item => ({ id: item.id, text: item.text, start: item.locator.start, end: item.locator.end,
      color: HIGHLIGHTS.find(color => color.id === item.color)?.css || '#efd279', style: item.color === 'underline' ? 'underline' : 'fill', hasNote: Boolean(item.note || item.sketches?.length || item.audioRecordings?.length), locator: item.locator }));
    void action('setHighlights', highlights).catch(onError);
    void action('setReminders', book.reminders.filter(item => !item.completed && (book.kind === 'pdf' || item.locator.spineIndex === session.spineIndex)).map(item => ({ id: item.id, start: item.locator.start, end: item.locator.end, text: item.locator.text, locator: item.locator }))).catch(onError);
    void action('setReadingMarker', book.kind === 'pdf' || book.readingMarker?.spineIndex === session.spineIndex ? book.readingMarker : null).catch(onError);
  }, [action, book.annotations, book.reminders, book.readingMarker, session.spineIndex, onError]);
  useEffect(() => {
    const settings = library.settings;
    const media = matchMedia('(prefers-color-scheme: dark)');
    const configure = () => {
      const dark = settings.theme === 'dark' || settings.theme === 'system' && media.matches;
      const sepia = settings.theme === 'sepia';
      void action('configure', { marginX: settings.margin, marginY: 42, twoPageSpread: settings.twoPageSpread,
        ...(book.kind === 'pdf' ? { zoom: pdfZoom === 'fit' ? 'fit' : Number(pdfZoom) } : {}), variables: {
      '--color-background': dark ? '#202621' : sepia ? '#f3ebdb' : '#faf9f5', '--color-text': dark ? '#dce3dc' : '#2c342e',
      '--color-surface': dark ? '#29332b' : sepia ? '#eee4d2' : '#f0f5f1', '--color-link': dark ? '#a8c096' : '#47674c',
      '--font-family': settings.fontFamily, '--font-size': `${settings.fontSize}px`, '--line-height': `${settings.lineHeight}`,
      }, fontFamily: settings.fontFamily, fontSize: settings.fontSize, lineHeight: settings.lineHeight }).catch(onError);
    };
    configure();
    if (settings.theme === 'system') media.addEventListener('change', configure);
    return () => media.removeEventListener('change', configure);
  }, [action, book.kind, pdfZoom, library.settings.theme, library.settings.fontFamily, library.settings.fontSize, library.settings.lineHeight, library.settings.margin, library.settings.twoPageSpread, onError]);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (ownsKeyboardInput(event.target) || obscured) return;
      if (event.key === 'Escape') { onClearSelection(); return; }
      if (event.key.toLowerCase() === 'm' && !event.ctrlKey && !event.metaKey && !event.altKey) {
        event.preventDefault();
        if (event.shiftKey && book.readingMarker) onNavigate(book.readingMarker);
        else void action('setReadingMarkerPlacement', true).catch(onError);
      }
      if (event.key === 'ArrowRight') { event.preventDefault(); void action('nextPage').catch(onError); }
      if (event.key === 'ArrowLeft') { event.preventDefault(); void action('previousPage').catch(onError); }
    };
    window.addEventListener('keydown', onKey); return () => window.removeEventListener('keydown', onKey);
  }, [action, book.readingMarker, obscured, onNavigate, onClearSelection, onError]);
  const changeNarration = (next: { voice: string; rate: number }) => {
    narrationPreferences.current = next;
    setVoice(next.voice); setRate(next.rate);
    const target = session; const epoch = narrationEpoch.current;
    // Keep rapid voice/speed changes in order and discard controls belonging
    // to a chapter that has since been replaced.
    narrationChanges.current = narrationChanges.current.catch(() => {}).then(async () => {
      await runReaderCommand(() => command('narration_update', { sessionId: target.sessionId, ...next }),
        () => epoch === narrationEpoch.current && activeReader.current?.session.documentId === target.documentId && activeReader.current.session.sessionId === target.sessionId);
    }).catch(onError);
  };
  const seekNarration = (position: { seconds?: number; delta?: number }) => {
    const target = session; const epoch = narrationEpoch.current;
    narrationChanges.current = narrationChanges.current.catch(() => {}).then(async () => {
      await runReaderCommand(() => command('narration_seek', { sessionId: target.sessionId, ...position }),
        () => epoch === narrationEpoch.current && activeReader.current?.session.documentId === target.documentId && activeReader.current.session.sessionId === target.sessionId);
    }).catch(onError);
    return narrationChanges.current;
  };
  const commitNarrationSeek = () => {
    const seconds = pendingNarrationSeek.current;
    if (seconds === null) return;
    pendingNarrationSeek.current = null;
    setNarrationSeek(null);
    void seekNarration({ seconds });
  };
  const canSeekNarration = audio.kind === 'narration' && (audio.duration || 0) > 0 && ['playing', 'paused', 'preparing'].includes(audio.phase || '');
  const playbackAction = narrationPlaybackAction(playbackAudio);
  const toggleNarrationPlayback = () => {
    if (playbackAction === 'start') ++narrationEpoch.current;
    const epoch = narrationEpoch.current;
    return runReaderCommand(() => playbackAction === 'pause' ? command('narration_pause', { sessionId: session.sessionId, paused: true })
      : playbackAction === 'resume' ? command('narration_pause', { sessionId: session.sessionId, paused: false })
      : command('narration_start', { sessionId: session.sessionId, voice, rate }),
    () => epoch === narrationEpoch.current && activeReader.current?.session.documentId === session.documentId && activeReader.current.session.sessionId === session.sessionId).catch(onError);
  };
  const toggleInspector = (next: Inspector) => onInspector(inspector === next ? null : next);
  return <section className="reader-workspace"><header className="reader-toolbar"><IconButton label="Back to library" onClick={onClose}><ArrowLeft size={18} /></IconButton><div className="toolbar-divider" /><IconButton label="Table of contents" active={inspector === 'contents'} onClick={() => toggleInspector('contents')}><List size={18} /></IconButton><div className="reader-title"><strong>{book.title}</strong><span>{book.author || 'Unknown author'}</span></div>{book.kind === 'pdf' ? <select aria-label="PDF zoom" className="pdf-zoom" value={pdfZoom} onChange={event => { setPdfZoom(event.target.value); }}><option value="fit">Fit page</option>{[0.75, 1, 1.25, 1.5, 2].map(value => <option key={value} value={value}>{value * 100}%</option>)}</select> : null}<IconButton label="Reading appearance" active={inspector === 'appearance'} onClick={() => toggleInspector('appearance')}><Type size={18} /></IconButton><IconButton label="Bookmark this page" onClick={onBookmark}><Bookmark size={17} /></IconButton><IconButton label="Add research reminder for this page" onClick={() => onRemind()}><Search size={16} /></IconButton><IconButton label="Reading marker" onClick={() => void action('setReadingMarkerPlacement', true).catch(onError)}><MapPin size={17} /></IconButton><IconButton label={book.kind === 'epub' ? 'Listen to this book' : 'Read aloud is available for EPUB books'} disabled={book.kind === 'pdf'} active={narrationOpen} onClick={() => setNarrationOpen(!narrationOpen)}><Headphones size={18} /></IconButton><div className="toolbar-divider" /><IconButton label="Notes and highlights" active={inspector === 'notes'} onClick={() => toggleInspector('notes')}><FileText size={17} /></IconButton><button className={`ask-ai-button${inspector === 'ai' ? ' selected' : ''}`} onClick={() => toggleInspector('ai')}><Sparkles size={15} />Ask AI</button></header>
    <div className="reader-body"><main className="reading-column">{hasReference ? <div className="reference-return"><button onClick={onBackReference}><ArrowLeft size={12} />Back to reading</button></div> : null}<div className="native-reader-slot" ref={viewport} aria-label={`${book.kind.toUpperCase()} reading area`}><div className="reader-preparing">Opening your document…</div></div>
      {selection?.text ? <div className="selection-toolbar" role="region" aria-label="Selected passage actions"><span className="selection-snippet">“{selection.text.slice(0, 65)}{selection.text.length > 65 ? '…' : ''}”</span><div className="selection-swatches">{HIGHLIGHTS.map(color => <button key={color.id} className={`swatch${color.id === 'underline' ? ' underline' : ''}`} style={{ background: color.css }} aria-label={`Highlight ${color.label.toLowerCase()}`} onClick={() => onHighlight(color.id)}>{color.id === 'underline' ? 'U' : null}</button>)}</div><button className="selection-action" onClick={() => onHighlight('yellow', true)}><FileText size={14} />Note</button><button className="selection-action" onClick={() => onRemind()}><Search size={14} />Remind</button>{book.kind === 'epub' ? <IconButton label="Listen from here" onClick={() => { setNarrationOpen(true); void command('narration_start', { sessionId: session.sessionId, voice, rate, locator: locatorFromMessage(session, selection) }).catch(onError); }}><Headphones size={15} /></IconButton> : null}<IconButton label="Ask AI about selection" onClick={() => onInspector('ai')}><Sparkles size={15} /></IconButton><IconButton label="Dismiss selection" onClick={onClearSelection}><X size={15} /></IconButton></div> : null}
      <footer className="reader-footer"><IconButton label="Previous page" onClick={() => void action('previousPage').catch(onError)}><ChevronLeft size={17} /></IconButton><div className="reading-location"><span>{publication?.readingOrder[session.spineIndex]?.title || `${book.kind === 'pdf' ? 'Page' : 'Chapter'} ${session.spineIndex + 1}`}</span><small>{book.kind === 'pdf' ? `${session.spineIndex + 1} of ${session.totalSpines}` : `${page + 1} of ${Math.max(1, pageCount)}`}</small></div><input className="reading-progress-slider" type="range" onPointerDown={focusRangeControl} onClick={focusRangeControl} min={0} max={Math.max(0, session.totalSpines - 1)} value={session.spineIndex} step={1} aria-label={book.kind === 'pdf' ? 'Document page' : 'Book chapter'} onChange={event => onSeek(Number(event.target.value))} /><span className="progress-label">{percent(book.progress)}%</span>{book.readingMarker ? <button className="marker-return" onClick={() => onNavigate(book.readingMarker!)} title="Shift+M"><MapPin size={12} />Return to marker</button> : null}<IconButton label="Next page" onClick={() => void action('nextPage').catch(onError)}><ChevronRight size={17} /></IconButton></footer>
      {narrationOpen ? <div className="narration-bar"><span className="narration-art"><Headphones size={20} /></span><div className="narration-title"><strong>{audio.title || book.title}</strong><span>{audio.phase === 'preparing' ? 'Preparing offline speech…' : `${duration(audio.elapsed)} / ${audio.hasEstimatedDuration ? '≈' : ''}${duration(audio.duration)}`}</span><input className="reading-progress-slider" style={{ display: 'block', width: '100%', minWidth: 0, marginTop: 5 }} aria-label="Seek narration" aria-valuetext={`${duration(narrationSeek ?? audio.elapsed)} of ${duration(audio.duration)}`} type="range" onPointerDown={focusRangeControl} onClick={focusRangeControl} min={0} max={Math.max(0.01, audio.duration || 0)} step={0.1} value={Math.min(audio.duration || 0, narrationSeek ?? audio.elapsed ?? 0)} disabled={!canSeekNarration} onChange={event => { const value = Number(event.target.value); pendingNarrationSeek.current = value; setNarrationSeek(value); }} onPointerUp={commitNarrationSeek} onKeyUp={commitNarrationSeek} onBlur={commitNarrationSeek} /></div><IconButton label="Skip back 15 seconds" disabled={!canSeekNarration} onClick={() => void seekNarration({ delta: -15 })}><RotateCcw size={16} /></IconButton><IconButton label={audio.phase === 'playing' || audio.phase === 'preparing' ? 'Pause narration' : 'Play narration'} onClick={() => void toggleNarrationPlayback()}>{audio.phase === 'playing' || audio.phase === 'preparing' ? <Pause size={18} fill="currentColor" /> : <Play size={18} fill="currentColor" />}</IconButton><IconButton label="Skip forward 15 seconds" disabled={!canSeekNarration} onClick={() => void seekNarration({ delta: 15 })}><RotateCw size={16} /></IconButton><select aria-label="Narration voice" value={voice} onChange={event => changeNarration({ ...narrationPreferences.current, voice: event.target.value })}>{['anna', 'azelma', 'charles', 'george'].map(value => <option key={value} value={value}>{value[0].toUpperCase() + value.slice(1)}</option>)}</select><select aria-label="Playback speed" value={rate} onChange={event => changeNarration({ ...narrationPreferences.current, rate: Number(event.target.value) })}>{[0.75, 1, 1.25, 1.5, 1.75, 2].map(value => <option value={value} key={value}>{value}×</option>)}</select><IconButton label="Stop and close narration" onClick={() => { ++narrationEpoch.current; setNarrationOpen(false); void command('narration_stop').catch(onError); }}><X size={16} /></IconButton></div> : null}
    </main>{inspector ? <aside className={`reader-inspector ${inspector}`} aria-label={`${inspector} panel`}><div className="inspector-close"><IconButton label="Close sidebar" onClick={() => onInspector(null)}><X size={16} /></IconButton></div>{inspector === 'contents' ? <><div className="panel-heading"><h2>Contents</h2></div><div className="panel-scroll"><TocTree entries={publication?.toc || []} onNavigate={onNavigateHref} />{book.bookmarks.length ? <><h3 className="sidebar-subheading">Bookmarks</h3>{book.bookmarks.map(mark => <div className="bookmark-item" key={mark.id}><button className="bookmark-row" onClick={() => onNavigate(mark.locator)}><Bookmark size={13} />{mark.title}</button><IconButton label={`Remove bookmark ${mark.title}`} onClick={() => onRemoveBookmark(mark.id)}><Trash2 size={12} /></IconButton></div>)}</> : null}</div></> : inspector === 'appearance' ? <><div className="panel-heading"><h2>Reading appearance</h2></div><div className="panel-padding"><AppearanceControls settings={library.settings} onChange={onSettings} /></div></> : inspector === 'ai' ? <AIPanel book={book} selection={selection} onSaveThread={onSaveThread} onError={onError} /> : annotation ? <NoteEditor key={annotation.id} book={book} annotation={annotation} onUpdate={onUpdateNote} onDelete={onDeleteNote} onBack={() => onSelectedNote(null)} onExport={onExport} onError={onError} onReminder={(title, note) => onRemind(title, note)} onOpenReminder={onOpenReminder} /> : <NoteList book={book} onExport={format => onExport(format)} selectedId={selectedNoteId} onSelect={onSelectedNote} onNavigate={note => onNavigate(note.locator)} />}</aside> : null}</div>
  </section>;
}
