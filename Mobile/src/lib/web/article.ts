import { File, Paths } from 'expo-file-system';
import { strToU8, zipSync, type Zippable } from 'fflate';

/**
 * Reader-mode articles saved from the in-app browser, packaged as a
 * single-chapter EPUB 3 so they flow through the same import path as books.
 * Ported from the Mac app's ArticleEPUBBuilder and WebPageURL.
 */

export type ArticleContent = {
  title: string;
  byline?: string;
  sourceURL: string;
  contentHTML: string;
  language?: string;
};

export const MAX_IMAGE_COUNT = 40;
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

export class ArticleError extends Error {}

// URL helpers -----------------------------------------------------------------

export function normalizedWebURL(input: string): string | null {
  let trimmed = input.trim();
  if (!trimmed) return null;
  if (!trimmed.includes('://')) trimmed = `https://${trimmed}`;
  try {
    const url = new URL(trimmed);
    return isAllowedWebURL(url) ? url.toString() : null;
  } catch {
    return null;
  }
}

export function isAllowedWebURL(url: URL): boolean {
  return (url.protocol === 'http:' || url.protocol === 'https:') && Boolean(url.hostname);
}

/** Stable identifier for a page, so re-saving replaces the entry instead of duplicating it. */
export function webPageIdentifier(sourceURL: string): string {
  return `web:${canonicalWebURL(sourceURL)}`;
}

export function canonicalWebURL(sourceURL: string): string {
  try {
    const url = new URL(sourceURL);
    url.hash = '';
    url.username = '';
    url.password = '';
    url.protocol = url.protocol.toLowerCase();
    url.hostname = url.hostname.toLowerCase();
    if ((url.protocol === 'https:' && url.port === '443') || (url.protocol === 'http:' && url.port === '80')) url.port = '';
    if (url.pathname.length > 1 && url.pathname.endsWith('/')) url.pathname = url.pathname.slice(0, -1);
    return url.toString();
  } catch {
    return sourceURL;
  }
}

export function hostOf(sourceURL: string): string {
  try {
    return new URL(sourceURL).hostname;
  } catch {
    return sourceURL;
  }
}

// HTML helpers ----------------------------------------------------------------

const REMOVED_BLOCKS = ['script', 'style', 'iframe', 'object', 'embed', 'form', 'noscript'];
const VOID_TAGS = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'];

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function stripUnsafe(html: string): string {
  let result = html;
  for (const name of REMOVED_BLOCKS) {
    result = result.replace(new RegExp(`<${name}\\b[^>]*>[\\s\\S]*?</${name}\\s*>`, 'gi'), '');
    result = result.replace(new RegExp(`<${name}\\b[^>]*/?>`, 'gi'), '');
  }
  return result.replace(/\son[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, '');
}

function selfClose(tag: string, html: string): string {
  return html.replace(new RegExp(`<${tag}\\b([^>]*)>`, 'gi'), (full, attrs: string) => {
    if (full.endsWith('/>')) return full;
    let trimmed = attrs.trim();
    if (trimmed.endsWith('/')) trimmed = trimmed.slice(0, -1).trim();
    return trimmed ? `<${tag} ${trimmed}/>` : `<${tag}/>`;
  });
}

export function toXHTMLFragment(html: string): string {
  let result = html.replace(/&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);)/g, '&amp;');
  for (const tag of VOID_TAGS) result = selfClose(tag, result);
  return result;
}

export function imageSources(html: string): string[] {
  const sources: string[] = [];
  const regex = /<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(html)) !== null) {
    const source = match[1] || match[2] || match[3];
    if (source) sources.push(source);
  }
  return sources;
}

function replaceImageSource(source: string, href: string, html: string): string {
  const escaped = escapeRegExp(source);
  return html.replace(new RegExp(`(<img\\b[^>]*?\\bsrc\\s*=\\s*)(?:"${escaped}"|'${escaped}'|${escaped})`, 'gi'), `$1"${href}"`);
}

function removeImages(source: string, html: string): string {
  const escaped = escapeRegExp(source);
  return html.replace(new RegExp(`<img\\b[^>]*?\\bsrc\\s*=\\s*(?:"${escaped}"|'${escaped}'|${escaped})[^>]*/?>`, 'gi'), '');
}

