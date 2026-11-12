import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { run } from '@tauri-apps/cli';
const configuration=fileURLToPath(new URL('../.env',import.meta.url));
if(existsSync(configuration)) process.loadEnvFile(configuration);
await run(process.argv.slice(2));
