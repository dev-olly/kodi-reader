// A command belongs to the view that issued it. An old view may finish work
// after navigation, but its failures must not become errors on the next view.
export async function runReaderCommand(
  perform: () => Promise<unknown>,
  isCurrent: () => boolean,
): Promise<void> {
  if (!isCurrent()) return;
  try { await perform(); }
  catch (error) { if (isCurrent()) throw error; }
}

export async function openReaderPublication<Session, Publication>(
  open: () => Promise<Session>,
  publication: () => Promise<Publication>,
  isCurrent: () => boolean,
): Promise<{ session: Session; publication: Publication } | null> {
  const session = await open();
  if (!isCurrent()) return null;
  // Native opening can download missing bytes. Parsing the publication is a
  // dependent operation, including when reopening an offline-removed book.
  const parsed = await publication();
  return isCurrent() ? { session, publication: parsed } : null;
}

export function pdfPageTarget(href: string, totalPages: number): number | null {
  const match = /^#page=(\d+)$/i.exec(href);
  if (!match || !Number.isSafeInteger(totalPages) || totalPages < 1) return null;
  const page = Number(match[1]);
  return Number.isSafeInteger(page) && page >= 1 && page <= totalPages ? page - 1 : null;
}

export function resolveEpubHref(
  href: string,
  readingOrder: { href: string }[],
  currentSpine: number,
  source: 'publication' | 'chapter' = 'publication',
): { spineIndex: number; fragment: string | null } | null {
  const current = readingOrder[currentSpine];
  if (!current) return null;
  const delimiter = href.indexOf('#');
  const path = (delimiter < 0 ? href : href.slice(0, delimiter)).split('?')[0];
  const fragment = delimiter < 0 ? null : href.slice(delimiter + 1);
  try {
    const currentPath = current.href.split('#')[0];
    const origin = 'https://book.invalid/';
    const base = source === 'chapter' ? new URL(currentPath, origin) : new URL(origin);
    const resolved = path ? new URL(path, base) : new URL(currentPath, origin);
    if (resolved.origin !== new URL(origin).origin) return null;
    const pathKey = decodeURIComponent(resolved.pathname.slice(1));
    const spineIndex = readingOrder.findIndex(item => decodeURIComponent(item.href.split('#')[0]) === pathKey);
    return spineIndex < 0 ? null : { spineIndex, fragment: fragment === null ? null : decodeURIComponent(fragment) };
  } catch { return null; }
}
