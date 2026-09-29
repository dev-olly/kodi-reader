# Paddle live verification and production launch plan

Status date: 29 September 2026

This is the working task board for moving Ask AI credits from the verified Paddle sandbox flow to real payments. Do not use sandbox IDs, tokens, balances, or test prices in production. Do not enable live checkout until every release gate in Phase 5 is complete.

## Current position

- Email authentication works in a signed Mac build.
- Production Supabase already contains the credit-accounting migration. Do not reapply it.
- The Paddle sandbox flow has passed checkout, signed webhook, duplicate-event, full-refund, automatic app return, and automatic balance-refresh tests.
- The gated production backend, live Paddle catalog, credentials, webhook, and public checkout configuration were deployed on 29 September 2026. Checkout and credit enforcement remain disabled pending Paddle approval and the coordinated app release.
- Paddle Live now has three active SaaS products and tax-inclusive one-time EUR prices: Starter `pri_01m3pryz3g6b43nda6dwf3jyn5` (€3.99), Regular `pri_01m3przj1tvy7xrjkbt67b8t1m` (€7.99), and Plus `pri_01m3ps0343dg05hrdfgsc6psxx` (€14.99).
- `kodi-reader.app` is pending Paddle domain review. Account identity and payout verification remain with Olly.
- The €1 / €2 / €3 sandbox prices are test values only. Retail prices were approved on 29 September 2026: Starter €3.99, Regular €7.99, and Plus €14.99, all tax-inclusive one-time purchases.
- Google and Apple sign-in remain disabled and are not required for an email-first payment launch.
- Kodi Reader 0.4.0 (build 6) has a Developer ID-signed, Apple-notarized release candidate at `.build/KodiReader-0.4.0-rc.dmg`. It contains payment support but keeps credit and purchase controls hidden while backend enforcement is off.

## Phase 1 — Decide the information Paddle and customers will see

These tasks block website review and live catalog creation.

- [x] **LIVE-01 — Choose seller type**  
  **Owner:** Olly  
  **Decision:** individual/sole trader, confirmed 29 September 2026. Paddle says business verification is not required for individuals or sole traders, but identity verification still applies.  
  **Done when:** completed. Use the individual/sole-trader path in the live Paddle profile; do not create a company profile for Kodi Reader.

- [ ] **LIVE-02 — Confirm seller identity for legal pages**  
  **Owner:** Olly  
  **Provide privately:** legal name or registered company name, trading name if different, country, and a business/support contact. Do not put identity documents, bank details, or home-address evidence in Git or chat.  
  **Done when:** the name Paddle verifies is the name used in the website Terms.

- [ ] **LIVE-03 — Approve customer policies**  
  **Owner:** Olly, with professional legal review if desired  
  **Decisions:** refund-request window; treatment of unused purchased credits; account-deletion handling; record-retention period; governing law/jurisdiction; support response target. Mandatory consumer rights must remain unaffected.  
  **Done when:** there is approved wording for Terms, Refund Policy, Purchase Information, and Privacy Policy.

- [x] **LIVE-04 — Approve retail prices**  
  **Owner:** Olly  
  **Packs:** 250 Starter, 600 Regular, 1,400 Plus; one-time EUR purchases; tax included; no expiry; no subscription.  
  **Decision:** Starter €3.99 (399 cents), Regular €7.99 (799 cents), Plus €14.99 (1,499 cents). This is an aggressive price point based on measured normal usage; production cost per completed answer must be monitored because frequent near-limit requests can exceed it.  
  **Record:** [`approved-pricing.md`](approved-pricing.md). Sandbox amounts must never be copied.

## Phase 2 — Make kodi-reader.app ready for Paddle domain review

Paddle requires a live HTTPS site with a clear product description, pricing or a pricing screenshot, purchased deliverables, Terms, Refund Policy, and Privacy Policy accessible through navigation. Paddle also asks sole proprietors to include their brand and preferably their legal name in the Terms.

