# Paddle sandbox catalog

This isolated setup tool uses Paddle's official Node SDK. It cannot target live Paddle and does not change the app, backend, checkout, or credit balances.

Use Node 22+, then run `npm ci --ignore-scripts` in this directory.

Provide `PADDLE_SANDBOX_API_KEY` in the environment, or save the key in the repository's ignored `.build/paddle-sandbox.key` with mode 0600. `PADDLE_API_KEY` is also supported, but a live key is always rejected. Never put keys in command-line arguments, source files, or chat.

- `node setup.mjs` checks authentication and lists only Kodi catalog metadata; it makes no changes.
- `node setup.mjs --apply --amounts=100,200,300` creates the agreed sandbox packs at those euro-cent test amounts and reads them back for verification. The user approved these test amounts on 26 September 2026. They are not retail prices.

The packs contain 250 / 600 / 1,400 credits, use one-time EUR prices with tax included, and have quantity fixed at one. The `saas` tax category describes the cloud-hosted Ask AI service and must be available in the Paddle account. Confirm the category during live onboarding.

Re-running reuses matching tagged products and prices. Conflicting or duplicate catalog entries fail closed instead of being overwritten. After a network failure, run the read-only check before retrying; do not run multiple setup processes concurrently.

Verified IDs and the backend `PADDLE_PACKS_JSON` shape are saved to `.build/paddle-sandbox-catalog.json`. Use them only with an isolated staging backend/database. This script does not enable purchases or approve production prices.

## Local checkout test

`checkout-test.mjs` reuses the adjacent `kodi-reader-ai` repository's Paddle adapter and SQL migration. It needs that repository's dependencies installed, plus a local PostgreSQL server at `127.0.0.1:55439` with a `kodi_sandbox` administrator. It creates a uniquely named test database. Never substitute a hosted database.

1. Run `node checkout-test.mjs serve` (serves port 55440 on loopback only).
2. Open a temporary HTTPS tunnel to port 55440. Only the checkout assets/legal pages and signed webhook are served; database and administrative actions are not exposed.
3. Run `node checkout-test.mjs connect https://YOUR-TEMPORARY.trycloudflare.com` to create/reuse the sandbox public client token and webhook destination. Private connection settings are saved in `.build/paddle-sandbox-connection.json`.
4. Approve that exact domain in Paddle sandbox and set the default payment link to its `/checkout` page.
5. Run `node checkout-test.mjs checkout starter` and open the returned URL. Use synthetic customer details and official Paddle test cards only.
6. Use `status` to inspect the test ledger, `provider-status` to check transactions after uncertain responses, `replay` for duplicate notification delivery, and `refund` for a full test refund. `refund` reuses an existing adjustment instead of issuing another. `payment-status` reads refund approval status. After approval, `verify-refund` asserts the single Starter purchase was reversed exactly once and only the 25 welcome credits remain.
7. Run `node checkout-test.mjs disconnect` before shutting down the server/tunnel; this disables the temporary webhook destination. Reset the temporary default payment link before reusing the account.

The latest local test database name and synthetic user ID are in `.build/paddle-local-test.json`. Keep the database available until pending sandbox refunds have been observed. These tests do not replace signed Mac build/authentication acceptance.

## Testing from the Mac app

Build the separate signed app after starting the checkout harness and connecting its tunnel as above:

```sh
xcodegen generate
xcodebuild -project KodiReader.xcodeproj -scheme KodiReader -configuration Release \
  -derivedDataPath .build/AuthReleaseDerivedData \
  KODI_PRODUCT_NAME='Kodi Reader Sandbox' \
  KODI_BUNDLE_IDENTIFIER=com.olly.KodiReader.Sandbox \
  PAYMENTS_ENABLED=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) KODI_PAYMENT_SANDBOX' build
node Tools/paddle-sandbox/native-server.mjs
```

The app is at `.build/AuthReleaseDerivedData/Build/Products/Release/Kodi Reader Sandbox.app`. It has separate local storage and Keychain sign-in, disables Sparkle updates, and uses a compile-time loopback endpoint at port 55441. Regular builds keep their production endpoint. The native backend reads only public Supabase configuration from the signed sandbox app, verifies real sessions using the existing auth implementation, and links verified IDs to the local test ledger. No production database/admin key is accepted. Account deletion is blocked in this test backend.

The actual backend handles balances, purchases, limits, credit reservations, and streaming. AI calls are forwarded with the signed-in user's bearer token to the existing Kodi AI service; no OpenAI key is extracted. The proxy intentionally omits the credit protocol header, so a future credit-enforced production backend will reject requests rather than charge production credits too. The public tunnel still exposes only checkout assets and signed webhooks; account APIs remain on loopback.

Keep PostgreSQL, the checkout server, tunnel, and native server running while testing. Restarting `serve` creates a fresh test database; restarting only the native server preserves the current one. If the tunnel changes, reconnect its webhook and approve the new sandbox checkout domain. The transaction-specific checkout URL overrides the sandbox's existing default payment link.

In **Kodi Reader Sandbox**: sign in, open a book/document, open Ask AI, and choose **Buy credits**. Starter costs a test €1 for 250 credits. Use Paddle's `4242 4242 4242 4242` card, a future expiry, any three-digit CVC, and synthetic billing details. Checkout requests reopening the app; accept the browser's Open Kodi Reader Sandbox prompt if shown. The app automatically checks the authenticated order status and displays **Credits added** after webhook confirmation. Choose **Continue with Ask AI** to return to the composer. A fresh account with no questions sent should have 275 credits after Starter. A successful answer should then use one credit. Never use a real payment card.

`node --test Tools/paddle-sandbox/native-adapter.test.mjs` verifies anonymous rejection, blocked account deletion, concurrent user-token separation, local reserve/settle calls, and omission of production credit headers. Stop the native server along with the checkout harness/tunnel when testing ends; disable the webhook with `disconnect` first.
