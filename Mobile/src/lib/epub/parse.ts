import { directoryOf, normalizePath, resolveHref, splitFragment } from './path';
import { attr, childrenNamed, collectedText, descendants, firstChild, firstDescendant, parseXML, type XMLNode } from './xml';
import type { ManifestItem, Publication, SpineItem, TOCEntry } from '../types';

/** Reads entries out of an extracted archive by archive-relative path. */
export type EntrySource = {
  exists(path: string): boolean;
  text(path: string): string;
  size(path: string): number;
};

export class EPUBParseError extends Error {}

export function packagePath(source: EntrySource): string {
  const containerPath = 'META-INF/container.xml';
  if (!source.exists(containerPath)) {
    throw new EPUBParseError('This file is missing META-INF/container.xml, so it is not an EPUB.');
  }
  const root = parseXML(source.text(containerPath));
  const rootFiles = descendants(root, 'rootfile');
  const preferred =
    rootFiles.find((node) => attr(node, 'media-type') === 'application/oebps-package+xml') ?? rootFiles[0];
  const fullPath = attr(preferred, 'full-path');
  if (!fullPath) throw new EPUBParseError('The EPUB container does not name a package document.');
  return normalizePath(fullPath);
}

type Package = {
  title: string;
  creators: string[];
  identifier?: string;
  language?: string;
  coverItemID?: string;
  manifest: Record<string, ManifestItem>;
  spine: SpineItem[];
  pageProgression: 'ltr' | 'rtl';
  ncxItemID?: string;
};

function parseManifest(root: XMLNode, opfPath: string): Record<string, ManifestItem> {
  const manifestElement = firstDescendant(root, 'manifest');
  const items: Record<string, ManifestItem> = {};
  for (const element of childrenNamed(manifestElement, 'item')) {
    const id = attr(element, 'id');
    const href = attr(element, 'href');
    if (!id || !href) continue;
    const properties = (attr(element, 'properties') ?? '').split(/\s+/).filter(Boolean);
    items[id] = {
      id,
      path: resolveHref(href, opfPath),
      mediaType: attr(element, 'media-type') ?? 'application/octet-stream',
      properties: new Set(properties),
    };
  }
  return items;
}

function parsePackage(opfPath: string, source: EntrySource): Package {
  if (!source.exists(opfPath)) {
    throw new EPUBParseError(`The package document ${opfPath} is missing from the archive.`);
  }
  const root = parseXML(source.text(opfPath));
  const manifest = parseManifest(root, opfPath);

  const metadata = firstDescendant(root, 'metadata');
  const value = (name: string) => {
    const text = collectedText(firstChild(metadata, name));
    return text ? text : undefined;
  };
  const creators = childrenNamed(metadata, 'creator')
    .map(collectedText)
    .filter(Boolean);
  const coverMeta = childrenNamed(metadata, 'meta').find((node) => attr(node, 'name') === 'cover');
  const coverID = attr(coverMeta, 'content');

  const spineElement = firstDescendant(root, 'spine');
  const spine: SpineItem[] = childrenNamed(spineElement, 'itemref')
    .map((element) => {
      const idref = attr(element, 'idref');
      const item = idref ? manifest[idref] : undefined;
      if (!idref || !item) return null;
      return {
        idref,
        path: item.path,
        mediaType: item.mediaType,
        isLinear: attr(element, 'linear') !== 'no',
      };
    })
    .filter((item): item is SpineItem => item !== null);

  if (spine.length === 0) throw new EPUBParseError('The EPUB has an empty spine, so there is nothing to read.');

  const progression = attr(spineElement, 'page-progression-direction') === 'rtl' ? 'rtl' : 'ltr';

  return {
    title: value('title') ?? 'Untitled',
    creators,
    identifier: value('identifier'),
    language: value('language'),
    coverItemID: coverID && manifest[coverID] ? coverID : undefined,
    manifest,
    spine,
    pageProgression: progression,
    ncxItemID: attr(spineElement, 'toc'),
  };
}

let tocCounter = 0;
const nextTocID = () => `toc-${++tocCounter}`;

function parseOrderedList(list: XMLNode, documentPath: string): TOCEntry[] {
  return childrenNamed(list, 'li')
    .map((item): TOCEntry | null => {
      const anchor = firstChild(item, 'a') ?? firstChild(item, 'span');
      const nested = firstChild(item, 'ol');
      const title = collectedText(anchor);
      const children = nested ? parseOrderedList(nested, documentPath) : [];
      const href = attr(anchor, 'href');
      if (!href) {
        if (children.length === 0 || !title) return null;
        return { id: nextTocID(), title, path: '', children };
      }
      const { path, fragment } = splitFragment(href);
      return {
        id: nextTocID(),
        title: title || 'Untitled Section',
        path: resolveHref(path, documentPath),
        fragment,
        children,
      };
    })
    .filter((entry): entry is TOCEntry => entry !== null);
}

