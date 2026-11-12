import { useEffect, useRef, useState } from 'react';
import { ArrowUp, Check, LogOut, Mail, Plus, Sparkles, Square, Trash2, X } from 'lucide-react';
import { command, describeError, subscribe } from '../native';
import { now, uuid } from '../model';
import { draftAfterFailedAnswer, isCreditError, matchesAIRequest, type ActiveAIRequest } from '../aiCredits';
import { createPendingSignIn, normalizeSignInCode, parsePendingSignIn, PENDING_SIGN_IN_KEY } from '../authCode';
import { readSavedPrompts, savePreference } from '../preferences';
import type { AuthStatus, Book, ChatThread, ReaderMessage } from '../types';
import { MarkdownPreview } from './NotesPanel';
import { IconButton, Spinner } from './Primitives';
import { AICreditControls } from './AICreditControls';

export function SignInForm({ configured, onSignedIn, onError }: { configured: boolean | undefined; onSignedIn: (status: AuthStatus) => void; onError: (error: unknown) => void }) {
  const [pending] = useState(() => {
    try {
      const saved = parsePendingSignIn(localStorage.getItem(PENDING_SIGN_IN_KEY), Date.now());
      if (!saved) localStorage.removeItem(PENDING_SIGN_IN_KEY);
      return saved;
    } catch { return null; }
  });
  const [email, setEmail] = useState(pending?.email || '');
  const [code, setCode] = useState('');
  const [sent, setSent] = useState(Boolean(pending));
  const [busy, setBusy] = useState(false);
  const emailInput = useRef<HTMLInputElement>(null);
  const clearPending = () => { try { localStorage.removeItem(PENDING_SIGN_IN_KEY); } catch { /* Sign-in also works when browser storage is unavailable. */ } };
  const showCode = () => {
    const address = email.trim();
    setEmail(address); setCode(''); setSent(true);
    try { localStorage.setItem(PENDING_SIGN_IN_KEY, JSON.stringify(createPendingSignIn(address, Date.now()))); } catch { /* Keep the current form usable without persistent storage. */ }
  };
  const send = async () => {
    if (!configured || busy) return;
    setBusy(true);
    try {
      if (sent) {
        const normalized = normalizeSignInCode(code);
        setCode(normalized);
        if (!/^[0-9]+$/.test(normalized)) throw new Error('Enter the sign-in code from your email.');
        await command('auth_verify_code', { email: email.trim(), code: normalized });
        clearPending(); setCode('');
        onSignedIn(await command<AuthStatus>('auth_status'));
      } else { await command('auth_send_code', { email: email.trim() }); showCode(); }
    } catch (error) { onError(error); } finally { setBusy(false); }
  };
  if (configured === undefined) return <div className="sign-in-form" role="status"><Spinner label="Checking sign-in…" /></div>;
  if (!configured) return <div className="sign-in-form" role="status"><span className="sign-in-icon"><Sparkles size={24} /></span><h3>Ask AI is unavailable</h3><p>Sign-in hasn’t been enabled for this version of Kodi Reader.</p><small>You can keep reading and taking notes without an account.</small></div>;
  return <form className="sign-in-form" onSubmit={event => { event.preventDefault(); void send(); }}>
    <span className="sign-in-icon"><Mail size={24} /></span>
    <h3>{sent ? 'Check your inbox' : 'A little help with the big ideas'}</h3>
    <p>{sent ? `Enter the sign-in code for ${email}.` : 'Sign in with your email to ask questions about what you’re reading.'}</p>
    {!sent ? <label>Email address<input ref={emailInput} type="email" autoComplete="email" required disabled={busy} value={email} onChange={event => setEmail(event.target.value)} placeholder="you@example.com" /></label>
      : <label>Sign-in code<input type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]+" required disabled={busy} spellCheck={false} value={code} onChange={event => setCode(normalizeSignInCode(event.target.value))} placeholder="Enter your code" autoFocus /></label>}
    <button className="button primary" type="submit" disabled={busy}>{busy ? <Spinner label={sent ? 'Signing in…' : 'Sending…'} /> : sent ? 'Sign in' : 'Send a code'}</button>
    {sent ? <button className="text-button" type="button" disabled={busy} onClick={() => { clearPending(); setSent(false); setCode(''); }}>Use another email</button>
      : <button className="text-button" type="button" disabled={busy} onClick={() => { if (emailInput.current?.reportValidity()) showCode(); }}>I already have a code</button>}
    <small>Reading and notes always work without an account. Ask AI sends your selected context to Kodi’s hosted AI service.</small>
  </form>;
}

