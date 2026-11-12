export interface NoteReference { kind: 'sketch' | 'audio' | 'reminder'; id: string; line: string }
export function notePreviewText(markdown: string): string {
  return markdown
    .replace(/!?\[((?:\\.|[^\]\\])*)\]\((?:\\.|[^)\\])*\)/g, '$1')
    .replace(/^[ \t]{0,3}(?:`{3,}|~{3,})[^\n]*$/gm, '')
    .replace(/(^|\n)[ \t]{0,3}(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+)/g, '$1')
    .replace(/\*\*|__|~~|`+/g, '')
    .replace(/\\([\\`*_[\]{}()#+.!|>~-])/g, '$1')
    .replace(/\s+/g, ' ').trim();
}
export function noteReferences(markdown: string): NoteReference[] {
  const references: NoteReference[] = [];
  let fence: { marker: string; length: number } | null = null;
  for (const line of markdown.split(/\r?\n/)) {
    const trimmed = line.trimStart();
    const marker = /^(`{3,}|~{3,})/.exec(trimmed)?.[0];
    if (marker) {
      if (!fence) fence = { marker: marker[0], length: marker.length };
      else if (marker[0] === fence.marker && marker.length >= fence.length && !trimmed.slice(marker.length).trim()) fence = null;
      continue;
    }
    if (fence) continue;
    const match = /^\[((?:\\.|[^\]\\])*)\]\(kodi-(sketch|audio|reminder):\/\/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\)$/i.exec(line);
    if (match) references.push({ kind: match[2].toLowerCase() as NoteReference['kind'], id: match[3].toLowerCase(), line });
  }
  return references;
}
export function removeNoteReference(markdown: string, kind: NoteReference['kind'], id: string): string {
  const matching = new Set(noteReferences(markdown).filter(reference => reference.kind === kind && reference.id === id.toLowerCase()).map(reference => reference.line));
  let fence: { marker: string; length: number } | null = null;
  return markdown.split(/\r?\n/).filter(line => {
    const trimmed = line.trimStart(); const marker = /^(`{3,}|~{3,})/.exec(trimmed)?.[0];
    if (marker) { if (!fence) fence = { marker: marker[0], length: marker.length }; else if (marker[0] === fence.marker && marker.length >= fence.length && !trimmed.slice(marker.length).trim()) fence = null; return true; }
    return fence || !matching.has(line);
  }).join('\n');
}

export function renameNoteReference(markdown: string, kind: NoteReference['kind'], id: string, title: string): string {
  const matching = new Set(noteReferences(markdown).filter(reference => reference.kind === kind && reference.id === id.toLowerCase()).map(reference => reference.line));
  const label = title.replace(/[\r\n]+/g, ' ').replace(/[\\[\]]/g, '\\$&');
  let fence: { marker: string; length: number } | null = null;
  return markdown.split(/\r?\n/).map(line => {
    const marker = /^(`{3,}|~{3,})/.exec(line.trimStart())?.[0];
    if (marker) { if (!fence) fence = { marker: marker[0], length: marker.length }; else if (marker[0] === fence.marker && marker.length >= fence.length && !line.trimStart().slice(marker.length).trim()) fence = null; return line; }
    if (fence || !matching.has(line)) return line;
    return `[${label}]${line.slice(line.lastIndexOf('](') + 1)}`;
  }).join('\n');
}

export function insertAudioTranscript(markdown: string, id: string, transcript: string): string | null {
  const text = transcript.replace(/\r\n?/g, '\n').trim();
  const reference = noteReferences(markdown).find(item => item.kind === 'audio' && item.id === id.toLowerCase());
  if (!text || !reference) return null;
  const encoded = text.replace(/([\\`*_[\]{}<>#+.!|~-])/g, '\\$1');
  let fence: { marker: string; length: number } | null = null;
  const lines = markdown.split(/\r?\n/);
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]; const marker = /^(`{3,}|~{3,})/.exec(line.trimStart())?.[0];
    if (marker) { if (!fence) fence = { marker: marker[0], length: marker.length }; else if (marker[0] === fence.marker && marker.length >= fence.length && !line.trimStart().slice(marker.length).trim()) fence = null; continue; }
    if (!fence && line === reference.line) {
      const prefix = lines.slice(0, index + 1).join('\n'); const suffix = lines.slice(index + 1).join('\n');
      return `${prefix}\n\n${encoded}${suffix.startsWith('\n') ? '\n' : '\n\n'}${suffix}`;
    }
  }
  return null;
}
