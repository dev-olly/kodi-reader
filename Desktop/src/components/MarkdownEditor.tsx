import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react';
import { EditorState } from '@codemirror/state';
import { drawSelection, EditorView, keymap, placeholder } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { noteCommandExtensions } from '../noteCommands';

export interface MarkdownEditorHandle { format: (kind: 'bold' | 'italic' | 'code' | 'list') => void }
export const MarkdownEditor = forwardRef<MarkdownEditorHandle, {
  value: string; onChange: (value: string) => void; onCommand: (name: string, argument: string) => void | Promise<void>; onBlur?: () => void; label?: string;
}>(function MarkdownEditor({ value, onChange, onCommand, onBlur, label = 'Note text' }, ref) {
  const container = useRef<HTMLDivElement>(null);
  const editor = useRef<EditorView | null>(null);
  const callbacks = useRef({ onChange, onCommand, onBlur }); callbacks.current = { onChange, onCommand, onBlur };
  useImperativeHandle(ref, () => ({ format(kind) {
    const view = editor.current; if (!view) return;
    const { from, to } = view.state.selection.main;
    if (kind === 'list') {
      const first = view.state.doc.lineAt(from); const last = view.state.doc.lineAt(to);
      const text = view.state.sliceDoc(first.from, last.to);
      const lines = text.split('\n'); const remove = lines.every(line => /^- /.test(line));
      view.dispatch({ changes: { from: first.from, to: last.to, insert: lines.map(line => remove ? line.slice(2) : `- ${line}`).join('\n') } });
    } else {
      const marker = kind === 'bold' ? '**' : kind === 'italic' ? '*' : '`';
      const before = view.state.sliceDoc(Math.max(0, from - marker.length), from);
      const after = view.state.sliceDoc(to, Math.min(view.state.doc.length, to + marker.length));
      if (before === marker && after === marker) view.dispatch({ changes: [{ from: from - marker.length, to: from, insert: '' }, { from: to, to: to + marker.length, insert: '' }], selection: { anchor: from - marker.length, head: to - marker.length } });
      else { const text = view.state.sliceDoc(from, to); view.dispatch({ changes: { from, to, insert: `${marker}${text}${marker}` }, selection: { anchor: from + marker.length, head: to + marker.length } }); }
    }
    view.focus();
  } }), []);
  useEffect(() => {
    if (!container.current) return;
    const view = new EditorView({ parent: container.current, state: EditorState.create({ doc: value, extensions: [
      markdown(), history(), drawSelection(), EditorView.lineWrapping, placeholder('Write a thought…'),
      EditorView.contentAttributes.of({ 'aria-label': label, spellcheck: 'true' }),
      noteCommandExtensions((name, argument) => {
        const afterRemoval = view.state.doc.toString();
        const insertion = view.state.selection.main.head;
        void Promise.resolve().then(() => {
          if (editor.current === view) return callbacks.current.onCommand(name, argument);
        }).catch(() => {
          // The parent displays the failure. Preserve a retryable command if
          // the user has not typed on and no attachment was already added.
          if (editor.current === view && view.state.doc.toString() === afterRemoval) {
            const text = `/${name}${argument ? ` ${argument}` : ''}`;
            view.dispatch({ changes: { from: insertion, insert: text }, selection: { anchor: insertion + text.length } });
          }
        });
      }),
      keymap.of([{ key: 'Mod-Enter', run(current) { current.contentDOM.blur(); callbacks.current.onBlur?.(); return true; } }, indentWithTab, ...defaultKeymap, ...historyKeymap]),
      EditorView.updateListener.of(update => { if (update.docChanged) callbacks.current.onChange(update.state.doc.toString()); }),
      EditorView.domEventHandlers({ blur() { callbacks.current.onBlur?.(); } }),
      EditorView.theme({ '&': { background: 'transparent', fontSize: '14px' }, '.cm-content': { padding: '14px 0', fontFamily: 'inherit', lineHeight: '1.65', minHeight: '150px' }, '.cm-scroller': { overflow: 'auto', fontFamily: 'inherit' }, '&.cm-focused': { outline: 'none' }, '.cm-line': { padding: '0 2px' }, '.cm-placeholder': { color: 'var(--muted)' }, '.cm-cursor': { borderLeftColor: 'var(--accent)', borderLeftWidth: '1.5px' }, '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': { background: 'var(--accent-soft)' }, '.cm-tooltip': { backgroundColor: 'var(--surface)', color: 'var(--ink)', border: '1px solid var(--line)', borderRadius: '8px', overflow: 'hidden', boxShadow: '0 6px 20px #0002' }, '.cm-tooltip-autocomplete > ul > li': { fontFamily: 'inherit', fontSize: '12px', padding: '7px 10px' }, '.cm-tooltip-autocomplete > ul > li[aria-selected]': { backgroundColor: 'var(--accent-soft)', color: 'var(--ink)' }, '.cm-completionDetail': { color: 'var(--muted)', fontSize: '10px', marginLeft: '10px' } }),
    ] }) });
    editor.current = view;
    view.focus();
    return () => { view.destroy(); editor.current = null; };
    // The editor keeps its selection and undo history while React updates the note.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    const view = editor.current;
    if (view && view.state.doc.toString() !== value) view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: value } });
  }, [value]);
  return <div className="markdown-editor" ref={container} />;
});
