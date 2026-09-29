# Ask AI credits — implementation and release gates

The concrete owner-by-owner production task board is in [`paddle-live-verification-plan.md`](paddle-live-verification-plan.md).

The code supports 25 welcome credits once per verified Supabase account and one-time packs of 250 / 600 / 1,400 credits. Retail prices approved on 29 September 2026 are €3.99 / €7.99 / €14.99, tax inclusive; see [`approved-pricing.md`](approved-pricing.md). Paddle Live IDs are not configured yet. Purchased credits have no expiry. Reading and local history work without sign-in.

## Current status (26 September 2026)

Implemented locally: first-launch email/Skip onboarding, provider-gated Google and native Apple sign-in, Keychain session reuse, balance and Buy credits UI, draft recovery on HTTP 402, SQL ledger, checkout API, Paddle webhook reconciliation, disabled browser checkout page, and privacy/purchase information.

Backend changes live in the adjacent `../kodi-reader-ai` repository. They have NOT been deployed. Migration `001_credits.sql` was applied successfully to the hosted Kodi Reader Supabase project (`hftfeybmgpousanpawgw`) on 26 September 2026 through the SQL Editor. All eight post-migration checks passed: five private tables, RLS, anonymous/client-role restrictions, backend RPC access, deletion trigger, both existing auth accounts preserved, and no credit accounts/orders activated. Do not reapply this migration. This manual SQL application is not a Supabase CLI migration-history entry.

Paddle sandbox catalog and a real browser checkout were verified on 26 September 2026 using an isolated local PostgreSQL database and the backend's actual Paddle adapter/SQL migration. A declined test card granted nothing; a successful Starter payment changed the test balance from 25 to 275; replaying Paddle's payment notification kept it at 275. Forged signatures returned 400. Refund validation status and catalog IDs are recorded in `docs/paddle-sandbox-validation.md`. This is not yet the signed Mac app → deployed staging backend acceptance test. Google/Apple sign-in have NOT been verified. Do not enable those providers or announce credit packs until their release checks pass.

Email sign-in and Keychain persistence were previously verified in a signed Mac build. The credit-era automated suite includes real local PostgreSQL tests, not just mocks. New signed-build acceptance still requires the deployed staging backend and payment sandbox.

## Backend setup

1. Production Kodi Reader already has `migrations/001_credits.sql` applied. For a new staging project, apply it once as the database owner. Back up before migrations. It creates a private schema, a service-role-only RPC, and an account-deletion trigger. No data tables are exposed to app clients. The migration is transactional and deliberately fails on accidental reapplication.
2. Keep `SUPABASE_SECRET_KEY` and `PADDLE_API_KEY` / `PADDLE_WEBHOOK_SECRET` exclusively on the server. Existing public app configuration stays unchanged.
3. Start with `CREDITS_ENFORCED=false`. All chat requests still require authentication. No anonymous fallback exists in this code.
4. Use a separate staging backend/Supabase project for sandbox testing. Set `CREDITS_ENFORCED=true`, `PADDLE_ENVIRONMENT=sandbox`, and `PADDLE_SANDBOX_ENABLED=true` there. Never mix live balances with sandbox payments in one database.
5. Set `PADDLE_PACKS_JSON` to the three approved **sandbox** price IDs and integer euro-cent amounts. Each Paddle price must be active, EUR, one-time, tax-inclusive (`tax_mode=internal`), without country price overrides. The server validates these properties at checkout.
6. Configure Paddle's default payment URL to the deployed `/checkout` page and place its public client token in `website/checkout-config.js`. Keep `enabled=false` until that environment is ready. Sandbox and live configurations must use matching tokens.
7. Subscribe `/v1/paddle/webhook` to `transaction.completed`, `adjustment.created`, and `adjustment.updated`. Verify notification signatures with the endpoint secret. Browser completion never grants credits.

APIs (all except health/webhook require a verified bearer token):

- `POST /v1/account/initialize`, `GET /v1/credits`: initialize the once-only welcome grant and return available balance and debt when enforcement is enabled.
- `GET /v1/credit-packs`: pack sizes plus approved prices, or unavailable/null prices.
- `POST /v1/checkout`: `{ "pack": "starter" }`, with UUID `Idempotency-Key`; returns a browser URL.
- `POST /v1/chat/completions`: UUID `Idempotency-Key`, `X-Kodi-Credit-Protocol: 1`. Empty balance returns `402 insufficient_credits`; incompatible clients return `426 update_required` after authentication. Reused IDs return 409 without generating again.
- `DELETE /v1/account`: deletes the verified auth account; database trigger disables its ledger account and removes spendable credits. Local reading data remains.

The backend measures text tokens with o200k_base plus a conservative framing allowance, trims oldest question/reply pairs, and rejects an oversized current selection. `max_completion_tokens=2048` includes reasoning. The server allows no client override of model, output cap, or streaming options. Billed usage includes input, output, cached input, cache writes, and reasoning counts. No book text is stored in the ledger.

## Settlement and reconciliation

All balance mutations lock the account row. A UUID is bound to the request fingerprint; retries cannot start a second generation. Reserved credits reduce available balance immediately. Completed answers settle once. Service failures, truncated/empty streams, and cancellation before text refund. A client disconnect after text charges; a server timeout refunds. Abandoned reservations release after five minutes, with a 30-second sweep and lazy recovery on the next account operation. Keep at least one backend machine running. Database outages fail closed; unresolved reservations expire.

