# Payment development flag

Public releases keep `PAYMENTS_ENABLED = NO` in `Config/Auth.xcconfig`.
The build exposes this as `PaymentsEnabled` in Info.plist and
`AIFeatureFlags.paymentsEnabled` in Swift. Missing values also disable payments.
This flag is independent of Google, Apple, email, and the sign-in requirement for Ask AI.

Version 0.3.2 is built from the committed authentication-only source. Unfinished
credit and checkout code is excluded from this release checkout.

During payment development, guard balances, purchase UI, credit refreshes,
checkout entry points, payment return URLs, and payment-specific account copy
with this flag. Enable it only in an isolated payment test build using
`PAYMENTS_ENABLED = YES`; keep production builds explicitly set to `NO`.

The server must independently enforce access. While AI is available without
purchases, keep `CREDITS_ENFORCED=false`; sign-in validation and request limits
remain enabled. A client flag cannot override server credit enforcement.
