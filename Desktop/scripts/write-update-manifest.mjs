import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
const directory = resolve(process.argv[2] ?? 'release-output');
const tag = process.env.RELEASE_TAG;
const repository = process.env.GITHUB_REPOSITORY;
if (!/^desktop-v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/.test(tag ?? '') || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository ?? '')) throw new Error('A verified desktop release tag and repository are required.');
const files = readdirSync(directory);
const platforms = {};
for (const [key, suffix] of [['windows-x86_64', '.exe.sig'], ['linux-x86_64', '.AppImage.sig']]) {
  const matches = files.filter(file => file.endsWith(suffix));
  if (matches.length !== 1) throw new Error(`Expected exactly one signed updater artifact for ${key}.`);
  const signatureFile = matches[0]; const artifact = signatureFile.slice(0, -4);
  if (!files.includes(artifact)) throw new Error(`Missing update artifact ${artifact}.`);
  const signature = readFileSync(join(directory, signatureFile), 'utf8').trim();
  if (!signature || signature.length < 40) throw new Error(`Missing updater signature for ${key}.`);
  platforms[key] = { signature, url: `https://github.com/${repository}/releases/download/${tag}/${encodeURIComponent(artifact)}` };
}
const manifest = { version: tag.replace('desktop-v', ''), notes: 'Kodi Reader desktop update. See the release notes for changes.', pub_date: new Date().toISOString(), platforms };
writeFileSync(join(directory, 'latest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
console.log('Created updater metadata from actual signed Windows and Linux artifacts.');
