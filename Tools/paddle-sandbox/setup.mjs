// Sandbox catalog only. Never configures checkout, production, or database balances.
import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Environment, LogLevel, Paddle } from '@paddle/paddle-node-sdk';

const root = new URL('../../', import.meta.url);
const keyFile = new URL('.build/paddle-sandbox.key', root);
const resultFile = new URL('.build/paddle-sandbox-catalog.json', root);
const packs = [
  { id: 'starter', name: 'Starter', credits: 250 },
  { id: 'regular', name: 'Regular', credits: 600 },
  { id: 'plus', name: 'Plus', credits: 1400 },
];
class SetupError extends Error {}
const requireState = (condition, message) => { if (!condition) throw new SetupError(message); };
const collect = async (collection) => { const items = []; for await (const item of collection) items.push(item); return items; };

async function main() {
  const args = process.argv.slice(2);
  requireState(args.every(a => a === '--apply' || /^--amounts=\d+,\d+,\d+$/.test(a)),
    'Usage: node setup.mjs [--apply --amounts=100,200,300]. Amounts are approved sandbox euro cents.');
  const apply = args.includes('--apply');
  const amountArg = args.find(a => a.startsWith('--amounts='));
  const amounts = amountArg?.slice(10).split(',').map(Number);
  requireState(!apply || (amounts?.length === 3 && amounts.every(n => Number.isSafeInteger(n) && n > 0)),
    'Provide three explicitly approved test amounts before applying the catalog.');

  let key = process.env.PADDLE_SANDBOX_API_KEY || process.env.PADDLE_API_KEY;
  if (!key) {
    try { key = (await readFile(keyFile, 'utf8')).trim(); await chmod(keyFile, 0o600); }
    catch { throw new SetupError('Sandbox key unavailable. Export PADDLE_SANDBOX_API_KEY or save it in .build/paddle-sandbox.key.'); }
  }
  requireState(key.startsWith('pdl_sdbx_apikey_'), 'Refusing a missing, malformed, or live key. A Paddle sandbox API key is required.');
  const paddle = new Paddle(key, { environment: Environment.sandbox, logLevel: LogLevel.none });
  const products = await collect(paddle.products.list({ perPage: 200, status: ['active', 'archived'] }));
  if (!apply) {
    console.log(JSON.stringify({ authenticated: true, environment: 'sandbox', productCount: products.length,
      kodiProducts: products.filter(p => p.customData?.kodi_app === 'kodi-reader').map(p => ({ id: p.id, name: p.name, status: p.status })) }, null, 2));
    return;
  }

  const config = {};
  const verified = [];
  for (const [index, pack] of packs.entries()) {
    const name = `Kodi Reader ${pack.name} — ${pack.credits} credits (Sandbox)`;
    const metadata = { kodi_app: 'kodi-reader', kodi_pack: pack.id, credits: pack.credits, sandbox_only: true };
    const matches = products.filter(p => p.customData?.kodi_app === 'kodi-reader' && p.customData?.kodi_pack === pack.id);
    requireState(matches.length <= 1, `Multiple ${pack.id} products exist; inspect them before continuing.`);
    let product = matches[0];
    if (!product) {
      requireState(!products.some(p => p.name === name), `An unrecognized ${pack.id} product exists; inspect it before creating another.`);
      product = await paddle.products.create({ name, taxCategory: 'saas',
        description: `Sandbox only: ${pack.credits} answers in Kodi Reader Ask AI. One-time purchase; no subscription.`,
        customData: metadata });
    }
    requireState(product.status === 'active' && product.taxCategory === 'saas' &&
      product.customData?.credits === pack.credits && product.customData?.sandbox_only === true,
      `Existing ${pack.id} product does not match the sandbox configuration.`);
    const prices = await collect(paddle.prices.list({ productId: [product.id], status: ['active', 'archived'], perPage: 200 }));
    const candidates = prices.filter(p => p.customData?.kodi_app === 'kodi-reader' && p.customData?.kodi_pack === pack.id);
    requireState(candidates.length <= 1, `Multiple ${pack.id} test prices exist; inspect before continuing.`);
    let price = candidates[0];
    if (!price) {
      requireState(prices.length === 0, `Unrecognized ${pack.id} prices exist; inspect before creating another.`);
      price = await paddle.prices.create({ productId: product.id, name: `${pack.name} sandbox test price`,
        description: 'TEST ONLY — not approved retail pricing', billingCycle: null, trialPeriod: null,
        taxMode: 'internal', unitPrice: { amount: String(amounts[index]), currencyCode: 'EUR' },
        quantity: { minimum: 1, maximum: 1 }, customData: metadata });
    }
    // Read back each entity; a successful POST alone is not sufficient verification.
    const actualProduct = await paddle.products.get(product.id);
    const actualPrice = await paddle.prices.get(price.id);
    requireState(actualProduct.name === name && actualProduct.taxCategory === 'saas' && actualProduct.status === 'active',
      `${pack.id} product verification failed.`);
    requireState(actualPrice.productId === product.id && actualPrice.status === 'active' &&
      actualPrice.unitPrice.currencyCode === 'EUR' && Number(actualPrice.unitPrice.amount) === amounts[index] &&
      actualPrice.billingCycle === null && actualPrice.trialPeriod === null && actualPrice.taxMode === 'internal' &&
      !actualPrice.unitPriceOverrides?.length && actualPrice.quantity.minimum === 1 && actualPrice.quantity.maximum === 1,
      `${pack.id} price verification failed. Nothing was enabled in Kodi Reader.`);
    config[pack.id] = { price_id: price.id, amount: amounts[index] };
    verified.push({ ...pack, product_id: product.id, ...config[pack.id], currency: 'EUR', tax_category: 'saas', one_time: true, tax_inclusive: true });
    console.log(`Verified ${pack.name}: ${pack.credits} credits, EUR ${(amounts[index] / 100).toFixed(2)} (sandbox only).`);
  }
  await mkdir(new URL('.build/', root), { recursive: true });
  await writeFile(resultFile, JSON.stringify({ environment: 'sandbox', test_only: true, pricing_approved: false,
    packs: verified, PADDLE_PACKS_JSON: config }, null, 2) + '\n', { mode: 0o600 });
  console.log(`Catalog IDs saved to ${fileURLToPath(resultFile)}. No live configuration was changed.`);
}

main().catch(error => {
  // Never print request objects, headers, credentials, or SDK response bodies.
  console.error(error instanceof SetupError ? error.message :
    `Paddle setup failed (${typeof error.code === 'string' && /^[a-z_]+$/.test(error.code) ? error.code : 'request_failed'}). Check sandbox key permissions and connectivity. Re-run the read-only check before retrying.`);
  process.exitCode = 1;
});
