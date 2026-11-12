export interface CreditBalance { balance: number | null; enforced: boolean }
export interface CreditPack { id: string; name: string; credits: number; amount: number | null; available: boolean; currency: string }
export interface CreditCatalog { packs: CreditPack[]; sandbox: boolean }
export function parseCreditBalance(value: unknown): CreditBalance {
  const data = value && typeof value === 'object' ? value as Record<string, unknown> : {};
  const count = typeof data.available === 'number' ? data.available : data.balance;
  return { balance: typeof count === 'number' && Number.isSafeInteger(count) ? Math.max(0, count) : null, enforced: data.enforced === true };
}
export function parseCreditCatalog(value: unknown): CreditCatalog {
  const data = value && typeof value === 'object' ? value as Record<string, unknown> : {};
  const packs: CreditPack[] = [];
  for (const pack of Array.isArray(data.packs) ? data.packs : []) {
    if (!pack || typeof pack !== 'object' || typeof pack.id !== 'string' || !pack.id || typeof pack.name !== 'string' || !Number.isSafeInteger(pack.credits) || pack.credits < 1) continue;
    const amount = Number.isSafeInteger(pack.amount) && pack.amount >= 0 ? pack.amount : null;
    const currency = typeof pack.currency === 'string' && /^[A-Z]{3}$/.test(pack.currency) ? pack.currency : 'EUR';
    packs.push({ id: pack.id, name: pack.name, credits: pack.credits, amount, available: pack.available === true && amount !== null, currency });
  }
  return { packs, sandbox: data.sandbox === true };
}
export function formatCreditPrice(pack: CreditPack): string | null {
  if (pack.amount === null) return null;
  try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: pack.currency }).format(pack.amount / 100); }
  catch { return null; }
}
export function checkoutUrl(value: unknown): string {
  const raw = value && typeof value === 'object' ? (value as Record<string, unknown>).url : null;
  if (typeof raw !== 'string') throw new Error('Checkout did not return a browser address. Please try again.');
  const url = new URL(raw);
  if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Checkout returned an invalid browser address. Please try again.');
  return url.toString();
}
export function draftAfterFailedAnswer(current: string, submitted: string, received: string): string {
  return !received.trim() && !current.trim() ? submitted : current;
}
export function isCreditError(error: string): boolean { return /\b402\b|insufficient_credits|no credits|out of credits/i.test(error); }

export interface ActiveAIRequest { requestId: string | null; threadId: string; submitted: string; received: string; sending: boolean }
export function matchesAIRequest(event: { requestId?: string; bookId?: string; threadId?: string }, request: ActiveAIRequest, bookId: string): boolean {
  return request.sending && (!event.bookId || event.bookId === bookId) && (!event.threadId || event.threadId === request.threadId) && (!event.requestId || !request.requestId || event.requestId === request.requestId);
}

export function validCheckoutRequests(value: unknown): Record<string, string> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).filter(([pack, id]) => /^[a-z0-9][a-z0-9_-]{0,63}$/i.test(pack) && typeof id === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id))) as Record<string, string>;
}
