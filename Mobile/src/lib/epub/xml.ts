import { XMLParser } from 'fast-xml-parser';

/**
 * Thin element tree over fast-xml-parser's `preserveOrder` output, with the
 * handful of queries the package and navigation parsers need.
 */
export type XMLNode = {
  name: string;
  attributes: Record<string, string>;
  children: XMLNode[];
  text: string;
};

const parser = new XMLParser({
  preserveOrder: true,
  ignoreAttributes: false,
  attributeNamePrefix: '',
  removeNSPrefix: true,
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: false,
  processEntities: true,
  htmlEntities: true,
});

type RawNode = Record<string, unknown>;

function convert(raw: RawNode): XMLNode | null {
  const keys = Object.keys(raw).filter((key) => key !== ':@');
  const name = keys[0];
  if (!name) return null;
  if (name === '#text') {
    return { name: '#text', attributes: {}, children: [], text: String(raw['#text'] ?? '') };
  }
  const attributes = (raw[':@'] as Record<string, unknown> | undefined) ?? {};
  const rawChildren = (raw[name] as RawNode[] | undefined) ?? [];
  const children = rawChildren.map(convert).filter((node): node is XMLNode => node !== null);
  const stringAttributes: Record<string, string> = {};
  for (const [key, value] of Object.entries(attributes)) {
    stringAttributes[key] = String(value);
  }
  return { name, attributes: stringAttributes, children, text: '' };
}

export function parseXML(source: string): XMLNode {
  const parsed = parser.parse(source) as RawNode[];
  const children = parsed.map(convert).filter((node): node is XMLNode => node !== null);
  return { name: '#document', attributes: {}, children, text: '' };
}

export function attr(node: XMLNode | undefined, name: string): string | undefined {
  return node?.attributes[name];
}

export function childrenNamed(node: XMLNode | undefined, name: string): XMLNode[] {
  return node?.children.filter((child) => child.name === name) ?? [];
}

export function firstChild(node: XMLNode | undefined, name: string): XMLNode | undefined {
  return node?.children.find((child) => child.name === name);
}

export function descendants(node: XMLNode | undefined, name: string): XMLNode[] {
  const found: XMLNode[] = [];
  const walk = (current: XMLNode) => {
    for (const child of current.children) {
      if (child.name === name) found.push(child);
      walk(child);
    }
  };
  if (node) walk(node);
  return found;
}

export function firstDescendant(node: XMLNode | undefined, name: string): XMLNode | undefined {
  return descendants(node, name)[0];
}

/** All text beneath the node, whitespace collapsed. */
export function collectedText(node: XMLNode | undefined): string {
  if (!node) return '';
  const parts: string[] = [];
  const walk = (current: XMLNode) => {
    if (current.name === '#text') parts.push(current.text);
    for (const child of current.children) walk(child);
  };
  walk(node);
  return parts.join('').replace(/\s+/g, ' ').trim();
}
