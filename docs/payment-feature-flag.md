# Payment development flag

Version 0.3.2 shipped with `PAYMENTS_ENABLED = NO`. Beginning with 0.4.0,
production builds set it to `YES` so the installed app supports the credit
protocol, balances, checkout return URLs, and purchases when the server launch
gates open. The build exposes this value as `PaymentsEnabled` in Info.plist and
`AIFeatureFlags.paymentsEnabled` in Swift. Missing values still disable payments.

The server remains the launch authority. While `CREDITS_ENFORCED=false`, the app
keeps the balance and purchase controls hidden and Ask AI continues under the
authenticated rollout limits. When enforcement is enabled, the authenticated
credits response makes the controls visible without requiring another app build.
Google and Apple sign-in remain separately gated.

Keep `CREDITS_ENFORCED=false`, `PRICING_APPROVED=false`, and
`PADDLE_LIVE_APPROVED=false` until Paddle approves the account and checkout
domain and the compatible app has shipped. A client flag cannot override server
credit enforcement.
