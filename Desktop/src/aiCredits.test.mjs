import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const source = await readFile(new URL('./aiCredits.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { parseCreditBalance, parseCreditCatalog, formatCreditPrice, checkoutUrl, draftAfterFailedAnswer, isCreditError, matchesAIRequest, validCheckoutRequests } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

test('credit balances use authoritative server counts and preserve unenforced null balances', () => {
  assert.deepEqual(parseCreditBalance({ balance: 250, enforced: true }), { balance: 250, enforced: true });
  assert.deepEqual(parseCreditBalance({ available: 17, balance: 99, enforced: true }), { balance: 17, enforced: true });
  assert.deepEqual(parseCreditBalance({ balance: null, enforced: false }), { balance: null, enforced: false });
  assert.deepEqual(parseCreditBalance({ balance: '250', enforced: true }), { balance: null, enforced: true });
});
test('credit packs never invent prices when catalog entries are unavailable or malformed', () => {
  const catalog = parseCreditCatalog({ sandbox: true, packs: [
    { id: 'starter', name: 'Starter', credits: 250, amount: 399, available: true },
    { id: 'missing-price', name: 'No price', credits: 600, amount: null, available: true },
    { id: 'negative-price', name: 'Invalid price', credits: 600, amount: -1, available: true },
    { id: 'inactive', name: 'Inactive', credits: 1400, amount: 1499, available: false },
    { id: 'broken', name: 'Broken', credits: '250', amount: 399, available: true },
  ] });
  assert.equal(catalog.sandbox, true); assert.equal(catalog.packs.length, 4);
  assert.equal(catalog.packs[0].available, true);
  assert.equal(formatCreditPrice(catalog.packs[0]).replace(/\D/g, ''), '399');
  assert.equal(catalog.packs[1].available, false); assert.equal(formatCreditPrice(catalog.packs[1]), null);
  assert.equal(catalog.packs[2].available, false); assert.equal(formatCreditPrice(catalog.packs[2]), null);
  assert.equal(catalog.packs[3].available, false);
});
test('checkout opens only a returned HTTPS URL without embedded credentials', () => {
  assert.equal(checkoutUrl({ url: 'https://checkout.example.com/order?id=abc' }), 'https://checkout.example.com/order?id=abc');
  for (const value of [{}, { url: 'javascript:alert(1)' }, { url: 'http://checkout.example.com/' }, { url: 'file:///tmp/order' }, { url: 'https://user:password@checkout.example.com/' }]) assert.throws(() => checkoutUrl(value));
});
test('a 402 or pre-token error restores the submitted question without overwriting a new draft', () => {
  assert.equal(draftAfterFailedAnswer('', 'Explain this passage 😀', ''), 'Explain this passage 😀');
  assert.equal(draftAfterFailedAnswer('new question', 'submitted question', ''), 'new question');
  assert.equal(draftAfterFailedAnswer('', 'submitted question', 'partial answer'), '');
  assert.equal(draftAfterFailedAnswer('', 'submitted question', '   '), 'submitted question');
  assert.equal(isCreditError('You have no credits left'), true);
  assert.equal(isCreditError('HTTP 402 insufficient_credits'), true);
  assert.equal(isCreditError('The credit service is temporarily unavailable'), false);
});
test('old answers cannot clear a newer request or restore another conversation’s draft', () => {
  const active = { requestId: 'new-request', threadId: 'thread-A', submitted: 'current question', received: '', sending: true };
  assert.equal(matchesAIRequest({ requestId: 'new-request', threadId: 'thread-A', bookId: 'book-A' }, active, 'book-A'), true);
  assert.equal(matchesAIRequest({ requestId: 'old-request', threadId: 'thread-A', bookId: 'book-A' }, active, 'book-A'), false);
  assert.equal(matchesAIRequest({ requestId: 'new-request', threadId: 'thread-B', bookId: 'book-A' }, active, 'book-A'), false);
  assert.equal(matchesAIRequest({ requestId: 'new-request', threadId: 'thread-A', bookId: 'book-B' }, active, 'book-A'), false);
  assert.equal(matchesAIRequest({ requestId: 'new-request', threadId: 'thread-A', bookId: 'book-A' }, { ...active, sending: false }, 'book-A'), false);
});

test('persisted checkout idempotency IDs retain valid pack requests and reject corrupted storage', () => {
  const id = 'aabbccdd-1234-5678-abcd-1234567890ab';
  assert.deepEqual(validCheckoutRequests({ starter: id, other: 'invalid', 'bad/path': id, regular: null }), { starter: id });
  assert.deepEqual(validCheckoutRequests(null), {});
  assert.deepEqual(validCheckoutRequests([id]), {});
});
