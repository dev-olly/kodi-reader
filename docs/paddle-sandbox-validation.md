# Paddle sandbox validation — 26 September 2026

The user approved **sandbox-only** amounts of €1 / €2 / €3 for the 250 / 600 / 1,400-credit packs. These are not approved retail prices. Production purchases, credit enforcement, and checkout configuration remain disabled.

## Catalog

All three products use the `saas` category for cloud-hosted Ask AI, one-time EUR prices, tax included (`internal`), no regional overrides, no trial, and quantity fixed at one. Paddle accepted this tax category in sandbox; confirm it during live onboarding.

- Starter — 250 credits, €1 test price. Product `pro_01m3dj6ct2ge9y0wedfshsvphp`; price `pri_01m3dj6d49parf47r98c3na6ee`.
- Regular — 600 credits, €2 test price. Product `pro_01m3dj6dkmbvfj4ecc9fzgv6w1`; price `pri_01m3dj6dxvb8cz3f9yzcdctwgz`.
- Plus — 1,400 credits, €3 test price. Product `pro_01m3dj6ef1vn01g7zy2m56d2bv`; price `pri_01m3dj6etbmjvq1ynqsyq79sb7`.

Each product and price was fetched after creation to verify its settings. Re-running setup reused the same IDs. A live-prefixed key was rejected before any API request. Credentials remain in ignored local files with mode 0600, never in source or logs.

## Checkout and ledger evidence

The test harness imports `kodi-reader-ai/src/paddle.js` and applies the real SQL migration to a disposable **local** PostgreSQL database. It calls the SQL RPC directly rather than using hosted Supabase. A synthetic customer was used; no real card or user account was involved. The production Supabase database was not used.

Paddle requires both a default payment link and an approved checkout domain even in this sandbox account. The test used a temporary Cloudflare HTTPS origin, a public sandbox browser token, and a signed webhook subscribed to `transaction.completed`, `adjustment.created`, and `adjustment.updated`. The test adapter overrides only the transaction's checkout URL. The existing website checkout code opened the transaction automatically from `_ptxn`.

- Declined card: checkout displayed the decline and the test balance stayed at **25**.
- Successful test card: transaction `txn_01m3djh44qgesb49hqep3908s0` completed for **€1 including VAT**, and the signed notification added **250** credits, bringing the balance to **275**. Processing took **439 ms** locally.
- Duplicate: replaying Paddle notification `ntf_01m3djjhjce5vmng9d3e2pcqw6` delivered the same event again and the balance remained **275**; no second credit grant. Processing took **394 ms**.
- Forged webhook: invalid signature returned **HTTP 400**.
- Refund: full sandbox refund `adj_01m3djmfb32mz728wqcymv4tb0` initially had status `pending_approval`; its `adjustment.created` event correctly left the balance at **275**. Paddle approved it at approximately 00:50 UTC. The signed `adjustment.updated` notification removed exactly **250** credits, leaving **25** and no debt; processing took **426 ms**. Assertions verified one welcome grant, one purchase grant, one reversal, and a reconciled ledger.
- Late payment after refund: replaying the original payment notification again left the balance at **25**, without restoring refunded credits; processing took **364 ms**.

Three earlier local checkout intents have no Paddle transaction because configuration validation rejected them before creation. They granted no credits. They belong only to the disposable local database.

## Remaining acceptance checks

- Signed Mac build through a deployed isolated staging backend and authentication.
- Partial refunds, disputes/reversals, and purchases after account deletion against Paddle sandbox (database-level automated tests already cover their accounting).
- Final euro price approval, live Paddle onboarding/domain review, and purchase/legal information.

The temporary local harness is not a persistent staging deployment. After the initial testing, its notification destination was disabled and the sandbox default payment link was reset to the development placeholder `https://localhost/checkout`. The public sandbox client token and catalog remain available; no live configuration was changed.

## Native test build handoff, 26 September 2026

The signed **Kodi Reader Sandbox** build now uses a loopback-only test backend, verified Supabase authentication, and a fresh isolated local ledger. Its Developer ID signature and build passed. The adapter test passed concurrent user identity preservation, anonymous rejection, blocked account deletion, local credit settlement, and prevention of production credit charging. The public checkout tunnel rejects account API requests with 404; the native account API rejects anonymous requests with 401.

The sandbox notification destination was re-enabled for the new temporary checkout domain, and that domain was approved in Paddle sandbox. A Starter checkout was created and visually verified showing **test mode**, €1 including VAT, and 250 credits. No payment was submitted during this handoff. The default payment link remains the localhost placeholder; transactions carry the verified temporary checkout URL.

The checkout server, tunnel, native backend, and local database are left running for the user's manual app test. The app is open at its sign-in screen. Signed-in native balance/purchase/answer acceptance remains for the user to complete; the earlier synthetic purchase/refund tests are not presented as a completed native app payment. Restart/cleanup instructions are in `Tools/paddle-sandbox/README.md`.

## Automatic checkout return, 26 September 2026

The user completed a native Plus sandbox purchase; the server granted 1,400 credits (balance 1,425), but the old app displayed a stale balance. The rebuilt sandbox app now polls an authenticated, owner-checked purchase-status endpoint and only announces success after the signed webhook reconciles that exact order. Pending purchase IDs persist per account across relaunches. Regular and sandbox builds register separate return URL schemes.

End-to-end verification from the signed Mac app passed: a new Starter checkout (`txn_01m3egh4nzwwa7s2x0s9xbzw59`) completed with Paddle's test card and synthetic billing details. The checkout requested reopening Kodi Reader Sandbox. Chrome showed its standard external-app prompt; after opening the app, it showed **Credits added**, **250 credits added**, and **1,675 credits available** without a manual refresh. **Continue with Ask AI** returned to the composer with the updated balance. Browser card saving was declined. The test balance remains 1,675; no real payment was taken.

Validation: 21 Mac tests, 31 backend/local-adapter tests, and 2 browser-script unit tests passed; signed Release build and signature verification passed. The local backend was restarted without resetting the database. The browser has an explicit Return to Kodi Reader fallback; app polling also works when automatic navigation is blocked. Production website/backend deployment and live pricing remain gated separately.