- [ ] **WEB-01 — Add Terms and Conditions**  
  **Owner:** Codex drafts after LIVE-02 and LIVE-03; Olly approves  
  **Content:** seller identity, product/license description, account rules, Ask AI credits, acceptable use, availability, intellectual property, limitation language, termination, consumer rights, contact, governing law.  
  **Prepared locally:** `/terms` now contains the product, account, credit, Paddle merchant-of-record, acceptable-use, AI-output, liability, consumer-rights, and German-law terms. The public legal name/service-address decision remains before deployment.  
  **Done when:** `/terms` is live, linked in the site footer, checkout, privacy, and purchases pages, and contains no placeholder fields.

- [ ] **WEB-02 — Add a standalone Refund Policy**  
  **Owner:** Codex drafts after LIVE-03; Olly approves  
  **Content:** how to request a refund, information to include, unused/used credit treatment, disputes, account deletion, processing through Paddle, and mandatory rights.  
  **Prepared locally:** `/refunds` now covers Paddle support, statutory withdrawal rights, delivery faults, unused/used credits, reversals, account deletion, and refund timing.  
  **Done when:** `/refunds` is live and linked everywhere Paddle expects it.

- [ ] **WEB-03 — Publish clear product and deliverable details**  
  **Owner:** Codex  
  **Content:** Kodi Reader is a free macOS EPUB/PDF reader; payment buys a fixed number of Ask AI answers; one credit equals one completed answer/follow-up; purchased credits do not expire; delivery occurs to the signed-in account after payment confirmation.  
  **Prepared locally:** `/pricing` and `/purchases` contain this description and distinguish free reading from paid Ask AI credits.  
  **Done when:** a reviewer can understand the product and exactly what is delivered without installing the app.

- [ ] **WEB-04 — Publish approved pricing**  
  **Owner:** Codex after LIVE-04  
  **Content:** all three pack prices, quantities, tax-inclusive wording, one-time-purchase wording, no automatic top-ups, and no subscription.  
  **Prepared locally:** `/pricing` shows €3.99 / €7.99 / €14.99 for 250 / 600 / 1,400 credits, including per-answer prices and delivery details.  
  **Done when:** the website and app show the same approved quantities and prices. Until then, prepare an app pricing screenshot for Paddle instead of inventing prices.

- [ ] **WEB-05 — Update pre-launch wording**  
  **Owner:** Codex immediately before submission  
  **Current blocker:** `/purchases` says purchases have not launched and the public checkout config is disabled.  
  **Done when:** the review copy accurately describes an upcoming/live purchasable product without claiming checkout is enabled before it is safe.

- [ ] **WEB-06 — Run the domain-review audit**  
  **Owner:** Codex  
  **Checks:** HTTPS, no broken links, mobile layout, product screenshots, download path, support email delivery, footer navigation, Terms, Refunds, Privacy, Purchases, pricing/deliverables, seller name consistency, and no sandbox wording.  
  **Evidence:** dated screenshots/PDF plus a link report saved under `docs/evidence/` (no secrets).  
  **Done when:** `https://kodi-reader.app` passes every check from a signed-out browser.

## Phase 3 — Complete Paddle live account verification

These are human/account actions. Codex can guide the dashboard and verify the resulting non-secret configuration, but Olly must complete identity checks and accept account terms.

- [x] **PAD-01 — Create or activate the Paddle live account**  
  **Owner:** Olly  
  **Done when:** the dashboard is in live mode rather than the separate sandbox account.

- [ ] **PAD-02 — Submit `kodi-reader.app` for Website Approval**  
  **Owner:** Olly, after Phase 2  
  **Submit:** only the exact domain/subdomain that launches checkout. Paddle says every checkout subdomain needs separate approval.  
  **Evidence:** submitted 29 September 2026; Paddle currently reports `Pending`.  
  **Done when:** the production checkout domain is approved. Manual reviews may take roughly 5–7 business days according to Paddle.

- [ ] **PAD-03 — Complete identity/business verification**  
  **Owner:** Olly  
  **Private information:** enter identity documents and proof directly in Paddle/Sumsub; never send them to Codex or commit them. Registered businesses may also need business identification.  
  **Done when:** Paddle reports the account verification complete.

