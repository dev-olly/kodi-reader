import { lazy, Suspense, useEffect, useRef, useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ArrowLeft, Bold, Check, Code, Download, FileText, Italic, List, Mic, Pause, Pencil, Play, Plus, Search, Sparkles, Square, Trash2 } from 'lucide-react';
import { command, describeError } from '../native';
import { duration, HIGHLIGHTS, now, uuid } from '../model';
import type { Annotation, AudioNote, Book, ExportFormat, Library, Reminder, Sketch } from '../types';
import type { MarkdownEditorHandle } from './MarkdownEditor';
import { AudioAttachment } from './AudioAttachment';
import { SketchAttachment } from './SketchAttachment';
import { insertAudioTranscript, notePreviewText, noteReferences, removeNoteReference, renameNoteReference } from '../noteMedia';
import { createDraftFlusher, registerEditor } from '../editorLifecycle';
import { ActionMenu, EmptyState, IconButton } from './Primitives';

const MarkdownEditor = lazy(() => import('./MarkdownEditor').then(module => ({ default: module.MarkdownEditor })));

export function MarkdownPreview({ text, onReference }: { text: string; onReference?: (kind: string, id: string) => void }) {
  return <div className="markdown-preview"><ReactMarkdown remarkPlugins={[remarkGfm]} urlTransform={url => /^(https?:|mailto:|kodi-(sketch|audio|reminder):)/i.test(url) || !url.includes(':') ? url : ''} components={{
    a({ href, children }) {
      const match = /^kodi-(sketch|audio|reminder):\/\/([a-f0-9-]+)$/i.exec(href || '');
      if (match) return <button className="attachment-link" onClick={() => onReference?.(match[1], match[2])}>{match[1] === 'sketch' ? <Pencil size={15} /> : match[1] === 'audio' ? <Mic size={15} /> : <Search size={15} />}{children}</button>;
      return <a href={href} onClick={event => { event.preventDefault(); if (href && /^https?:/i.test(href)) void command('open_external', { url: href }); }}>{children}</a>;
    },
    img({ alt }) { return <span className="inline-image-placeholder">{alt || 'Attached image'}</span>; },
  }}>{text}</ReactMarkdown></div>;
}

