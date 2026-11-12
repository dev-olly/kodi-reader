// Preserve the actual license texts installed with resolved runtime packages.
import { readFileSync, readdirSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(root, 'src-tauri/resources/licenses'); mkdirSync(output, { recursive: true });
const licenses = [];
const isLicense = name => /^(licen[cs]e|copying|notice|third[-_ ]?party[-_ ]?notices?)([._-].*)?$/i.test(name);
const collect = (directory, prefix) => {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).filter(entry => entry.isFile() && isLicense(entry.name)).map(entry => {
    const filename = `${prefix}-${entry.name.replace(/[^A-Za-z0-9._-]/g, '_')}`;
    const content = readFileSync(join(directory, entry.name));
    writeFileSync(join(output, filename), content);
    return filename;
  });
};
const native = spawnSync('rustc', ['-vV'], { cwd: resolve(root, 'src-tauri'), encoding: 'utf8' });
const target = /^host: (.+)$/m.exec(native.stdout ?? '')?.[1];
if (!target) throw new Error('Could not identify the native Rust build target.');
const metadata = spawnSync('cargo', ['metadata', '--locked', '--format-version', '1', '--all-features', '--filter-platform', target], { cwd: resolve(root, 'src-tauri'), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
if (metadata.error || metadata.status !== 0) throw new Error(`Could not inventory Rust licenses: ${metadata.error?.message ?? metadata.stderr}`);
for (const item of JSON.parse(metadata.stdout).packages) {
  if (!item.source) continue;
  const prefix = `rust-${item.name}-${item.version}`;
  const files = collect(dirname(item.manifest_path), prefix);
  if (item.license_file) {
    const source = resolve(dirname(item.manifest_path), item.license_file);
    const name = `${prefix}-${basename(source)}`;
    if (existsSync(source) && !files.includes(name)) { writeFileSync(join(output, name), readFileSync(source)); files.push(name); }
  }
  licenses.push({ ecosystem: 'cargo', name: item.name, version: item.version, license: item.license, repository: item.repository, files });
}
const lock = JSON.parse(readFileSync(resolve(root, 'package-lock.json'), 'utf8'));
for (const [directory, item] of Object.entries(lock.packages)) {
  if (!directory || item.dev || !directory.includes('node_modules/')) continue;
  const packageRoot = resolve(root, directory);
  if (!existsSync(join(packageRoot, 'package.json'))) {
    if (item.optional) continue; // npm omits native packages for other platforms.
    throw new Error(`Installed runtime dependency missing: ${directory}`);
  }
  const details = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
  licenses.push({ ecosystem: 'npm', name: details.name, version: details.version, license: details.license ?? item.license,
    repository: details.repository, files: collect(packageRoot, `npm-${String(details.name).replace(/[^A-Za-z0-9._-]/g, '_')}-${details.version}`) });
}
licenses.sort((a, b) => `${a.ecosystem}:${a.name}:${a.version}`.localeCompare(`${b.ecosystem}:${b.name}:${b.version}`));
writeFileSync(join(output, 'manifest.json'), `${JSON.stringify(licenses, null, 2)}\n`);
writeFileSync(join(output, 'README.txt'), 'License texts and declared SPDX expressions from the exact Cargo.lock and package-lock.json package versions. See THIRD_PARTY_NOTICES.md for bundled reader assets, FFmpeg, speech runtime and model attribution. Packages without a top-level license text remain listed in manifest.json for release review.\n');
console.log(`Collected ${licenses.length} resolved dependency attributions and their supplied license texts.`);
