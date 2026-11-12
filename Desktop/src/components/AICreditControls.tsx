import { useCallback, useEffect, useRef, useState } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { Coins, ExternalLink, RefreshCw, X } from 'lucide-react';
import { command, describeError, isNative } from '../native';
import { checkoutUrl, formatCreditPrice, parseCreditBalance, parseCreditCatalog, validCheckoutRequests, type CreditBalance, type CreditCatalog, type CreditPack } from '../aiCredits';
import { IconButton, Spinner } from './Primitives';

export function AICreditControls({ owner, refreshToken, openCatalogToken }: { owner: string; refreshToken: number; openCatalogToken: number }) {
  const storageKey = `kodi-desktop.checkout.${owner}`;
  const [initialCheckoutRequests] = useState(() => { try { return validCheckoutRequests(JSON.parse(localStorage.getItem(storageKey) || '{}')); } catch { return {}; } });
  const checkoutRequests = useRef<Record<string, string>>(initialCheckoutRequests);
  const [balance, setBalance] = useState<CreditBalance>({ balance: null, enforced: false });
  const [catalog, setCatalog] = useState<CreditCatalog>({ packs: [], sandbox: false });
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [buying, setBuying] = useState<string | null>(null);
  const [showPacks, setShowPacks] = useState(false);
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState('');
  const alive = useRef(true);
  const revision = useRef(0);
  const previousBalance = useRef<number | null>(null);
  const checkoutActive = useRef(false);
  const refresh = useCallback(async () => {
    const request = ++revision.current; setBusy(true);
    const results = await Promise.allSettled([command<unknown>('ai_credits'), command<unknown>('ai_credit_packs')]);
    if (!alive.current || request !== revision.current) return;
    const messages: string[] = [];
    if (results[0].status === 'fulfilled') {
      const next = parseCreditBalance(results[0].value); setBalance(next); setLoaded(true);
      if (previousBalance.current !== null && next.balance !== null && next.balance > previousBalance.current) {
        setWaiting(false); setNotice(`Balance updated: ${next.balance.toLocaleString()} credits available.`); previousBalance.current = null;
        checkoutRequests.current = {}; try { localStorage.removeItem(storageKey); } catch { /* Old completed IDs remain safe to retry. */ }
      }
    } else messages.push(describeError(results[0].reason));
    if (results[1].status === 'fulfilled') setCatalog(parseCreditCatalog(results[1].value));
    else messages.push(describeError(results[1].reason));
    setError(messages.length ? [...new Set(messages)].join(' ') : null); setBusy(false);
  }, [storageKey]);
  useEffect(() => { alive.current = true; return () => { alive.current = false; revision.current++; }; }, [owner]);
  useEffect(() => { void refresh(); }, [refresh, refreshToken]);
  useEffect(() => { if (openCatalogToken > 0) setShowPacks(true); }, [openCatalogToken]);
  useEffect(() => {
    let stop: (() => void) | undefined; let mounted = true;
    const onReturn = () => { if (document.visibilityState === 'visible') void refresh(); };
    window.addEventListener('focus', onReturn); document.addEventListener('visibilitychange', onReturn);
    if (isNative()) getCurrentWindow().onFocusChanged(event => { if (event.payload) onReturn(); }).then(unlisten => { if (mounted) stop = unlisten; else unlisten(); }).catch(() => {});
    return () => { mounted = false; stop?.(); window.removeEventListener('focus', onReturn); document.removeEventListener('visibilitychange', onReturn); };
  }, [refresh]);
  const buy = async (pack: CreditPack) => {
    if (checkoutActive.current || !pack.available || !formatCreditPrice(pack)) return;
    checkoutActive.current = true; setBuying(pack.id); setError(null); setNotice('');
    try {
      const requestId = Object.hasOwn(checkoutRequests.current, pack.id) ? checkoutRequests.current[pack.id] : crypto.randomUUID();
      checkoutRequests.current[pack.id] = requestId;
      // Save before sending so network timeouts and app restarts reuse the same
      // server-side checkout intent rather than create another payable order.
      localStorage.setItem(storageKey, JSON.stringify(checkoutRequests.current));
      const checkout = await command<unknown>('ai_checkout', { pack: pack.id, requestId });
      if (!alive.current) return;
      const url = checkoutUrl(checkout);
      await command('open_external', { url });
      if (!alive.current) return;
      previousBalance.current = balance.balance; setWaiting(true);
      setNotice('Checkout opened in your browser. After paying, return here and refresh your balance.');
    } catch (cause) {
      if (alive.current) {
        const message = describeError(cause); setError(message);
        if (/purchase is complete/i.test(message)) {
          delete checkoutRequests.current[pack.id];
          try { localStorage.setItem(storageKey, JSON.stringify(checkoutRequests.current)); } catch { /* Keeping a completed ID cannot create a second order. */ }
          void refresh();
        }
      }
    }
    finally { checkoutActive.current = false; if (alive.current) setBuying(null); }
  };
  return <section className="ai-credits" aria-label="Ask AI credits"><div className="credit-strip"><Coins size={13} /><span>{balance.balance !== null ? `${balance.balance.toLocaleString()} credits` : busy ? 'Checking credits…' : loaded && !balance.enforced ? 'Credits not required' : 'Balance unavailable'}</span><IconButton label="Refresh credit balance" disabled={busy || Boolean(buying)} onClick={() => void refresh()}><RefreshCw size={12} className={busy ? 'spin' : ''} /></IconButton><button className="text-button" aria-expanded={showPacks} onClick={() => setShowPacks(!showPacks)}>{showPacks ? 'Close' : 'Buy credits'}</button></div>{showPacks ? <div className="credit-packs"><header><h3>Ask AI credits</h3><IconButton label="Close credit packs" onClick={() => setShowPacks(false)}><X size={13} /></IconButton></header><p>One credit buys one answer, including a follow-up. Purchased credits never expire.</p>{catalog.sandbox ? <div className="sandbox-label">Test checkout — no real payment</div> : null}{catalog.packs.length ? catalog.packs.map(pack => { const price = formatCreditPrice(pack); return <article className="credit-pack" key={pack.id}><div><strong>{pack.name}</strong><small>{pack.credits.toLocaleString()} answers</small></div>{pack.available && price ? <button className="button small" disabled={Boolean(buying) || waiting} onClick={() => void buy(pack)} aria-label={`Buy ${pack.name}, ${pack.credits} credits for ${price}`}>{buying === pack.id ? <Spinner label="Opening…" /> : <>{price}<ExternalLink size={11} /></>}</button> : <small>Unavailable</small>}</article>; }) : <p className="credit-empty">{busy ? 'Loading credit packs…' : 'Credit packs are not available yet.'}</p>}{waiting ? <div className="credit-waiting"><p>Waiting for server confirmation. You can keep reading; use Refresh balance when you return.</p><button className="text-button" onClick={() => { setWaiting(false); previousBalance.current = null; setNotice('Checkout notice dismissed. Only a server-confirmed payment can add credits.'); }}>I cancelled checkout</button></div> : null}<small className="purchase-detail">One-time purchases. No subscription or automatic top-ups. Prices include tax. Payment opens in your browser; credits appear after payment is confirmed.</small><button className="text-button credit-refresh" disabled={busy || Boolean(buying)} onClick={() => void refresh()}><RefreshCw size={12} />Refresh balance</button></div> : null}{notice ? <p className="credit-notice" role="status">{notice}</p> : null}{error ? <p className="credit-error" role="alert">{error}</p> : null}</section>;
}
