import { File, Paths } from 'expo-file-system';
import * as Sharing from 'expo-sharing';

import type { Annotation, BookRecord } from './types';

function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
}

function noteMarkdown(book: BookRecord, annotation: Annotation): string {
  const lines = [
    `### ${annotation.text.length > 80 ? `${annotation.text.slice(0, 80)}…` : annotation.text}`,
    '',
    `> ${annotation.text.replace(/\n/g, '\n> ')}`,
    '',
    `*${book.title}* by ${book.author}${annotation.chapterTitle ? ` · ${annotation.chapterTitle}` : ''} · ${formatDate(annotation.createdAt)}`,
  ];
  if (annotation.note?.trim()) {
    lines.push('', annotation.note.trim());
  }
  return lines.join('\n');
}

/** Markdown export matching the macOS app's notes export. */
export function notesMarkdown(books: BookRecord[]): string {
  const sections = books
    .filter((book) => book.annotations.length > 0)
    .map((book) => {
      const notes = [...book.annotations]
        .sort((a, b) => a.locator.spineIndex - b.locator.spineIndex)
        .map((annotation) => noteMarkdown(book, annotation));
      return [`## ${book.title}`, '', ...notes.flatMap((note) => [note, ''])].join('\n');
    });
  return ['# Kodi Reader notes', '', ...sections].join('\n');
}

export async function shareNotes(books: BookRecord[], fileName = 'Kodi Notes.md') {
  const file = new File(Paths.cache, fileName);
  if (file.exists) file.delete();
  file.write(notesMarkdown(books));
  if (await Sharing.isAvailableAsync()) {
    await Sharing.shareAsync(file.uri, { mimeType: 'text/markdown', UTI: 'net.daringfireball.markdown' });
  }
}