function stripAttribute(name: string, html: string): string {
  return html.replace(new RegExp(`\\s${name}\\s*=\\s*("[^"]*"|'[^']*'|[^\\s>]+)`, 'gi'), '');
}

export function xmlEscape(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

// Images ----------------------------------------------------------------------

type InlinedImage = { href: string; mediaType: string; data: Uint8Array; itemID: string };

function extensionForMIME(mime: string): string {
  switch (mime.toLowerCase()) {
    case 'image/jpeg':
    case 'image/jpg':
      return 'jpg';
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    case 'image/svg+xml':
      return 'svg';
    case 'image/avif':
      return 'avif';
    default:
      return 'img';
  }
}

function hashBytes(data: Uint8Array): string {
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  for (let i = 0; i < data.length; i += 1) {
    h1 = Math.imul(h1 ^ data[i], 0x01000193) >>> 0;
    h2 = Math.imul(h2 + data[i], 0x9e3779b1) >>> 0;
  }
  return `${h1.toString(16).padStart(8, '0')}${h2.toString(16).padStart(8, '0')}`;
}

function makeInlinedImage(data: Uint8Array, mediaType: string): InlinedImage {
  const name = hashBytes(data);
  return { href: `images/${name}.${extensionForMIME(mediaType)}`, mediaType, data, itemID: `img-${name}` };
}

function decodeBase64(payload: string): Uint8Array {
  const clean = payload.replace(/[^A-Za-z0-9+/=]/g, '');
  const binary = globalThis.atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function inlinedDataURL(source: string): InlinedImage | null {
  const comma = source.indexOf(',');
  if (comma < 0) return null;
  const header = source.slice(0, comma);
  const payload = source.slice(comma + 1);
  const mime = header.slice('data:'.length).split(';')[0] || 'image/png';
  if (!mime.startsWith('image/')) return null;
  try {
    const data = header.toLowerCase().includes(';base64') ? decodeBase64(payload) : strToU8(decodeURIComponent(payload));
    if (data.length <= 16 || data.length > MAX_IMAGE_BYTES) return null;
    return makeInlinedImage(data, mime);
  } catch {
    return null;
  }
}

async function downloadImage(source: string, sourceURL: string): Promise<InlinedImage | null> {
  if (source.toLowerCase().startsWith('data:')) return inlinedDataURL(source);
  let resolved: URL;
  try {
    resolved = new URL(source, sourceURL);
  } catch {
    return null;
  }
  if (!isAllowedWebURL(resolved)) return null;
  try {
    const response = await fetch(resolved.toString());
    if (!response.ok) return null;
    const mime = (response.headers.get('content-type') ?? '').split(';')[0].trim() || guessImageMime(resolved.pathname);
    if (!mime.startsWith('image/')) return null;
    const buffer = await response.arrayBuffer();
    if (buffer.byteLength <= 16 || buffer.byteLength > MAX_IMAGE_BYTES) return null;
    return makeInlinedImage(new Uint8Array(buffer), mime);
  } catch {
    return null;
  }
}

function guessImageMime(path: string): string {
  const ext = path.split('.').pop()?.toLowerCase() ?? '';
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    case 'avif':
      return 'image/avif';
    default:
      return 'application/octet-stream';
  }
}

async function inlineImages(html: string, sourceURL: string): Promise<{ html: string; images: InlinedImage[] }> {
  const unique = Array.from(new Set(imageSources(html)));
  if (unique.length === 0) return { html, images: [] };
  const limited = unique.slice(0, MAX_IMAGE_COUNT);
  const results = await Promise.all(limited.map(async (source) => [source, await downloadImage(source, sourceURL)] as const));

  const hrefBySource = new Map<string, string>();
  const images: InlinedImage[] = [];
  const seen = new Set<string>();
  for (const [source, image] of results) {
    if (!image) continue;
    hrefBySource.set(source, image.href);
    if (!seen.has(image.itemID)) {
      seen.add(image.itemID);
      images.push(image);
    }
  }

  let rewritten = html;
  for (const source of unique) {
    const href = hrefBySource.get(source);
    rewritten = href ? replaceImageSource(source, href, rewritten) : removeImages(source, rewritten);
  }
  rewritten = stripAttribute('srcset', rewritten);
  rewritten = stripAttribute('sizes', rewritten);
  return { html: rewritten, images };
}

// Documents -------------------------------------------------------------------

const CONTAINER_XML = `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`;

function packageDocument(p: { identifier: string; title: string; author: string; language: string; sourceURL: string; modified: string; images: InlinedImage[] }): string {
  const imageItems = p.images
    .map((image) => `    <item id="${xmlEscape(image.itemID)}" href="${xmlEscape(image.href)}" media-type="${xmlEscape(image.mediaType)}"/>`)
    .join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">${xmlEscape(p.identifier)}</dc:identifier>
    <dc:title>${xmlEscape(p.title)}</dc:title>
    <dc:creator>${xmlEscape(p.author)}</dc:creator>
    <dc:language>${xmlEscape(p.language)}</dc:language>
    <dc:source>${xmlEscape(p.sourceURL)}</dc:source>
    <meta property="dcterms:modified">${p.modified}</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
${imageItems}
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
`;
}

function navDocument(title: string, language: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="${xmlEscape(language)}" xml:lang="${xmlEscape(language)}">
<head><title>${xmlEscape(title)}</title></head>
<body>
  <nav epub:type="toc">
    <ol>
      <li><a href="chapter.xhtml">${xmlEscape(title)}</a></li>
    </ol>
  </nav>
</body>
</html>
`;
}

function chapterDocument(title: string, author: string, language: string, sourceURL: string, body: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="${xmlEscape(language)}" xml:lang="${xmlEscape(language)}">
<head>
  <title>${xmlEscape(title)}</title>
</head>
<body>
  <h1>${xmlEscape(title)}</h1>
  <p>${xmlEscape(author)} · <a href="${xmlEscape(sourceURL)}">${xmlEscape(hostOf(sourceURL))}</a></p>
  ${body}
</body>
</html>
`;
}

export function resolvedTitle(article: ArticleContent): string {
  const trimmed = article.title.trim();
  return trimmed || hostOf(article.sourceURL);
}

export function resolvedAuthor(article: ArticleContent): string {
  const trimmed = (article.byline ?? '').trim();
  return trimmed || hostOf(article.sourceURL) || 'Web';
}

/**
 * Builds the EPUB in the cache directory and returns its file URI, ready for
 * `importDocument`. Images are downloaded and inlined so the snapshot works
 * offline.
 */
export async function buildArticleEPUB(article: ArticleContent): Promise<{ uri: string; fileName: string }> {
  if (!article.contentHTML.trim()) throw new ArticleError('Could not extract an article from this page.');
  const title = resolvedTitle(article);
  const author = resolvedAuthor(article);
  const language = (article.language ?? '').trim().slice(0, 16) || 'en';

  const { html, images } = await inlineImages(stripUnsafe(article.contentHTML), article.sourceURL);
  const chapter = chapterDocument(title, author, language, article.sourceURL, toXHTMLFragment(html));
  const modified = new Date().toISOString().replace(/\.\d+Z$/, 'Z');

  const entries: Zippable = {
    mimetype: [strToU8('application/epub+zip'), { level: 0 }],
    'META-INF/container.xml': strToU8(CONTAINER_XML),
    'OEBPS/content.opf': strToU8(packageDocument({ identifier: webPageIdentifier(article.sourceURL), title, author, language, sourceURL: article.sourceURL, modified, images })),
    'OEBPS/nav.xhtml': strToU8(navDocument(title, language)),
    'OEBPS/chapter.xhtml': strToU8(chapter),
  };
  for (const image of images) entries[`OEBPS/${image.href}`] = image.data;

  const zipped = zipSync(entries, { level: 6 });
  const fileName = `${title.replace(/[^A-Za-z0-9 _-]+/g, ' ').trim().slice(0, 60) || 'Web page'}.epub`;
  const file = new File(Paths.cache, `kodi-web-${Date.now()}.epub`);
  if (file.exists) file.delete();
  file.write(zipped);
  return { uri: file.uri, fileName };
}
