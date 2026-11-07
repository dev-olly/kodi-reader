import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir, userInfo } from 'node:os';
import { dirname, join, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const candidates = [
  process.env.ANALYTICS_POSTGRES_BIN,
  ...process.env.PATH.split(delimiter),
  '/opt/homebrew/opt/postgresql@14/bin',
].filter(Boolean);
const bin = candidates.find(path => ['postgres', 'initdb', 'pg_ctl', 'psql'].every(name => existsSync(join(path, name))));

test('PostgreSQL migration, RLS, deduplication, UTC aggregation, >1000 rows and retention', {
  skip: !bin && 'Install PostgreSQL or set ANALYTICS_POSTGRES_BIN to run database integration checks.',
  timeout: 30000,
}, () => {
  const directory = mkdtempSync(join(tmpdir(), 'kodi-analytics-test-'));
  const data = join(directory, 'data');
  const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
  let started = false;
  function run(name, args) {
    const result = spawnSync(join(bin, name), args, { encoding: 'utf8', timeout: 15000 });
    assert.equal(result.status, 0, `${name} failed: ${result.stderr || result.stdout || result.error}`);
    return result;
  }
  const sql = input => {
    const result = spawnSync(join(bin, 'psql'), ['-h', directory, '-U', userInfo().username, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-X', '-q'], {
      input, encoding: 'utf8', timeout: 15000,
    });
    assert.equal(result.status, 0, `SQL failed: ${result.stderr || result.stdout || result.error}`);
    return result;
  };
  try {
    run('initdb', ['-D', data, '--auth=trust', '--no-locale', '--encoding=UTF8']);
    // Unix socket only: never opens a TCP listener or touches an existing database.
    run('pg_ctl', ['-D', data, '-l', join(directory, 'postgres.log'), '-w', '-o', `-F -k ${directory} -c listen_addresses=''`, 'start']);
    started = true;
    sql('create role anon; create role authenticated; create role service_role bypassrls;');
    const migration = readFileSync(join(root, 'docs/analytics/001_analytics.sql'), 'utf8');
    sql(migration);
    sql(migration); // Safe to apply the migration again.
    const usageMigration = readFileSync(join(root, 'docs/analytics/003_usage_v2.sql'), 'utf8');
    sql(usageMigration); // A telemetry-only project does not need private auth / billing schemas.
    sql(usageMigration);
    sql(readFileSync(join(root, 'docs/analytics/verify.sql'), 'utf8'));
    sql(readFileSync(join(root, 'docs/analytics/verify-usage-v2.sql'), 'utf8'));
    const featureMigration = readFileSync(join(root, 'docs/analytics/004_feature_usage.sql'), 'utf8');
    sql(featureMigration);
    // Reapplication also preserves already-received V3 intervals and actions.
    sql(`
      insert into public.analytics_events (id, installation_id, session_id, occurred_at, name, duration_seconds, schema_version)
      values ('f4444444-4444-4444-8444-444444444444', 'a4444444-4444-4444-8444-444444444444',
        'b4444444-4444-4444-8444-444444444444', now(), 'audio_recording_heartbeat', 12, 3);
    `);
    sql(featureMigration);
    sql(`do $$ begin
      assert (select duration_seconds from public.analytics_events where id='f4444444-4444-4444-8444-444444444444') = 12,
        'reapplying feature migration preserves stored V3 data';
    end; $$;
    delete from public.analytics_events where id='f4444444-4444-4444-8444-444444444444';`);
    sql(readFileSync(join(root, 'docs/analytics/verify.sql'), 'utf8'));
    sql(readFileSync(join(root, 'docs/analytics/verify-usage-v2.sql'), 'utf8'));
    sql(readFileSync(join(root, 'docs/analytics/verify-feature-usage.sql'), 'utf8'));
    // Minimal existing application schemas. The production auth / credits
    // migration owns these tables; analytics never creates or changes them.
    sql(`
      create schema auth;
      create table auth.users (id uuid primary key, created_at timestamptz not null, last_sign_in_at timestamptz, deleted_at timestamptz);
      create schema kodi_private;
      create table kodi_private.accounts (id uuid primary key, auth_user_id uuid, created_at timestamptz not null, deleted_at timestamptz);
      create table kodi_private.ledger (account_id uuid not null, kind text not null, reference text not null, created_at timestamptz not null, unique(account_id, kind, reference));
    `);
    const serverMigration = readFileSync(join(root, 'docs/analytics/002_server_usage.sql'), 'utf8');
    sql(serverMigration);
    sql(serverMigration);
    sql(usageMigration); // Preserve the optional existing history panel as well.
    sql(featureMigration); // V3 preserves that same optional panel and ACLs.
    sql(readFileSync(join(root, 'docs/analytics/verify-server-usage.sql'), 'utf8'));
    sql(readFileSync(join(root, 'docs/analytics/verify-feature-usage.sql'), 'utf8'));
  } finally {
    if (started) run('pg_ctl', ['-D', data, '-m', 'immediate', '-w', 'stop']);
    rmSync(directory, { recursive: true, force: true });
  }
});
