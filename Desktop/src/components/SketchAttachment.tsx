import { useEffect, useState } from 'react';
import { Check, Pencil, Trash2 } from 'lucide-react';
import { mediaSource } from '../native';
import type { Sketch } from '../types';
import { ActionMenu, IconButton } from './Primitives';

export function SketchAttachment({ sketch, onOpen, onRename, onDelete, disabled = false }: { sketch: Sketch; onOpen: () => void; onRename: (title: string) => Promise<void> | void; onDelete: () => Promise<void> | void; disabled?: boolean }) {
  const [preview, setPreview] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(sketch.title || 'Sketch');
  const previewPath = typeof sketch.previewPath === 'string' ? sketch.previewPath : null;
  useEffect(() => {
    let alive = true; setPreview(null);
    if (previewPath) void mediaSource(previewPath).then(src => { if (alive) setPreview(src); }).catch(() => {});
    return () => { alive = false; };
  }, [previewPath, sketch.modifiedAt]);
  return <div className="sketch-card"><button className="sketch-preview" disabled={disabled} onClick={onOpen} aria-label={`Open ${sketch.title || 'sketch'}`}>{preview ? <img src={preview} alt="" /> : <Pencil size={25} />}</button><div className="sketch-card-footer">{editing ? <form onSubmit={event => { event.preventDefault(); if (title.trim()) void Promise.resolve().then(() => onRename(title.trim())).then(() => setEditing(false)).catch(() => {}); }}><input type="text" aria-label="Sketch title" disabled={disabled} value={title} onChange={event => setTitle(event.target.value)} autoFocus /><IconButton label="Save sketch title" disabled={disabled} type="submit"><Check size={12} /></IconButton></form> : <button className="sketch-title" disabled={disabled} onClick={onOpen}>{sketch.title || 'Sketch'}</button>}<ActionMenu className="inline-menu" label="Sketch actions" trigger="•••"><button disabled={disabled} onClick={onOpen}><Pencil size={13} />Edit drawing</button><button disabled={disabled} onClick={() => { setTitle(sketch.title || 'Sketch'); setEditing(true); }}>Rename…</button><button className="danger" disabled={disabled} onClick={() => { void Promise.resolve().then(onDelete).catch(() => {}); }}><Trash2 size={13} />Remove sketch</button></ActionMenu></div></div>;
}
