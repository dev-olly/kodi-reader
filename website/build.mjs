import { cp, mkdir, readdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Keep API helpers, tests, and environment files out of the public static output.
const root = new URL('./', import.meta.url);
const output = new URL('./dist/', root);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const entry of await readdir(root, { withFileTypes: true })) {
  if ((entry.isFile() && /\.(html|css|js|ico)$/.test(entry.name)) || entry.name === 'assets') {
    await cp(new URL(entry.name, root), new URL(entry.name, output), { recursive: true });
  }
}
console.log(`Static website built in ${fileURLToPath(output)}`);
