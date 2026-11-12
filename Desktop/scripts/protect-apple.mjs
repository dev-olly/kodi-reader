import { createHash } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(desktop, '..');
const manifest = JSON.parse(readFileSync(resolve(desktop, 'protected-apple.json'), 'utf8'));
const changed = Object.entries(manifest.files).filter(([path, expected]) => {
  const absolute = resolve(root, path);
  // Recorded commit hashes also work in shallow CI checkouts. Missing tracked
  // files always fail; only originally untracked files may be absent in CI.
  const committed = manifest.committedFiles?.[path];
  if (!existsSync(absolute)) return !(process.env.CI && committed === null);
  const current = createHash('sha256').update(readFileSync(absolute)).digest('hex');
  return current !== expected && !(process.env.CI && typeof committed === 'string' && current === committed);
}).map(([path]) => path);
if (changed.length) { console.error(`Protected Apple files changed:\n${changed.join('\n')}`); process.exitCode = 1; }
else console.log(`Verified ${Object.keys(manifest.files).length} Apple files unchanged, including pre-existing edits.`);
