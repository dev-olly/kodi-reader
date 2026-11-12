import { readdirSync, readFileSync, copyFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const targets = {
  'x86_64-pc-windows-msvc': ['.exe'],
  'x86_64-unknown-linux-gnu': ['.AppImage', '.deb', '.rpm'],
};
const walk = directory => readdirSync(directory, { withFileTypes: true }).flatMap(entry =>
  entry.isDirectory() ? walk(join(directory, entry.name)) : entry.isFile() ? [join(directory, entry.name)] : []);

export function collectInternal({ root, target, commit, runId, createdAt = new Date().toISOString() }) {
  const extensions = targets[target];
  if (!extensions) throw new Error('Supply a supported Windows or Linux native target.');
  if (!/^[a-f0-9]{40,64}$/.test(commit ?? '')) throw new Error('An exact source commit is required.');
  const config = JSON.parse(readFileSync(join(root, 'src-tauri/tauri.ci.conf.json'), 'utf8'));
  if (config.identifier !== 'com.olly.KodiReader.Desktop.Preview' || config.bundle?.createUpdaterArtifacts !== false || config.plugins?.updater) throw new Error('Only isolated preview bundles without updater configuration may enter internal artifacts.');
  const bundle = walk(join(root, 'src-tauri/target/release/bundle'));
  if (bundle.some(file => file.endsWith('.sig'))) throw new Error('Internal previews must not include signed updater artifacts.');
  const installers = extensions.map(extension => {
    const matches = bundle.filter(file => file.endsWith(extension));
    if (matches.length !== 1) throw new Error(`Expected exactly one ${extension} preview installer.`);
    return matches[0];
  });
  const destination = join(root, 'internal-output');
  if (existsSync(destination) && readdirSync(destination).length) throw new Error('Internal output must be empty to prevent mixing builds.');
  mkdirSync(destination, { recursive: true });
  const copied = new Set();
  const copy = (source, relative) => {
    if (copied.has(relative)) throw new Error(`Duplicate artifact filename: ${relative}`);
    const output = join(destination, relative);
    mkdirSync(dirname(output), { recursive: true });
    copyFileSync(source, output); copied.add(relative);
  };
  for (const file of installers) copy(file, basename(file));
  const codec = join(root, 'src-tauri/resources/ffmpeg');
  for (const required of ['BUILD.txt', 'ffmpeg-version.txt', 'COPYING.LGPLv2.1', 'SHA256SUMS']) {
    if (!existsSync(join(codec, required))) throw new Error(`Missing codec distribution evidence: ${required}`);
  }
  const codecFiles = walk(codec);
  if (!codecFiles.some(file => file.endsWith('.tar.xz')) || !codecFiles.some(file => file.endsWith('.tar.xz.asc'))) throw new Error('The corresponding verified FFmpeg source and detached signature are required.');
  for (const file of codecFiles) copy(file, `ffmpeg/${basename(file)}`);
  const licenses = join(root, 'src-tauri/resources/licenses');
  if (!existsSync(join(licenses, 'manifest.json'))) throw new Error('Resolved dependency notices are required.');
  for (const file of walk(licenses)) copy(file, `licenses/${basename(file)}`);
  copy(join(root, 'THIRD_PARTY_NOTICES.md'), 'THIRD_PARTY_NOTICES.md');
  const smoke = join(root, 'native-smoke-results');
  if (existsSync(smoke)) for (const file of walk(smoke)) copy(file, `native-smoke/${basename(file)}`);
  const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version;
  const manifest = { schemaVersion: 1, channel: 'preview', productName: config.productName, version, target, sourceCommit: commit,
    workflowRunId: runId || null, createdAt, manualAcceptance: false, publicReleaseReady: false,
    signingRequested: false, updaterEnabled: false, installers: installers.map(file => basename(file)),
    nativeSmokeEvidence: copied.has('native-smoke/result.json'),
    files: [...copied].sort().map(path => ({ path, sha256: createHash('sha256').update(readFileSync(join(destination, path))).digest('hex') })) };
  writeFileSync(join(destination, 'preview-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  copied.add('preview-manifest.json');
  writeFileSync(join(destination, 'README-PREVIEW.txt'), 'Kodi Reader Preview for Windows/Linux testing. This build has no requested code signing or automatic updates. It uses separate Preview application data. Native manual acceptance is incomplete; this is not the stable public release. See preview-manifest.json for the exact source commit and SHA256SUMS for file integrity. Keep the codec sources and notices with redistributed installers.\n');
  copied.add('README-PREVIEW.txt');
  const checksums = [...copied].sort().map(path => `${createHash('sha256').update(readFileSync(join(destination, path))).digest('hex')}  ${path}`);
  writeFileSync(join(destination, 'SHA256SUMS'), `${checksums.join('\n')}\n`);
  return manifest;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const manifest = collectInternal({ root, target: process.argv[2], commit: process.env.GITHUB_SHA, runId: process.env.GITHUB_RUN_ID });
  console.log(`Collected ${manifest.installers.length} ${manifest.target} preview installers and checksummed sources/notices.`);
}