function parseNavigationDocument(path: string, source: EntrySource): TOCEntry[] {
  const root = parseXML(source.text(path));
  const navs = descendants(root, 'nav');
  const toc = navs.find((nav) => attr(nav, 'type') === 'toc') ?? navs.find((nav) => firstChild(nav, 'ol'));
  const list = firstChild(toc, 'ol');
  return list ? parseOrderedList(list, path) : [];
}

function parseNavPoints(parent: XMLNode, documentPath: string): TOCEntry[] {
  const points = childrenNamed(parent, 'navPoint');
  const ordered = [...points].sort((lhs, rhs) => {
    const l = Number.parseInt(attr(lhs, 'playOrder') ?? '', 10);
    const r = Number.parseInt(attr(rhs, 'playOrder') ?? '', 10);
    return (Number.isNaN(l) ? Number.MAX_SAFE_INTEGER : l) - (Number.isNaN(r) ? Number.MAX_SAFE_INTEGER : r);
  });
  return ordered
    .map((point): TOCEntry | null => {
      const src = attr(firstChild(point, 'content'), 'src');
      if (!src) return null;
      const title = collectedText(firstChild(firstChild(point, 'navLabel'), 'text'));
      const { path, fragment } = splitFragment(src);
      return {
        id: nextTocID(),
        title: title || 'Untitled Section',
        path: resolveHref(path, documentPath),
        fragment,
        children: parseNavPoints(point, documentPath),
      };
    })
    .filter((entry): entry is TOCEntry => entry !== null);
}

function parseNCX(path: string, source: EntrySource): TOCEntry[] {
  const root = parseXML(source.text(path));
  const navMap = firstDescendant(root, 'navMap');
  return navMap ? parseNavPoints(navMap, path) : [];
}

function parseTOC(pkg: Package, source: EntrySource): TOCEntry[] {
  const navItem = Object.values(pkg.manifest).find((item) => item.properties.has('nav'));
  if (navItem && source.exists(navItem.path)) {
    try {
      const entries = parseNavigationDocument(navItem.path, source);
      if (entries.length > 0) return entries;
    } catch {
      /* fall through to the NCX */
    }
  }
  const ncxItem =
    (pkg.ncxItemID ? pkg.manifest[pkg.ncxItemID] : undefined) ??
    Object.values(pkg.manifest).find((item) => item.mediaType === 'application/x-dtbncx+xml');
  if (ncxItem && source.exists(ncxItem.path)) {
    try {
      return parseNCX(ncxItem.path, source);
    } catch {
      return [];
    }
  }
  return [];
}

export function parsePublication(source: EntrySource): Publication {
  const opfPath = packagePath(source);
  const pkg = parsePackage(opfPath, source);
  const linear = pkg.spine.filter((item) => item.isLinear);
  const readingOrder = linear.length > 0 ? linear : pkg.spine;
  const toc = parseTOC(pkg, source);

  const coverFromMeta = pkg.coverItemID ? pkg.manifest[pkg.coverItemID]?.path : undefined;
  const coverFromProperty = Object.values(pkg.manifest).find((item) => item.properties.has('cover-image'))?.path;
  const coverPath = coverFromMeta ?? coverFromProperty;

  const weights = readingOrder.map((item) => Math.max(1, source.size(item.path)));

  return {
    title: pkg.title,
    creators: pkg.creators,
    identifier: pkg.identifier,
    language: pkg.language,
    manifest: pkg.manifest,
    readingOrder,
    toc,
    coverPath: coverPath && source.exists(coverPath) ? coverPath : undefined,
    packagePath: opfPath,
    pageProgression: pkg.pageProgression,
    weights,
  };
}

export function flattenTOC(entries: TOCEntry[], depth = 0): { entry: TOCEntry; depth: number }[] {
  return entries.flatMap((entry) => [{ entry, depth }, ...flattenTOC(entry.children, depth + 1)]);
}

/** Chapter title for a reading-order index: the nearest preceding TOC entry. */
export function chapterTitle(publication: Publication, spineIndex: number): string | undefined {
  const order = publication.readingOrder;
  if (spineIndex < 0 || spineIndex >= order.length) return undefined;
  const flat = flattenTOC(publication.toc).map(({ entry }) => entry);
  const exact = flat.find((entry) => entry.path === order[spineIndex].path);
  if (exact) return exact.title;
  for (let candidate = spineIndex - 1; candidate >= 0; candidate -= 1) {
    const match = flat.find((entry) => entry.path === order[candidate].path);
    if (match) return match.title;
  }
  return undefined;
}

export function spineIndexForPath(publication: Publication, path: string): number {
  return publication.readingOrder.findIndex((item) => item.path === path);
}

export { directoryOf };
