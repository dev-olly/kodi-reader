import { createHash } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(desktop, '..');
const manifest = JSON.parse(readFileSync(resolve(desktop, 'protected-apple.json'), 'utf8'));
const upstreamFile = resolve(desktop, 'protected-apple-upstream-ci.json');
const inCI = process.env.CI === 'true';
if (inCI && existsSync(upstreamFile)) {
  const upstream = JSON.parse(readFileSync(upstreamFile, 'utf8'));
  if (upstream.version !== 1 || !/^[a-f0-9]{40}$/.test(upstream.sourceCommit ?? '') || !upstream.reason?.trim()
      || !Array.isArray(manifest.paths) || JSON.stringify(upstream.paths) !== JSON.stringify(manifest.paths)
      || !upstream.files || !Object.keys(upstream.files).length) throw new Error('Invalid pinned upstream Apple CI snapshot.');
  const covered = path => upstream.paths.some(prefix => path === prefix || path.startsWith(`${prefix}/`));
  for (const [path, hash] of Object.entries(upstream.files)) {
    if (!covered(path) || path.startsWith('/') || path.includes('\\') || path.includes(':') || path.split('/').some(part => !part || part === '.' || part === '..') || !/^[a-f0-9]{64}$/.test(hash)) throw new Error('Unsafe path/hash in upstream Apple CI snapshot.');
  }
  // Compare the complete tracked tree, never a per-file mixture of snapshots.
  // Git's index is available in a shallow checkout and excludes private local
  // build output/dependencies under otherwise protected source directories.
  const tracked = spawnSync('git', ['ls-files', '-z', '--', ...upstream.paths], { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (tracked.status !== 0 || tracked.error) throw new Error('Could not inventory the protected tracked Apple tree.');
  const actual = new Set(tracked.stdout.split('\0').filter(Boolean));
  const changed = [...new Set([...actual, ...Object.keys(upstream.files)])].filter(path => {
    if (!actual.has(path) || !upstream.files[path] || !existsSync(resolve(root, path))) return true;
    return createHash('sha256').update(readFileSync(resolve(root, path))).digest('hex') !== upstream.files[path];
  });
  if (changed.length) { console.error(`Protected Apple files differ from pinned upstream CI snapshot ${upstream.sourceCommit}:\n${changed.join('\n')}`); process.exitCode = 1; }
  else console.log(`Verified complete upstream Apple CI snapshot ${upstream.sourceCommit} (${actual.size} files). Original local boundary remains unchanged.`);
} else {
const changed = Object.entries(manifest.files).filter(([path, expected]) => {
  const absolute = resolve(root, path);
  // Recorded commit hashes also work in shallow CI checkouts. Missing tracked
  // files always fail; only originally untracked files may be absent in CI.
  const committed = manifest.committedFiles?.[path];
  if (!existsSync(absolute)) return !(inCI && committed === null);
  const current = createHash('sha256').update(readFileSync(absolute)).digest('hex');
  return current !== expected && !(inCI && typeof committed === 'string' && current === committed);
}).map(([path]) => path);
if (changed.length) { console.error(`Protected Apple files changed:\n${changed.join('\n')}`); process.exitCode = 1; }
else console.log(`Verified ${Object.keys(manifest.files).length} Apple files unchanged, including pre-existing edits.`);
}
