import { Parser } from 'htmlparser2';

/** Publisher scripts, frames, network requests, and base-URL overrides are disabled. */
export function chapterPolicy(nonce: string): string {
  return [
    "default-src 'none'",
    `script-src 'nonce-${nonce}'`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    "media-src 'self' data:",
    "connect-src 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join('; ');
}

/** Insert the policy before any publisher content, preserving body node indices. */
export function injectChapterHead(html: string, tags: string, nonce: string): string {
  if (!/^[A-Za-z0-9-]+$/.test(nonce)) throw new Error('Invalid reader script nonce.');
  let headEnd = -1;
  let unsafePrefix = false;
  const parser = new Parser({
    onopentag(name) {
      if (name === 'head') {
        headEnd = parser.endIndex + 1;
        parser.pause();
      } else if (name !== 'html') {
        unsafePrefix = true;
        parser.pause();
      }
    },
  });
  parser.end(html);
  if (unsafePrefix || headEnd < 0) throw new Error('This chapter must have a head before its content.');
  const policy = `<meta http-equiv="Content-Security-Policy" content="${chapterPolicy(nonce)}"/>`;
  return `${html.slice(0, headEnd)}${policy}\n${tags}\n${html.slice(headEnd)}`;
}
