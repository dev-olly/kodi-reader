import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { bundleConfiguration } from './bundle-config.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const release = process.argv.includes('--release');
const config = bundleConfiguration({ platform: process.platform, release, env: process.env,
  acceptance: release ? JSON.parse(readFileSync(resolve(root, 'release-acceptance.json'), 'utf8')) : undefined });
const destination = resolve(root, 'src-tauri', 'tauri.ci.conf.json');
writeFileSync(destination, `${JSON.stringify(config, null, 2)}\n`);
console.log(`Prepared ${release ? 'signed release' : 'internal test'} bundle configuration.`);
