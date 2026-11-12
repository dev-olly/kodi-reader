import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

test('Apple guard preserves dirty starting files locally and accepts clean shallow CI without allowing deletion', () => {
  const root = mkdtempSync(join(tmpdir(), 'kodi-apple-boundary-'));
  const hash = text => createHash('sha256').update(text).digest('hex');
  try {
    mkdirSync(join(root, 'Desktop/scripts'), { recursive: true });
    mkdirSync(join(root, 'App'));
    const script = join(root, 'Desktop/scripts/protect-apple.mjs');
    writeFileSync(script, readFileSync(resolve(import.meta.dirname, '../scripts/protect-apple.mjs')));
    writeFileSync(join(root, 'Desktop/protected-apple.json'), JSON.stringify({ version: 2,
      files: { 'App/tracked.swift': hash('user draft'), 'App/untracked.swift': hash('new user file') },
      committedFiles: { 'App/tracked.swift': hash('original commit'), 'App/untracked.swift': null },
    }));
    const run = ci => spawnSync(process.execPath, [script], { env: { ...process.env, CI: ci ? 'true' : '' }, encoding: 'utf8' });
    writeFileSync(join(root, 'App/tracked.swift'), 'user draft');
    writeFileSync(join(root, 'App/untracked.swift'), 'new user file');
    assert.equal(run(false).status, 0);
    writeFileSync(join(root, 'App/tracked.swift'), 'original commit');
    assert.equal(run(false).status, 1, 'local verification must preserve pre-existing edits');
    rmSync(join(root, 'App/untracked.swift'));
    assert.equal(run(true).status, 0, 'CI needs neither Git history nor untracked user files');
    writeFileSync(join(root, 'App/tracked.swift'), 'third version');
    assert.equal(run(true).status, 1, 'CI cannot accept a newly changed Apple file');
    rmSync(join(root, 'App/tracked.swift'));
    assert.equal(run(true).status, 1, 'missing tracked Apple files must fail even in CI');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
