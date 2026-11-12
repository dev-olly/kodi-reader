import { readdirSync, readFileSync, copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2];
if (!/^(x86_64-unknown-linux-gnu|x86_64-pc-windows-msvc)$/.test(target ?? '')) throw new Error('Supply a supported native release target.');
const destination = resolve(root, 'release-output'); mkdirSync(destination, { recursive: true });
const copied = [];
const copy = (source, name = basename(source)) => {
  copyFileSync(source, join(destination, name)); copied.push(name);
};
const walk = directory => readdirSync(directory, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? walk(join(directory, entry.name)) : [join(directory, entry.name)]);
for (const file of walk(resolve(root, 'src-tauri/target/release/bundle'))) {
  if (/\.(exe|AppImage|deb|rpm)(\.sig)?$/.test(file)) copy(file);
}
if (!copied.some(name => name.endsWith('.sig'))) throw new Error('Updater signatures were not produced; refusing to collect release files.');
const ffmpeg = resolve(root, 'src-tauri/resources/ffmpeg');
copy(join(ffmpeg, 'BUILD.txt'), `ffmpeg-${target}-BUILD.txt`);
copy(join(ffmpeg, 'ffmpeg-version.txt'), `ffmpeg-${target}-version.txt`);
if (target.includes('linux')) {
  for (const file of walk(ffmpeg)) if (/\.(xz|asc)$/.test(file) || basename(file) === 'COPYING.LGPLv2.1') copy(file);
  copy(resolve(root, 'THIRD_PARTY_NOTICES.md'));
}
const sums = copied.sort().map(name => `${createHash('sha256').update(readFileSync(join(destination, name))).digest('hex')}  ${name}`).join('\n');
writeFileSync(join(destination, `SHA256SUMS-${target}`), `${sums}\n`);
console.log(`Collected ${copied.length} signed distribution files for ${target}.`);