- [ ] **PAD-04 — Configure payout and account currency**  
  **Owner:** Olly  
  **Decision:** EUR balance is recommended if it matches the receiving bank account. Configure payout destination and threshold directly in Paddle.  
  **Done when:** Paddle reports payouts ready. No bank details are stored in the project.

- [ ] **PAD-05 — Configure checkout and tax settings**  
  **Owner:** Olly with Codex verification  
  **Settings:** tax-inclusive customer prices, desired live payment methods, approved default payment link `https://kodi-reader.app/checkout`, and the appropriate approved taxable category for hosted Ask AI.  
  **Status:** prices and account default are tax-inclusive; the default payment link is `https://kodi-reader.app/checkout` and is pending domain approval. Payment-method choice awaits the owner's final review.  
  **Done when:** a read-only configuration review matches the approved pricing/policy record.

## Phase 4 — Create live catalog and connect production securely

Start only after Paddle verification and LIVE-04. All Paddle live IDs and credentials are different from sandbox.

- [x] **PROD-01 — Create live products and one-time prices**  
  **Owner:** Codex after explicit price approval  
  **Rules:** EUR, tax included, one-time, quantity fixed at one, no country overrides, no trial, correct tax category.  
  **Evidence:** read-back of product/price IDs and amounts; secrets excluded.  
  **Done when:** exactly three active live packs exist with the approved prices.

- [x] **PROD-02 — Create scoped live credentials**  
  **Owner:** Olly creates; Codex installs without displaying them  
  **Items:** server API key, public client-side token, and live webhook secret. Use the minimum Paddle permissions needed for catalog read, transaction creation/read, adjustment read, and notification handling.  
  **Storage:** Fly secrets for server credentials; Vercel environment variable/static build configuration for the public token. Never commit secrets.  
  **Status:** Live API key has three read scopes and one transaction-write scope and expires 28 December 2026; public client token is deployed to the disabled checkout configuration. Server credentials are Fly secrets.  
  **Done when:** authentication checks pass and no secret is present in Git, logs, app bundle, or browser source.

- [x] **PROD-03 — Create live webhook destination**  
  **Owner:** Codex  
  **URL:** `https://kodi-reader-ai.fly.dev/v1/paddle/webhook`  
  **Events:** `transaction.completed`, `adjustment.created`, `adjustment.updated`.  
  **Done when:** signatures validate and a live-mode test/simulation is recorded without granting unverified credits.

- [x] **PROD-04 — Configure backend secrets and pack map**  
  **Owner:** Codex  
  **Fly settings:** live API key, webhook secret, Supabase secret key, `PADDLE_PACKS_JSON` with live price IDs and approved integer euro-cent amounts, `PADDLE_ENVIRONMENT=live`. Keep `CREDITS_ENFORCED=false`, `PRICING_APPROVED=false`, and `PADDLE_LIVE_APPROVED=false` during deployment verification.  
  **Done when:** production health/auth endpoints pass and checkout remains unavailable while the gates are false.

- [x] **PROD-05 — Configure the public checkout**  
  **Owner:** Codex  
  **Vercel settings:** environment `live`, the live public client token, return-to-app behavior, and enabled state controlled separately from source. Remove any sandbox environment selection.  
  **Done when:** production checkout assets load from the approved domain, but no real checkout can start until the coordinated launch.

## Phase 5 — Release and controlled activation

- [ ] **REL-01 — Finish pre-live acceptance**  
  **Owner:** Codex  
  **Tests:** delayed/duplicate webhook; partial/full refund; dispute/chargeback and reversal; last-credit concurrency; sign-out/account switch; account deletion followed by payment; app relaunch during checkout; browser return blocked; database/provider outage; 401/402/426 behavior; email delivery; Keychain refresh.  
  **Status:** 179 reader/core tests and 26 authentication/credit tests pass. The signed 0.4.0 release candidate passed code-signature verification, Gatekeeper assessment, and Apple notarization. Complete the remaining manual payment matrix after Paddle approves the live account and domain.  
  **Done when:** all automated checks pass and a signed staging build passes the manual matrix.

