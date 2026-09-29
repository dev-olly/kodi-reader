import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createAuth } from '../../../kodi-reader-ai/src/auth.js';
import { service, readJSON, connection, Pool } from './checkout-test.mjs';
import { createNativeApp } from './native-adapter.mjs';

const run = promisify(execFile);
const plist = fileURLToPath(new URL('../../.build/AuthReleaseDerivedData/Build/Products/Release/Kodi Reader Sandbox.app/Contents/Info.plist', import.meta.url));
async function publicSetting(name) {
  return (await run('/usr/bin/plutil', ['-extract', name, 'raw', '-o', '-', plist])).stdout.trim();
}
const local = await readJSON('paddle-local-test.json');
if (!/^kodi_paddle_[a-f0-9]{32}$/.test(local.database)) throw new Error('Invalid local test database');
const settings = await readJSON('paddle-sandbox-connection.json');
const pool = new Pool({ ...connection, database: local.database });
const baseAuth = createAuth({ SUPABASE_URL: await publicSetting('SupabaseURL'),
  SUPABASE_PUBLISHABLE_KEY: await publicSetting('SupabasePublishableKey') });
const server = createNativeApp({ baseAuth, ...service(pool, settings),
  registerUser: user => pool.query('insert into auth.users(id) values($1) on conflict do nothing', [user]) });
server.listen(55441, '127.0.0.1', () => console.log('Native sandbox backend ready on 127.0.0.1:55441. Real sign-in; local credits; sandbox payments.'));
const stop = () => server.close(async () => { await pool.end(); process.exit(0); });
process.on('SIGTERM', stop); process.on('SIGINT', stop);