Paddle checkout intents are created before calling Paddle. If creation times out, reusing the same ID cannot create another payable transaction. A pending intent needs operational reconciliation against Paddle before issuing a new checkout. Duplicate payment events are harmless. Webhooks retrieve authoritative transactions and all adjustments, validate the server-stored price/quantity/currency/amount, and reconcile absolute entitlements. Refunds revoke proportional credits (rounded up); pure tax corrections do not revoke answers. Already-spent refunded credits create debt that later purchases offset. Late/out-of-order events cannot undo a newer reconciliation snapshot.

After account deletion, payment records retain a minimal account identifier, not the email or reading content. Paid deleted-account orders are flagged `needs_review`; they do not recreate an account. Review these before launch and regularly thereafter, and arrange refunds through Paddle. Do not promise automatic refunds: those are not implemented. Confirm retention periods and unused-credit refund policy before publishing purchase terms.

## Authentication providers

- Google: configure the Google OAuth consent screen and web client in Supabase. Allow the exact callback `com.olly.KodiReader://auth/callback`. Supabase's provider callback must also be registered with Google. The app uses the SDK's PKCE browser flow. Enable `GOOGLE_SIGN_IN_ENABLED=YES` only after testing a signed build.
- Apple: Developer ID distribution uses browser OAuth through Supabase, sharing Google's background-safe callback handler and PKCE exchange. Configure a primary App ID, Apple Services ID, domain/callback, and signing key; see [Apple setup](ask-ai-auth-setup.md#apple-sign-in-setup-developer-id-distribution). Supabase stores the generated client secret, which must be rotated before its expiry (at most six months). Enable `APPLE_SIGN_IN_ENABLED=YES` only after configuration, then test in a signed build, including Hide My Email. Native Apple sign-in entitlements are not added to Developer ID builds.
- Keep both provider flags `NO` until ready. Email and Skip remain usable. Auth callbacks are not opened as books. Skipping onboarding does not grant credits; only a verified account does.

## Cost evidence and pricing decision

The benchmark in the backend's `docs/measurements/2026-09-26.json` used synthetic passages and the existing server's model, `gpt-5.6-terra`. It ran four real API requests with the 2,048 output cap:

- Short explanation: 140 input, 123 output, 0 reasoning tokens; estimated model cost $0.001756.
- Longer selection: 1,692 input, 353 output, 1,689 cache-write tokens, 0 reasoning; estimated model cost $0.0084645.
- Several follow-ups: 231 input, 257 output including 21 reasoning; estimated model cost $0.003546.

- Near-limit selection: 7,076 input, 483 output including 18 reasoning, 7,073 cache-write tokens; estimated model cost $0.0234845. Conservative server input budget: 7,578 tokens.

All four completed naturally and gave coherent explanations grounded in the synthetic passage. This is a small quality smoke test, not a production usage distribution or proof for every near-limit selection. The near-limit sample also completed naturally, but uses repeated synthetic paragraphs. More diverse passages, multilingual text, and a signed end-to-end stream remain release checks.

Costs use the [published model rates](https://developers.openai.com/api/docs/models/gpt-5.6-terra): $2/M input, $0.20/M cached input, $12/M output, cache writes at 1.25× input. Reasoning is already included in output and is not charged a second time in the calculator. These are calculated estimates from reported token usage, not reconciled invoice charges. The request-cap stress cost is $0.044576 when all 8,000 input tokens incur cache writes and all 2,048 generated tokens are used.

`node scripts/price-check.mjs docs/measurements/2026-09-26.json scripts/pricing-assumptions.example.json` calculates a conservative draft price floor. Example assumptions are explicit scenarios, **not confirmed business terms**: EUR/USD parity; 27% tax reserve; 5% + €0.50 payment fee; 5% refund reserve; three welcome allowances funded per buyer; 15% gross-price margin. At every request's maximum cost the floors are €27.89 / €56.92 / €123.28. The owner approved **€3.99 / €7.99 / €14.99** on 29 September 2026 based on normal measured usage and accepted that this aggressive pricing can be unprofitable if many requests approach the token limits. Monitor actual billed cost per completed answer from launch; see [`approved-pricing.md`](approved-pricing.md).

[Paddle advertises 5% + 50¢](https://www.paddle.com/pricing), with custom pricing for products below $10. Confirm actual EUR fees, refunds/dispute charges, account eligibility, supported tax regions, and conversion assumptions in your Paddle account before asking for final price approval. No finite pack price guarantees funding unlimited free-account abuse. Welcome grants are per account, not per person.

## Release order

1. Finish provider configuration and verify signed-build authentication.
2. Apply/test the migration in staging and complete real Paddle sandbox checkout, duplicate/delayed webhook, partial/full refund, dispute/reversal, last-credit race, sign-out, account-switch, and post-deletion payment checks.
3. Approve final euro prices and Paddle setup; finish legal business details, retention, and refund policy.
4. Release the compatible Mac app first.
5. Deploy the verified production backend, with credit enforcement and approved live purchases enabled together: `CREDITS_ENFORCED=true`, `PADDLE_ENVIRONMENT=live`, `PRICING_APPROVED=true`, `PADDLE_LIVE_APPROVED=true`. Do not set the sandbox flag in production. Publish the matching live checkout configuration.
6. Verify health, 401/402/426 responses, a paid purchase and balance refresh, and server usage. If purchases are paused later, keep processing refunds/webhooks; do not disable credit enforcement or introduce an anonymous bypass.