- [ ] **REL-02 — Build, sign, notarize, and publish the compatible Mac app**  
  **Owner:** Codex; Apple credentials remain with Olly  
  **Order:** app release precedes production credit enforcement. Google/Apple buttons remain disabled unless separately verified.  
  **Status:** version 0.4.0 (build 6) is built, signed with Developer ID, notarized by Apple, and stapled. Publication remains pending; do not enable the production gates before users can obtain this version.  
  **Done when:** users can update to the version that supports auth, credit protocol 1, checkout return, and HTTP 402/426 handling.

- [x] **REL-03 — Deploy production backend with gates closed**  
  **Owner:** Codex  
  **Done when:** new backend code is running, health is green, auth still works, old behavior remains available, and no live purchase is possible.

- [ ] **REL-04 — Activate live payments and credits together**  
  **Owner:** Codex after Olly's explicit launch approval  
  **Coordinated change:** enable the live checkout config and set `CREDITS_ENFORCED=true`, `PRICING_APPROVED=true`, `PADDLE_LIVE_APPROVED=true`. Never set `PADDLE_SANDBOX_ENABLED` in production.  
  **Done when:** catalog, balance, checkout, webhook, and Ask AI credit charging are simultaneously active.

- [ ] **REL-05 — Controlled real-payment smoke test**  
  **Owner:** Olly performs/approves the real purchase; Codex observes system state  
  **Scope:** one smallest-pack purchase with a pre-agreed spending limit. Verify Paddle transaction, signed webhook, exact credit grant, browser return, success screen, one Ask AI charge, receipt, and support/refund path.  
  **Done when:** payment and ledger reconcile, with no duplicate grant. A real purchase is never initiated without action-time approval.

- [ ] **REL-06 — Monitor and document rollback**  
  **Owner:** Codex  
  **Monitor:** webhook failures, checkout failures, reconciliation review queue, AI cost per answer, credit debt, refunds/disputes, auth errors, and Fly/Supabase availability.  
  **Rollback:** disable new checkouts while continuing to accept Paddle webhooks and honor existing balances. Do not disable authentication or credit accounting after sales begin.  
  **Done when:** the owner has a one-page incident/runbook and knows how to pause sales safely.

## Submission packet for Paddle

Prepare this folder before pressing Submit for Approval:

- [ ] Product URL and checkout domain.
- [ ] One-paragraph product description and list of paid deliverables.
- [ ] Approved pack/pricing record or dated app-pricing screenshot.
- [ ] Links to Terms, Refund Policy, Privacy Policy, and Purchase Information.
- [ ] Seller/brand name matching the Paddle profile.
- [ ] Support email that can send and receive.
- [ ] App screenshots showing the reader, Ask AI, credit balance, packs, and payment success.
- [ ] A short screen recording of sign-in → Ask AI → Buy credits → payment confirmation, if Paddle requests product access.
- [ ] Explanation that Kodi Reader is the original macOS software product and Paddle sells one-time Ask AI credit packs; reading is free.
- [ ] A test account only if Paddle requests one. Never provide a personal account or reusable production credential.

## Immediate next actions

1. Olly completes Paddle identity verification and payout settings as an individual/sole trader.
2. Paddle approves `kodi-reader.app`; then re-check the saved default payment link and desired payment methods.
3. Complete the remaining manual acceptance checks and publish the prepared 0.4.0 Mac release while checkout and credit enforcement remain disabled.
4. After Paddle approval and app release, Codex enables the three launch gates and checkout together.
5. Olly performs one controlled Starter purchase; Codex verifies the Paddle transaction, webhook, credit grant, app return, and one-credit Ask AI charge.

## Source requirements checked

- Paddle Account Verification: https://www.paddle.com/help/start/account-verification/what-is-account-verification
- Paddle Domain Review: https://www.paddle.com/help/start/account-verification/what-is-domain-verification
- Paddle Go-live checklist: https://developer.paddle.com/build/go-live-checklist/