export function NoteList({ book, selectedId, onSelect, onNavigate, onExport }: { book: Book; selectedId?: string | null; onSelect: (id: string) => void; onNavigate: (annotation: Annotation) => void; onExport?: (format: ExportFormat) => void }) {
  const [query, setQuery] = useState('');
  const notes = [...book.annotations].filter(note => `${note.text} ${note.note || ''}`.toLowerCase().includes(query.toLowerCase())).sort((a, b) => a.locator.spineIndex - b.locator.spineIndex || a.createdAt - b.createdAt);
  return <><div className="panel-heading"><h2>Notes & highlights</h2><span className="count">{book.annotations.length}</span><ActionMenu className="inline-menu" label="Export all notes" trigger={<Download size={13} />}><button onClick={() => onExport?.('markdown')}>Markdown (.md)</button><button onClick={() => onExport?.('docx')}>Word (.docx)</button><button onClick={() => onExport?.('html')}>HTML / Apple Notes</button><button onClick={() => onExport?.('notion')}>Notion (.md)</button></ActionMenu></div><div className="panel-search search-field"><Search size={14} /><input aria-label="Search notes" placeholder="Find a thought…" value={query} onChange={event => setQuery(event.target.value)} /></div>
    {!notes.length ? <EmptyState icon={<FileText size={26} />} title="Keep a thought"><p>Select a passage in your book, then highlight it or add a note.</p></EmptyState> : <div className="annotation-list">{notes.map(annotation => <article className={`annotation-card${selectedId === annotation.id ? ' selected' : ''}`} key={annotation.id} style={{ '--highlight-color': HIGHLIGHTS.find(color => color.id === annotation.color)?.css || HIGHLIGHTS[0].css } as React.CSSProperties}><button className="annotation-main" onClick={() => onSelect(annotation.id)}><span className="annotation-chapter">{annotation.chapterTitle || `${book.kind === 'pdf' ? 'Page' : 'Chapter'} ${annotation.locator.spineIndex + 1}`}</span><blockquote>{annotation.text || 'Page note'}</blockquote>{annotation.note ? <p>{notePreviewText(annotation.note).slice(0, 150)}</p> : null}<div className="annotation-meta">{annotation.sketches?.length ? <span><Pencil size={11} />{annotation.sketches.length}</span> : null}{annotation.audioRecordings?.length ? <span><Mic size={11} />{annotation.audioRecordings.length}</span> : null}<span>{new Date(annotation.modifiedAt * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}</span></div></button><button className="text-button annotation-jump" onClick={() => onNavigate(annotation)}>Go to passage →</button></article>)}</div>}
  </>;
}

export function NoteEditor({ book, annotation, onUpdate, onDelete, onBack, onExport, onError, onReminder, onOpenReminder }: {
  book: Book; annotation: Annotation; onUpdate: (id: string, changes: Partial<Annotation>) => Promise<unknown>;
  onDelete: (id: string) => void; onBack: () => void; onExport: (format: ExportFormat, annotationId?: string) => void;
  onError: (error: unknown) => void; onReminder: (title: string, annotation: Annotation) => Promise<void> | void;
  onOpenReminder?: (id: string) => Promise<void> | void;
}) {
  const [draft, setDraft] = useState(annotation.note || '');
  const [preview, setPreview] = useState(false);
  const [saved, setSaved] = useState(true);
  const [recording, setRecording] = useState(false);
  const [recordingPaused, setRecordingPaused] = useState(false);
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const lifecycle = useRef({ active: true, generation: 0 });
  const pendingAction = useRef<Promise<void> | null>(null);
  const retryAction = useRef<{ label: string; run: () => Promise<void>; saveFirst: boolean; failedText: string } | null>(null);
  const errorCallback = useRef(onError); errorCallback.current = onError;
  const reminderCallback = useRef(onReminder); reminderCallback.current = onReminder;
  const openReminderCallback = useRef(onOpenReminder); openReminderCallback.current = onOpenReminder;
  const recordingRef = useRef(false);
  const finishingRecording = useRef<Promise<void> | null>(null);
  const markdownRef = useRef<MarkdownEditorHandle>(null);
  const pending = useRef(draft); pending.current = draft;
  const savedText = useRef(annotation.note || '');
  const update = useRef(onUpdate); update.current = onUpdate;
  const annotationRef = useRef(annotation); annotationRef.current = annotation;
  const sketchArchive = useRef(new Map(annotation.sketches.map(item => [item.id, item])));
  const audioArchive = useRef(new Map(annotation.audioRecordings.map(item => [item.id, item])));
  const titleOverrides = useRef(new Map<string, string>());
  const mediaRevision = useRef(0);
  const savedMediaRevision = useRef(0);
  const managedReferences = useRef(new Set(noteReferences(annotation.note || '').map(item => `${item.kind}:${item.id}`)));
  const rememberMedia = <T extends Sketch | AudioNote>(kind: string, archive: Map<string, T>, item: T) => {
    const key = `${kind}:${item.id.toLowerCase()}`; const title = titleOverrides.current.get(key);
    if (title !== undefined && item.title !== title) archive.set(item.id, { ...item, title });
    else { archive.set(item.id, item); if (title !== undefined) titleOverrides.current.delete(key); }
  };
  for (const sketch of annotation.sketches) rememberMedia('sketch', sketchArchive.current, sketch);
  for (const audio of annotation.audioRecordings) rememberMedia('audio', audioArchive.current, audio);
  const saveDraft = async (text: string) => {
    const revision = mediaRevision.current;
    const references = new Set(noteReferences(text).map(item => `${item.kind}:${item.id}`));
    for (const key of references) managedReferences.current.add(key);
    const keep = (kind: string, id: string) => references.has(`${kind}:${id.toLowerCase()}`) || !managedReferences.current.has(`${kind}:${id.toLowerCase()}`);
    const result = await update.current(annotation.id, { note: text, sketches: [...sketchArchive.current.values()].filter(item => keep('sketch', item.id)), audioRecordings: [...audioArchive.current.values()].filter(item => keep('audio', item.id)), modifiedAt: now() });
    if (result !== undefined) { savedText.current = text; savedMediaRevision.current = revision; if (pending.current === text && mediaRevision.current === revision && lifecycle.current.active) setSaved(true); }
    return result !== undefined;
  };
  const saveDraftRef = useRef(saveDraft); saveDraftRef.current = saveDraft;
  const draftFlusher = useRef<ReturnType<typeof createDraftFlusher> | null>(null);
  if (!draftFlusher.current) draftFlusher.current = createDraftFlusher(() => pending.current, () => savedText.current, text => saveDraftRef.current(text), () => mediaRevision.current !== savedMediaRevision.current);
  const flush = draftFlusher.current;
  const flushRef = useRef(flush); flushRef.current = flush;
  const adoptIncoming = (next: Annotation) => {
    annotationRef.current = next;
    for (const sketch of next.sketches) rememberMedia('sketch', sketchArchive.current, sketch);
    for (const audio of next.audioRecordings) rememberMedia('audio', audioArchive.current, audio);
    const incoming = next.note || '';
    if (incoming === savedText.current) return;
    if (pending.current === savedText.current || pending.current === incoming) {
      savedText.current = incoming; pending.current = incoming;
      if (lifecycle.current.active) { setDraft(incoming); setSaved(true); }
    } else {
      const known = new Set(noteReferences(savedText.current).map(item => `${item.kind}:${item.id}`));
      const added = noteReferences(incoming).filter(item => !known.has(`${item.kind}:${item.id}`) && !pending.current.includes(item.line));
      if (added.length) { const merged = `${pending.current.trimEnd()}\n\n${added.map(item => item.line).join('\n')}\n`; pending.current = merged; if (lifecycle.current.active) setDraft(merged); }
      savedText.current = incoming;
    }
  };
  const adoptIncomingRef = useRef(adoptIncoming); adoptIncomingRef.current = adoptIncoming;
  useEffect(() => { adoptIncomingRef.current(annotation); }, [annotation.note]);
  const finishRecording = (teardown = false) => {
    if (finishingRecording.current) return finishingRecording.current;
    finishingRecording.current = (async () => {
      if (!recordingRef.current) return;
      try {
        if (!await flushRef.current()) throw new Error('Your note could not be saved. Try again before finishing this recording.');
      } catch (error) {
        // An unexpected unmount must still stop a microphone whose start finished late.
        // Native finalization retains recovery files if encoding or attachment saving fails.
        if (!teardown) throw error;
      }
      let result: Library;
      try { result = await command<Library>('audio_record_finish'); }
      finally {
        recordingRef.current = false;
        if (lifecycle.current.active) { setRecording(false); setRecordingPaused(false); }
      }
      const updated = result.books[book.id]?.annotations.find(item => item.id === annotation.id);
      if (updated) adoptIncomingRef.current(updated);
      if (!await flushRef.current()) throw new Error('Your recording is saved, but the latest note text could not be saved. Keep this editor open and try again.');
    })().finally(() => { finishingRecording.current = null; });
    return finishingRecording.current;
  };
  const finishRecordingRef = useRef(finishRecording); finishRecordingRef.current = finishRecording;
  useEffect(() => {
    if (draft === savedText.current) return;
    setSaved(false);
    const timer = setTimeout(() => { void flushRef.current().catch(error => errorCallback.current(error)); }, 500);
    return () => clearTimeout(timer);
  }, [draft]);
  useEffect(() => {
    lifecycle.current.active = true;
    const generation = ++lifecycle.current.generation;
    const unregister = registerEditor(async () => {
      if (pendingAction.current) await pendingAction.current;
      if (recordingRef.current) await finishRecordingRef.current();
      if (!await flushRef.current()) throw new Error('Your note could not be saved. Keep this window open and try again.');
    });
    return () => {
      unregister(); lifecycle.current.active = false;
      void Promise.resolve().then(async () => {
        // Strict Mode immediately mounts this same editor again; its new owner
        // must not be finalized by the development-only cleanup.
        if (lifecycle.current.generation !== generation) return;
        await pendingAction.current?.catch(() => {});
        if (recordingRef.current) await finishRecordingRef.current(true);
        if (!await flushRef.current()) throw new Error('Your latest note text could not be saved.');
      }).catch(error => errorCallback.current(error));
    };
  }, []);
  const assertActive = () => { if (!lifecycle.current.active) throw new Error('This note editor has closed. Reopen the note to try again.'); };
  const runAction = (label: string, run: () => Promise<void>, saveFirst = true): Promise<void> => {
    if (pendingAction.current) {
      const error = new Error('Wait for the current note action to finish, then try this command again.');
      if (lifecycle.current.active) setActionError(error.message);
      errorCallback.current(error);
      return Promise.reject(error);
    }
    if (!lifecycle.current.active) return Promise.reject(new Error('This note editor has closed. Reopen the note to try again.'));
    setActionBusy(label); setActionError(null); retryAction.current = null;
    const operation = Promise.resolve().then(async () => {
      if (saveFirst && !await flushRef.current()) throw new Error('Your note could not be saved. Try again before continuing.');
      assertActive();
      await run();
    }).catch(error => {
      if (lifecycle.current.active) { setActionError(describeError(error)); retryAction.current = { label, run, saveFirst, failedText: pending.current }; }
      errorCallback.current(error);
      throw error;
    }).finally(() => {
      pendingAction.current = null;
      if (lifecycle.current.active) setActionBusy(null);
    });
    pendingAction.current = operation;
    return operation;
  };
  const handleCommand = async (name: string, argument = ''): Promise<void> => {
    if (name === 'sketch' || name === 'draw') {
      let sketch: Sketch | null = null;
      await runAction('Adding sketch…', async () => {
        if (!sketch) {
          sketch = { id: uuid(), title: 'Untitled sketch', createdAt: now(), modifiedAt: now() };
          // Seed the archive before a save can observe the new reference. The
          // shared flusher also preserves edits made while this write is pending.
          sketchArchive.current.set(sketch.id, sketch);
          const nextText = `${pending.current.trimEnd()}${pending.current.trim() ? '\n\n' : ''}[${sketch.title}](kodi-sketch://${sketch.id})\n`;
          pending.current = nextText; setDraft(nextText); setSaved(false);
        }
        if (!await flushRef.current()) throw new Error('Your sketch could not be saved. Try again to save and open it.');
        assertActive();
        await command('sketch_open', { bookId: book.id, annotationId: annotation.id, sketchId: sketch.id });
      });
    } else if (name === 'audio') {
      await runAction('Starting recording…', async () => {
        if (recordingRef.current) throw new Error('Finish the current recording before starting another one.');
        await command('audio_record_start', { bookId: book.id, annotationId: annotation.id });
        recordingRef.current = true;
        if (!lifecycle.current.active) { await finishRecordingRef.current(true); return; }
        setRecording(true); setRecordingPaused(false);
      });
    } else if (name === 'remind' || name === 'task') {
      await runAction('Opening reminder…', async () => { await reminderCallback.current(argument, { ...annotationRef.current, note: pending.current }); });
    } else if (name === 'finish-audio') {
      await runAction('Finishing recording…', async () => { await finishRecordingRef.current(); }, false);
    } else if (name === 'pause-audio') {
      await runAction(recordingPaused ? 'Resuming recording…' : 'Pausing recording…', async () => {
        const paused = !recordingPaused;
        await command('audio_record_pause', { paused });
        if (lifecycle.current.active) setRecordingPaused(paused);
      }, false);
    } else if (name === 'preview') {
      await runAction('Saving note…', async () => { setPreview(true); });
    } else if (name === 'back') {
      await runAction('Saving note…', async () => { if (recordingRef.current) await finishRecordingRef.current(); assertActive(); onBack(); });
    } else if (name === 'open-sketch') {
      await runAction('Opening sketch…', async () => { await command('sketch_open', { bookId: book.id, annotationId: annotation.id, sketchId: argument }); });
    } else if (name === 'open-reminder') {
      await runAction('Opening reminder…', async () => {
        if (!openReminderCallback.current) throw new Error('This reminder could not be opened. Open it from Research reminders.');
        await openReminderCallback.current(argument);
      });
    } else if (name === 'play-audio') {
      await runAction('Opening audio…', async () => { const audio = [...audioArchive.current.values()].find(item => item.id.toLowerCase() === argument.toLowerCase()); if (audio) await playAudio(audio); });
    } else throw new Error('This note command is unavailable.');
  };
  const openReference = (kind: string, id: string) => {
    if (kind === 'sketch') void handleCommand('open-sketch', id).catch(() => {});
    if (kind === 'audio') void handleCommand('play-audio', id).catch(() => {});
    if (kind === 'reminder') void handleCommand('open-reminder', id).catch(() => {});
  };
  const renameMedia = async (kind: 'sketch' | 'audio', id: string, title: string) => {
    let applied = false;
    await runAction('Renaming attachment…', async () => {
      if (!applied) {
        const archive = kind === 'sketch' ? sketchArchive.current : audioArchive.current;
        const item = [...archive.values()].find(value => value.id.toLowerCase() === id.toLowerCase());
        if (!item) throw new Error('This attachment is no longer available.');
        const trimmed = title.trim(); if (!trimmed) throw new Error('Enter an attachment title.');
        titleOverrides.current.set(`${kind}:${item.id.toLowerCase()}`, trimmed);
        archive.set(item.id, { ...item, title: trimmed }); mediaRevision.current++;
        const text = renameNoteReference(pending.current, kind, id, trimmed);
        pending.current = text; setDraft(text); setSaved(false); applied = true;
      }
      if (!await flushRef.current()) throw new Error('The attachment title could not be saved. Try again.');
    });
  };
  const deleteMedia = async (kind: 'sketch' | 'audio', id: string) => {
    let applied = false;
    await runAction('Removing attachment…', async () => {
      if (!applied) {
        const text = removeNoteReference(pending.current, kind, id);
        managedReferences.current.add(`${kind}:${id.toLowerCase()}`); mediaRevision.current++;
        pending.current = text; setDraft(text); setSaved(false); applied = true;
      }
      if (!await flushRef.current()) throw new Error('The attachment could not be removed. Try again.');
    });
  };
  const addTranscript = async (audio: AudioNote) => {
    let applied = false;
    await runAction('Adding transcript…', async () => {
      if (!applied) {
        const text = insertAudioTranscript(pending.current, audio.id, audio.transcript || '');
        if (text === null) throw new Error('Keep this recording’s link in your note before adding its transcript.');
        pending.current = text; setDraft(text); setSaved(false); applied = true;
      }
      if (!await flushRef.current()) throw new Error('The transcript could not be saved. Try again.');
    });
  };
  const playAudio = (audio: AudioNote) => {
    if (!audio.path) throw new Error('This recording has not downloaded yet. Use Sync now to download its audio file.');
    return command('audio_play', { path: audio.path, rate: 1 });
  };
  return <div className="note-editor-panel"><div className="panel-heading"><IconButton label="Back to notes" disabled={Boolean(actionBusy)} onClick={() => void handleCommand('back').catch(() => {})}><ArrowLeft size={17} /></IconButton><h2>Note</h2><span className="autosave" role="status">{saved ? <><Check size={12} />Saved</> : 'Saving…'}</span><ActionMenu className="inline-menu" label="Note actions" trigger="•••"><button onClick={() => onExport('markdown', annotation.id)}><Download size={14} />Export Markdown</button><button onClick={() => onExport('docx', annotation.id)}>Export Word document</button><button onClick={() => onExport('html', annotation.id)}>Export HTML</button><button className="danger" onClick={() => onDelete(annotation.id)}><Trash2 size={14} />Delete highlight & note</button></ActionMenu></div>
    <div className="note-editor-scroll"><div className="note-quote"><span className="eyebrow">{annotation.chapterTitle || `${book.kind === 'pdf' ? 'PAGE' : 'CHAPTER'} ${annotation.locator.spineIndex + 1}`}</span><blockquote>{annotation.text || 'Page note'}</blockquote></div><div className="note-color-palette" role="group" aria-label="Highlight color">{HIGHLIGHTS.map(color => <button key={color.id} aria-label={color.label} aria-pressed={annotation.color === color.id} className={`swatch${annotation.color === color.id ? ' selected' : ''}${color.id === 'underline' ? ' underline' : ''}`} style={{ background: color.css }} onClick={() => { void onUpdate(annotation.id, { color: color.id, modifiedAt: now() }); }}>{annotation.color === color.id ? <Check size={13} /> : color.id === 'underline' ? 'U' : null}</button>)}</div>
    <div className="note-format-toolbar"><button className={!preview ? 'selected' : ''} disabled={Boolean(actionBusy)} onClick={() => setPreview(false)}>Write</button><button className={preview ? 'selected' : ''} disabled={Boolean(actionBusy)} onClick={() => void handleCommand('preview').catch(() => {})}>Preview</button><span /><IconButton label="Bold" onClick={() => markdownRef.current?.format('bold')} disabled={preview || Boolean(actionBusy)}><Bold size={14} /></IconButton><IconButton label="Italic" onClick={() => markdownRef.current?.format('italic')} disabled={preview || Boolean(actionBusy)}><Italic size={14} /></IconButton><IconButton label="Code" onClick={() => markdownRef.current?.format('code')} disabled={preview || Boolean(actionBusy)}><Code size={14} /></IconButton><IconButton label="Bullet list" onClick={() => markdownRef.current?.format('list')} disabled={preview || Boolean(actionBusy)}><List size={14} /></IconButton><IconButton label="Add sketch" disabled={Boolean(actionBusy)} onClick={() => void handleCommand('sketch').catch(() => {})}><Pencil size={15} /></IconButton><IconButton label="Record audio" onClick={() => void handleCommand('audio').catch(() => {})} disabled={recording || Boolean(actionBusy)}><Mic size={16} /></IconButton><IconButton label="Add research reminder" disabled={Boolean(actionBusy)} onClick={() => void handleCommand('remind').catch(() => {})}><Search size={15} /></IconButton></div>
    {actionBusy ? <p className="editor-hint note-command-feedback" role="status">{actionBusy}</p> : null}
    {actionError ? <div className="editor-hint dialog-error note-command-feedback" role="alert">{actionError}{retryAction.current && !actionBusy ? retryAction.current.failedText === draft ? <> <button className="text-button" type="button" onClick={() => {
      const retry = retryAction.current;
      // A restored slash command belongs to the parser. Replaying its action
      // directly would save the literal command alongside the new attachment.
      if (retry && pending.current === retry.failedText) void runAction(retry.label, retry.run, retry.saveFirst).catch(() => {});
    }}>Try again</button></> : <> Press Enter on the command to try again, or use the toolbar.</> : null}</div> : null}
    {preview ? <MarkdownPreview text={draft || '*Your note is empty.*'} onReference={openReference} /> : <Suspense fallback={<p className="editor-hint">Opening note editor…</p>}><MarkdownEditor ref={markdownRef} value={draft} onChange={value => { pending.current = value; setDraft(value); }} onCommand={handleCommand} onBlur={() => void flush().catch(error => errorCallback.current(error))} /></Suspense>}
    {recording ? <div className="recording-card" role="status"><i className="recording-dot" /><span>{recordingPaused ? 'Recording paused' : 'Recording your thought…'}</span><IconButton label={recordingPaused ? 'Resume recording' : 'Pause recording'} disabled={Boolean(actionBusy)} onClick={() => void handleCommand('pause-audio').catch(() => {})}>{recordingPaused ? <Play size={14} /> : <Pause size={14} />}</IconButton><IconButton label="Finish recording" disabled={Boolean(actionBusy)} onClick={() => void handleCommand('finish-audio').catch(() => {})}><Square size={15} fill="currentColor" /></IconButton></div> : null}
    {(annotation.sketches || []).length ? <div className="note-attachments"><h3>Sketches</h3>{annotation.sketches.map(sketch => <SketchAttachment key={sketch.id} sketch={sketch} disabled={Boolean(actionBusy)} onOpen={() => openReference('sketch', sketch.id)} onRename={title => renameMedia('sketch', sketch.id, title)} onDelete={() => deleteMedia('sketch', sketch.id)} />)}</div> : null}
    {(annotation.audioRecordings || []).length ? <div className="note-attachments"><h3>Audio notes</h3>{annotation.audioRecordings.map(audio => <AudioAttachment key={audio.id} audio={audio} bookId={book.id} annotationId={annotation.id} disabled={Boolean(actionBusy)} onError={onError} onRename={title => renameMedia('audio', audio.id, title)} onDelete={() => deleteMedia('audio', audio.id)} onAddTranscript={audio.transcript ? () => addTranscript(audio) : undefined} />)}</div> : null}
    <p className="editor-hint">Start a new line with <kbd>/</kbd> for sketches, audio, or reminders.<br />Markdown · <kbd>{typeof navigator !== 'undefined' && /Mac/.test(navigator.platform) ? '⌘ Enter' : 'Ctrl+Enter'}</kbd> to save</p></div>
  </div>;
}

export function GlobalNotes({ books, onOpen }: { books: Book[]; onOpen: (book: Book, annotation: Annotation) => void }) {
  const [query, setQuery] = useState('');
  const notes = books.flatMap(book => book.annotations.map(annotation => ({ book, annotation }))).filter(({ book, annotation }) => `${book.title} ${annotation.text} ${annotation.note || ''}`.toLowerCase().includes(query.toLowerCase())).sort((a, b) => b.annotation.modifiedAt - a.annotation.modifiedAt);
  return <section className="content-view global-notes"><header className="page-heading"><div><span className="eyebrow">IDEAS WORTH KEEPING</span><h1>Your notes</h1><p>Passages, thoughts, and connections across your library.</p></div></header><div className="search-field wide-search"><Search size={16} /><input aria-label="Search all notes" placeholder="Search passages, notes, or books…" value={query} onChange={event => setQuery(event.target.value)} /></div>{!notes.length ? <EmptyState icon={<FileText size={30} />} title="Your next idea starts with a passage"><p>Highlight something while reading to collect it here.</p></EmptyState> : <div className="global-note-grid">{notes.map(({ book, annotation }) => <button className="global-note-card" key={`${book.id}:${annotation.id}`} onClick={() => onOpen(book, annotation)}><span className="eyebrow">{book.title}</span><blockquote>{annotation.text || 'Page note'}</blockquote>{annotation.note ? <p>{notePreviewText(annotation.note).slice(0, 250)}</p> : null}<small>{book.author || 'Unknown author'}<span>Open note →</span></small></button>)}</div>}</section>;
}
