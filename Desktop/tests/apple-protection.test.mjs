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

test('byte-exact checkout settings prevent Windows newline conversion from tripping the Apple guard', () => {
  const root = mkdtempSync(join(tmpdir(), 'kodi-checkout-boundary-'));
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  };
  try {
    mkdirSync(join(root, 'Desktop/scripts'), { recursive: true });
    mkdirSync(join(root, 'App'));
    const script = join(root, 'Desktop/scripts/protect-apple.mjs');
    writeFileSync(script, readFileSync(resolve(import.meta.dirname, '../scripts/protect-apple.mjs')));
    const original = 'let title = "Reader"\nlet count = 2\n';
    const hash = createHash('sha256').update(original).digest('hex');
    writeFileSync(join(root, 'Desktop/protected-apple.json'), JSON.stringify({ files: { 'App/fixture.swift': hash }, committedFiles: { 'App/fixture.swift': hash } }));
    writeFileSync(join(root, 'App/fixture.swift'), original);
    git('init', '--quiet');
    git('-c', 'core.autocrlf=false', 'add', 'App/fixture.swift');
    const check = () => spawnSync(process.execPath, [script], { env: { ...process.env, CI: 'true' }, encoding: 'utf8' }).status;
    rmSync(join(root, 'App/fixture.swift'));
    git('-c', 'core.autocrlf=true', 'checkout-index', '--force', 'App/fixture.swift');
    assert.equal(check(), 1, 'automatic CRLF checkout changes protected bytes');
    rmSync(join(root, 'App/fixture.swift'));
    git('-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'checkout-index', '--force', 'App/fixture.swift');
    assert.equal(readFileSync(join(root, 'App/fixture.swift'), 'utf8'), original);
    assert.equal(check(), 0, 'byte-exact checkout passes without relaxing protection');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('pinned upstream CI snapshot requires a complete tree and never changes the original local boundary', () => {
  const root = mkdtempSync(join(tmpdir(), 'kodi-upstream-boundary-'));
  const hash = text => createHash('sha256').update(text).digest('hex');
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  };
  try {
    mkdirSync(join(root, 'Desktop/scripts'), { recursive: true });
    mkdirSync(join(root, 'App'));
    const script = join(root, 'Desktop/scripts/protect-apple.mjs');
    writeFileSync(script, readFileSync(resolve(import.meta.dirname, '../scripts/protect-apple.mjs')));
    const original = { version: 2, paths: ['App'], files: { 'App/one.swift': hash('old one'), 'App/two.swift': hash('old two') }, committedFiles: { 'App/one.swift': hash('old one'), 'App/two.swift': hash('old two') } };
    const originalBytes = JSON.stringify(original);
    const originalPath = join(root, 'Desktop/protected-apple.json');
    writeFileSync(originalPath, originalBytes);
    const upstream = { version: 1, sourceCommit: 'a'.repeat(40), reason: 'Independent native Mac release fixture', paths: ['App'], files: { 'App/one.swift': hash('new one'), 'App/two.swift': hash('new two'), 'App/new.swift': hash('new file') } };
    writeFileSync(join(root, 'Desktop/protected-apple-upstream-ci.json'), JSON.stringify(upstream));
    writeFileSync(join(root, 'App/one.swift'), 'new one');
    writeFileSync(join(root, 'App/two.swift'), 'new two');
    writeFileSync(join(root, 'App/new.swift'), 'new file');
    git('init', '--quiet'); git('-c', 'core.autocrlf=false', 'add', 'App');
    const run = ci => spawnSync(process.execPath, [script], { env: { ...process.env, CI: ci }, encoding: 'utf8' }).status;
    assert.equal(run('true'), 0, 'complete pinned upstream tree passes shallow CI');
    assert.equal(run(''), 1, 'local verification still requires the original snapshot');
    assert.equal(run('false'), 1, 'a false CI flag never enables upstream acceptance');
    writeFileSync(join(root, 'App/one.swift'), 'old one');
    assert.equal(run('true'), 1, 'old and new snapshots cannot be mixed per file');
    writeFileSync(join(root, 'App/one.swift'), 'new one');
    writeFileSync(join(root, 'App/two.swift'), 'later edit');
    assert.equal(run('true'), 1, 'later upstream mutations are rejected');
    writeFileSync(join(root, 'App/two.swift'), 'new two');
    rmSync(join(root, 'App/new.swift'));
    assert.equal(run('true'), 1, 'missing pinned files are rejected');
    writeFileSync(join(root, 'App/new.swift'), 'new file');
    writeFileSync(join(root, 'App/extra.swift'), 'later added source');
    git('-c', 'core.autocrlf=false', 'add', 'App/extra.swift');
    assert.equal(run('true'), 1, 'extra tracked protected files are rejected');
    assert.equal(readFileSync(originalPath, 'utf8'), originalBytes, 'the original manifest is never rewritten');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