export function AIPanel({ book, selection, onSaveThread, onError }: {
  book: Book; selection: ReaderMessage | null; onSaveThread: (thread: ChatThread) => Promise<unknown>; onError: (error: unknown) => void;
}) {
  const [auth, setAuth] = useState<AuthStatus | null>(null);
  const [authLoading, setAuthLoading] = useState(true);
  const [threadId, setThreadId] = useState(book.chats[0]?.id || '');
  const [text, setText] = useState('');
  const [pendingUser, setPendingUser] = useState('');
  const [stream, setStream] = useState('');
  const [sending, setSending] = useState(false);
  const [attachSelection, setAttachSelection] = useState(true);
  const [prompts, setPrompts] = useState<string[]>(() => readSavedPrompts());
  const [showSavePrompt, setShowSavePrompt] = useState(false);
  const [newPrompt, setNewPrompt] = useState('');
  const [creditsRefresh, setCreditsRefresh] = useState(0);
  const [openCreditPacks, setOpenCreditPacks] = useState(0);
  const bottom = useRef<HTMLDivElement>(null);
  const active = useRef<ActiveAIRequest>({ requestId: null, threadId, submitted: '', received: '', sending: false });
  const paymentsEnabled = useRef(false); paymentsEnabled.current = auth?.paymentsEnabled === true;
  const thread = book.chats.find(item => item.id === threadId);
  useEffect(() => {
    let alive = true;
    command<AuthStatus>('auth_status').then(status => { if (alive) setAuth(status); }).catch(error => { if (alive) onError(error); }).finally(() => { if (alive) setAuthLoading(false); });
    const subscriptions = [
      subscribe<{ requestId?: string; bookId?: string; threadId?: string; text: string }>('ai-delta', event => {
        if (!alive || !matchesAIRequest(event, active.current, book.id)) return;
        active.current.received += event.text;
        setStream(current => current + event.text);
      }),
      subscribe<{ requestId?: string; bookId?: string; threadId?: string; error?: string }>('ai-done', event => {
        if (!alive || !matchesAIRequest(event, active.current, book.id)) return;
        if (event.error) {
          const submitted = active.current.submitted; const received = active.current.received;
          setText(current => draftAfterFailedAnswer(current, submitted, received));
          if (paymentsEnabled.current && isCreditError(event.error)) setOpenCreditPacks(current => current + 1);
          onError(event.error);
        }
        active.current.sending = false;
        setSending(false); setPendingUser(''); setStream('');
        if (paymentsEnabled.current) setCreditsRefresh(current => current + 1);
      }),
    ];
    return () => { alive = false; for (const subscription of subscriptions) void subscription.then(stop => stop()); };
    // Book identity owns the streaming subscription; event handlers read current refs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.id]);
  useEffect(() => { bottom.current?.scrollIntoView({ block: 'nearest' }); }, [thread?.messages.length, stream]);
  useEffect(() => { savePreference('kodi-desktop.prompts', JSON.stringify(prompts)); }, [prompts]);
  const send = async (prompt = text) => {
    if (!prompt.trim() || active.current.sending) return;
    const currentId = threadId || uuid(); const requestId = uuid();
    active.current = { sending: true, threadId: currentId, requestId, submitted: prompt.trim(), received: '' };
    setSending(true); setPendingUser(prompt.trim()); setStream(''); setText('');
    try {
      if (!threadId) {
        const result = await onSaveThread({ id: currentId, title: prompt.trim().slice(0, 56), messages: [], createdAt: now(), modifiedAt: now() });
        if (result === undefined) throw new Error('The conversation could not be saved. Your question is kept below.');
        setThreadId(currentId);
      }
      const result = await command<string>('ai_chat', { requestId, bookId: book.id, threadId: currentId, text: prompt.trim(), references: selection?.text && attachSelection ? [{ id: uuid(), text: selection.text, locator: selection.locator, chapterTitle: selection.title }] : [] });
      if (active.current.requestId === requestId && active.current.sending && typeof result === 'string') active.current.requestId = result;
    } catch (error) {
      if (active.current.requestId !== requestId) return;
      active.current.sending = false;
      setSending(false); setPendingUser(''); setStream(''); setText(current => draftAfterFailedAnswer(current, prompt.trim(), active.current.received)); onError(error);
      if (paymentsEnabled.current && isCreditError(describeError(error))) { setOpenCreditPacks(current => current + 1); setCreditsRefresh(current => current + 1); }
    }
  };
  const signedIn = auth?.signedIn ?? Boolean(auth?.email);
  return <div className="ai-panel"><div className="panel-heading"><Sparkles size={17} /><h2>Ask AI</h2><IconButton label="New conversation" disabled={sending} onClick={() => { setThreadId(''); setPendingUser(''); setStream(''); }}><Plus size={17} /></IconButton></div>
    {authLoading ? <div className="center-loading"><Spinner label="Checking sign-in…" /></div> : !signedIn ? <SignInForm configured={auth?.configured} onSignedIn={setAuth} onError={onError} /> : <>
      {auth?.paymentsEnabled === true ? <AICreditControls key={auth.userId || auth.email || 'signed-in'} owner={auth.userId || auth.email || 'signed-in'} refreshToken={creditsRefresh} openCatalogToken={openCreditPacks} /> : null}
      {book.chats.length ? <select className="chat-thread-select" aria-label="Conversation" value={threadId} onChange={event => setThreadId(event.target.value)} disabled={sending}><option value="">New conversation</option>{book.chats.map(item => <option key={item.id} value={item.id}>{item.title || 'Conversation'}</option>)}</select> : null}
      <div className="chat-messages" aria-live="polite">{!thread?.messages.length && !sending ? <div className="chat-welcome"><div className="ai-symbol"><Sparkles size={25} /></div><h3>Read between the lines.</h3><p>Explore an idea, untangle a difficult passage, or connect it to something you know.</p>{['Explain this simply', 'What is the main idea?', 'Give me a practical example'].map(prompt => <button className="prompt-button" key={prompt} onClick={() => void send(prompt)}>{prompt}<ArrowUp size={13} /></button>)}</div> : null}{thread?.messages.map((message, index) => <div className={`chat-message ${message.role}`} key={message.id || index}><span className="chat-role">{message.role === 'user' ? 'You' : 'Kodi'}</span><MarkdownPreview text={message.text} />{message.incomplete ? <small className="interrupted-reply">This reply was interrupted. You can ask again.</small> : null}</div>)}{pendingUser && !thread?.messages.some(message => message.role === 'user' && message.text === pendingUser && (message.createdAt || 0) > now() - 30) ? <div className="chat-message user"><span className="chat-role">You</span><p>{pendingUser}</p></div> : null}{sending ? <div className="chat-message assistant"><span className="chat-role">Kodi</span>{stream ? <MarkdownPreview text={stream} /> : <Spinner label="Thinking…" />}</div> : null}<div ref={bottom} /></div>
      {prompts.length || showSavePrompt ? <div className="saved-prompts">{prompts.map(prompt => <div key={prompt}><button onClick={() => setText(prompt)} title={prompt}>{prompt}</button><button aria-label={`Remove saved prompt ${prompt}`} onClick={() => setPrompts(current => current.filter(item => item !== prompt))}><X size={11} /></button></div>)}{showSavePrompt ? <form onSubmit={event => { event.preventDefault(); const prompt = newPrompt.trim(); if (prompt) setPrompts(current => [...new Set([...current, prompt])]); setNewPrompt(''); setShowSavePrompt(false); }}><input aria-label="Saved prompt" value={newPrompt} onChange={event => setNewPrompt(event.target.value)} placeholder="A question you ask often…" autoFocus /><IconButton label="Save prompt" type="submit"><Check size={14} /></IconButton></form> : null}</div> : null}
      {selection?.text ? <div className="context-chip"><label><input type="checkbox" checked={attachSelection} onChange={event => setAttachSelection(event.target.checked)} />Include selected passage</label><p>“{selection.text.slice(0, 120)}{selection.text.length > 120 ? '…' : ''}”</p></div> : null}
      <form className="chat-composer" onSubmit={event => { event.preventDefault(); void send(); }}><textarea aria-label="Ask a question" placeholder="Ask about this book…" value={text} onChange={event => setText(event.target.value)} rows={3} onKeyDown={event => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void send(); } }} /><div><button type="button" className="text-button" onClick={() => { setShowSavePrompt(!showSavePrompt); setNewPrompt(text); }}><Plus size={12} />Save prompt</button><span />{sending ? <IconButton label="Stop answer" onClick={() => void command('ai_cancel').catch(onError)}><Square size={15} fill="currentColor" /></IconButton> : <button type="submit" className="send-button" aria-label="Send question" disabled={!text.trim()}><ArrowUp size={17} /></button>}</div></form>
      <footer className="ai-footer"><span>{auth?.email}</span><IconButton label="Sign out of Ask AI" onClick={() => { void command('auth_sign_out').then(() => setAuth({ configured: true, signedIn: false })).catch(onError); }}><LogOut size={13} /></IconButton></footer>
    </>}
  </div>;
}
