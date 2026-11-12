import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const file = resolve(root, 'release-acceptance.json');
const acceptance = JSON.parse(readFileSync(file, 'utf8'));
const required = ['windows11', 'ubuntu2404Wayland', 'ubuntu2404X11', 'ubuntu2604Wayland', 'fedoraWayland', 'macDriveRoundTrip', 'offlineAudio', 'signedUpdateUpgrade', 'installerDataRetention'];
const failures = required.filter(key => acceptance.checks[key]?.passed !== true || !acceptance.checks[key]?.evidence);
if (!existsSync(resolve(root, 'src-tauri/Cargo.lock'))) failures.push('committed Rust lockfile');
if (!process.env.TAURI_SIGNING_PRIVATE_KEY) failures.push('Tauri updater signing key');
if (failures.length) { console.error(`Public release is blocked until verified:\n${failures.map(v => `- ${v}`).join('\n')}`); process.exitCode = 1; }
else console.log('Native release acceptance and signing prerequisites are recorded.');
