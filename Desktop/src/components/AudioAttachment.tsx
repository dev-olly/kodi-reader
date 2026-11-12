import { useEffect, useRef, useState } from 'react';
import { Check, Download, Pause, Play, Sparkles, Trash2 } from 'lucide-react';
import { chooseExport, command, subscribe } from '../native';
import { audioCardPlayback, type AudioPlaybackStatus } from '../audioPlayback';
import { duration } from '../model';
import { focusRangeControl } from '../inputFocus';
import type { AudioNote } from '../types';
import { ActionMenu, IconButton, Spinner } from './Primitives';

export function AudioAttachment({ audio, bookId, annotationId, onRename, onDelete, onError, onAddTranscript, disabled = false }: {
  audio: AudioNote; bookId: string; annotationId: string; onRename: (title: string) => Promise<void> | void; onDelete: () => Promise<void> | void; onError: (error: unknown) => void;
  onAddTranscript?: () => Promise<void> | void; disabled?: boolean;
}) {
  const [active, setActive] = useState(false);
  const [paused, setPaused] = useState(false);
  const [position, setPosition] = useState(0);
  const [length, setLength] = useState(audio.duration || 0);
  const [transcribing, setTranscribing] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [title, setTitle] = useState(audio.title || 'Audio note');
  const [opening, setOpening] = useState(false);
  const alive = useRef(true);
  const requestPending = useRef(false);
  const playback = useRef({ active: false, paused: false, position: 0, duration: audio.duration || 0 });
  const statusVersion = useRef(0);
  const errorCallback = useRef(onError); errorCallback.current = onError;
  const applyStatus = (status: AudioPlaybackStatus) => {
    const next = audioCardPlayback(audio.path, status.phase === 'paused' || status.paused !== undefined ? {
      ...status, position: status.position ?? status.elapsed ?? playback.current.position, duration: status.duration ?? playback.current.duration,
    } : status);
    playback.current = next;
    if (!alive.current) return;
    setActive(next.active); setPaused(next.paused); setPosition(next.position);
    if (next.duration) setLength(next.duration);
  };
  const statusCallback = useRef(applyStatus); statusCallback.current = applyStatus;
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  useEffect(() => {
    let disposed = false; let stop: (() => void) | undefined;
    void subscribe<AudioPlaybackStatus>('audio-state', status => {
      if (disposed) return;
      statusVersion.current++; statusCallback.current(status);
    }).then(unsubscribe => { if (disposed) unsubscribe(); else stop = unsubscribe; }).catch(error => { if (!disposed) errorCallback.current(error); });
    // Opening an editor during playback should reflect the current owner too.
    const version = statusVersion.current;
    void command<AudioPlaybackStatus>('audio_position').then(status => { if (!disposed && version === statusVersion.current) statusCallback.current(status); }).catch(() => {});
    return () => { disposed = true; stop?.(); };
  }, [audio.path]);
  useEffect(() => {
    if (!active || paused) return;
    const timer = setInterval(() => {
      const version = statusVersion.current;
      void command<AudioPlaybackStatus>('audio_position').then(status => {
        if (alive.current && version === statusVersion.current) statusCallback.current(status);
      }).catch(() => { if (alive.current && version === statusVersion.current) statusCallback.current({ phase: 'idle' }); });
    }, 400);
    return () => clearInterval(timer);
  }, [active, paused]);
  const play = async () => {
    if (disabled || requestPending.current) return;
    requestPending.current = true; setOpening(true);
    try {
      if (!audio.path) throw new Error('This recording has not downloaded yet. Use Sync now to download its audio file.');
      const version = statusVersion.current;
      const result = playback.current.active
        ? await command<AudioPlaybackStatus>('audio_pause', { paused: !playback.current.paused, path: audio.path })
        : await command<AudioPlaybackStatus>('audio_play', { path: audio.path, rate: 1 });
      // Native events own playback state. A superseded decode may return after
      // another clip or narration has already become the active source.
      if (alive.current && version === statusVersion.current) statusCallback.current(result.cancelled ? { phase: 'idle' } : result);
    } catch (error) { onError(error); }
    finally { requestPending.current = false; if (alive.current) setOpening(false); }
  };
  const transcribe = async () => {
    setTranscribing(true);
    try { await command('audio_transcribe', { bookId, annotationId, audioId: audio.id }); } catch (error) { onError(error); } finally { if (alive.current) setTranscribing(false); }
  };
  const exportAudio = async () => {
    try { const destination = await chooseExport(audio.title || 'Audio note', 'm4a'); if (destination) await command('audio_export', { bookId, annotationId, audioId: audio.id, destination }); } catch (error) { onError(error); }
  };
  const deleteAudio = async () => {
    // A matching native start may still be decoding, including one requested
    // through the note's preview link. Stop that owner before removing its card.
    if (audio.path) {
      try { await command('audio_stop', { path: audio.path }); } catch (error) { onError(error); return; }
    }
    try { await onDelete(); } catch { /* The parent reports failed note mutations and retains its retry. */ }
  };
  return <div className="audio-card"><div className="audio-card-header"><IconButton disabled={disabled || opening} label={opening ? 'Opening recording…' : active && !paused ? `Pause ${audio.title || 'recording'}` : `Play ${audio.title || 'recording'}`} onClick={() => void play()}>{active && !paused ? <Pause size={17} fill="currentColor" /> : <Play size={17} fill="currentColor" />}</IconButton><div>{renaming ? <form className="audio-rename" onSubmit={event => { event.preventDefault(); if (title.trim()) void Promise.resolve().then(() => onRename(title.trim())).then(() => setRenaming(false)).catch(() => {}); }}><input type="text" aria-label="Recording title" disabled={disabled} value={title} onChange={event => setTitle(event.target.value)} autoFocus /><IconButton type="submit" disabled={disabled} label="Save recording title"><Check size={12} /></IconButton></form> : <button className="audio-title" onClick={() => { setTitle(audio.title || 'Audio note'); setRenaming(true); }} title="Rename recording"><strong>{audio.title || 'Audio note'}</strong></button>}<small>{active ? `${duration(position)} / ` : ''}{duration(length)}{audio.createdAt ? ` · ${new Date(audio.createdAt * 1000).toLocaleDateString()}` : ''}</small></div><ActionMenu className="inline-menu" label="Recording actions" trigger="•••"><button disabled={disabled} onClick={() => { setTitle(audio.title || 'Audio note'); setRenaming(true); }}>Rename…</button><button disabled={disabled} onClick={() => void exportAudio()}><Download size={13} />Export recording</button><button onClick={() => void transcribe()} disabled={disabled || transcribing}><Sparkles size={13} />Transcribe</button>{audio.transcript && onAddTranscript ? <button disabled={disabled} onClick={() => { void Promise.resolve().then(onAddTranscript).catch(() => {}); }}>Add transcript to note</button> : null}<button className="danger" disabled={disabled} onClick={() => void deleteAudio()}><Trash2 size={13} />Delete recording</button></ActionMenu></div>{audio.waveform?.length ? <div className="waveform" aria-hidden="true">{audio.waveform.slice(0, 70).map((value, index) => <i key={index} style={{ height: `${Math.max(8, Math.min(100, Math.abs(value) * 100))}%` }} />)}</div> : null}{active ? <input className="audio-seek" type="range" onPointerDown={focusRangeControl} onClick={focusRangeControl} aria-label="Seek recording" min={0} max={Math.max(1, length)} step={0.1} value={position} onChange={event => { if (!audio.path || !playback.current.active) return; const seconds = Number(event.target.value); statusVersion.current++; playback.current.position = seconds; setPosition(seconds); void command('audio_seek', { seconds, path: audio.path }).catch(onError); }} /> : null}{transcribing ? <div className="transcribing-status"><Spinner label="Transcribing on this device…" /></div> : audio.transcript ? <details className="transcript"><summary>Transcript</summary><p>{audio.transcript}</p><button className="text-button" onClick={() => void navigator.clipboard.writeText(audio.transcript!).catch(onError)}>Copy transcript</button></details> : <button className="text-button transcribe-button" disabled={disabled || transcribing} onClick={() => void transcribe()}><Sparkles size={11} />Transcribe on this device</button>}</div>;
}
