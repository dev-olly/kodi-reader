/**
 * Path arithmetic for locations inside an EPUB archive. EPUB hrefs are
 * relative URL references resolved against the document that contains them;
 * archive entry names are plain, slash-separated strings.
 */

export function directoryOf(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.slice(0, slash);
}

export function splitFragment(href: string): { path: string; fragment?: string } {
  const hash = href.indexOf('#');
  if (hash < 0) return { path: href };
  const fragment = href.slice(hash + 1);
  return { path: href.slice(0, hash), fragment: fragment ? fragment : undefined };
}

export function normalizePath(path: string): string {
  const stack: string[] = [];
  for (const segment of path.split('/')) {
    if (!segment || segment === '.') continue;
    if (segment === '..') {
      stack.pop();
      continue;
    }
    stack.push(segment);
  }
  return stack.join('/');
}

export function resolveHref(href: string, base: string): string {
  const raw = splitFragment(href).path;
  let decoded = raw;
  try {
    decoded = decodeURIComponent(raw);
  } catch {
    decoded = raw;
  }
  if (decoded.startsWith('/')) return normalizePath(decoded.slice(1));
  const baseDirectory = directoryOf(base);
  return normalizePath(baseDirectory ? `${baseDirectory}/${decoded}` : decoded);
}

export function extensionOf(path: string): string {
  const dot = path.lastIndexOf('.');
  const slash = path.lastIndexOf('/');
  return dot > slash ? path.slice(dot + 1).toLowerCase() : '';
}

export function isHTMLDocument(mediaType: string, path: string): boolean {
  if (mediaType === 'application/xhtml+xml' || mediaType === 'text/html') return true;
  return ['xhtml', 'xht', 'html', 'htm'].includes(extensionOf(path));
}
