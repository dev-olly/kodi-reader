import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('./authCode.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { normalizeSignInCode, createPendingSignIn, parsePendingSignIn, PENDING_SIGN_IN_TTL_MS } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

test('pasted email codes lose whitespace and invisible formatting while retaining leading zeros', () => {
  assert.equal(normalizeSignInCode(' \t00 12\r\n34\u00a0'), '001234');
  assert.equal(normalizeSignInCode('\uFEFF\u200B0\u200C0\u200D12\u202F34\u2060\u200E\u202C'), '001234');
});

test('normalization accepts six and eight digits without truncating or coercing the code', () => {
  for (const code of ['001234', '00123456', '0123456789']) assert.equal(normalizeSignInCode(code), code);
  assert.equal(normalizeSignInCode(' \u200B\n'), '');
  assert.equal(normalizeSignInCode('12x-34'), '12x-34');
});

test('normalization is safe to repeat before submission', () => {
  const code = normalizeSignInCode('0\u200B1 23\n45\uFEFF');
  assert.equal(normalizeSignInCode(code), '012345');
});

test('pending sign-in remembers only email and a ten-minute expiry, never an OTP', () => {
  const timestamp = 1_800_000_000_000;
  const pending = createPendingSignIn(' reader@example.com ', timestamp);
  assert.deepEqual(pending, { email: 'reader@example.com', expiresAt: timestamp + 600_000 });
  assert.equal(PENDING_SIGN_IN_TTL_MS, 600_000);
  assert.deepEqual(parsePendingSignIn(JSON.stringify(pending), timestamp + 1), pending);
  assert.deepEqual(parsePendingSignIn(JSON.stringify({ ...pending, code: '00123456' }), timestamp + 1), pending);
});

test('pending sign-in does not restore expired, future-dated, or corrupt state', () => {
  const timestamp = 1_800_000_000_000;
  const pending = createPendingSignIn('reader@example.com', timestamp);
  assert.equal(parsePendingSignIn(JSON.stringify(pending), pending.expiresAt), null);
  assert.equal(parsePendingSignIn(JSON.stringify(pending), timestamp - 1), null);
  for (const serialized of [null, '', '{', 'null', '[]', '{}', JSON.stringify({ email: 'reader@example.com', expiresAt: 'later' }), JSON.stringify({ email: 'not an email', expiresAt: pending.expiresAt }), JSON.stringify({ email: ' reader@example.com ', expiresAt: pending.expiresAt })]) {
    assert.equal(parsePendingSignIn(serialized, timestamp), null);
  }
});
