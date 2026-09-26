# Ask AI email sign-in setup

The app uses the Auth product of the official Supabase Swift SDK (pinned to 2.55.2).
The existing Fly proxy validates each request with Supabase `getUser(token)`.
Reading, notes, and local conversation history work without an account or network.
This phase does not grant, charge, or display credits and does not include payments.

## Current setup status (2026-09-24)

- Supabase project: `Kodi Reader`, reference `hftfeybmgpousanpawgw`, Frankfurt.
- Email signup and confirmation are enabled; anonymous and other providers are disabled.
- Email codes are configured as 6 digits with a 600-second expiry.
- Site URL: `https://www.kodi-reader.app`.
- The ignored `Config/Auth.local.xcconfig` contains this project's public URL and
  publishable key. The configured Developer ID Release build and signature check passed.
- Purelymail SMTP saved: `smtp.purelymail.com`, port 465, sender/username
  `olly@kodi-reader.app`, sender name `Kodi Reader`, 60-second per-user interval.
  No SMTP password is stored in this repository. Both Confirm sign up and Magic link
  or OTP templates send codes with no sign-in link.
- Real signed-app checks passed: new-user email delivery and verification, draft
  preservation without automatically sending, session restoration after quit/relaunch,
  sign-out, returning-user email delivery, rejection of a wrong code, and successful
  verification with the correct code. Tests used `olly@kodi-reader.app`.
- Fly's `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and server-only
  `SUPABASE_SECRET_KEY` are deployed from Fly's encrypted secrets. The admin key was
  saved with user approval on September 24. It is not in the Mac app or repository.
- [Kodi Reader v0.3.0](https://github.com/dev-olly/kodi-reader/releases/tag/v0.3.0)
  was published with a clean Developer ID build, Apple notarization, and a stapled
  ticket before the authenticated backend was deployed. Both Fly machines are healthy.
- Release validation passed: 145 Swift package tests, 15 app authentication tests,
  and 14 API tests. Live checks confirmed public health, rejection of unauthenticated
  chat and deletion requests, an authenticated streamed AI reply, deletion of a newly
  created disposable account, its removal from Supabase, and rejection of its old token.
  No existing account was deleted.

## 1. Create Supabase and configure email

1. Create a Supabase project. Save its project URL and **publishable key** for the app.
2. Enable email sign-in and new-user signup. Require email confirmation. Leave anonymous,
   phone, and social sign-in disabled. The same email-code flow handles signup and login.
3. Set the email OTP length to **6**, expiry to **600 seconds**, and sending cooldown to
   **60 seconds**. Keep verification and email sending rate limits enabled. Review delivery
   quotas with the chosen SMTP provider before a public launch.
4. In both the Confirm sign up and Magic link or OTP email templates, use
   `{{ .Token }}` instead of a confirmation URL:

   ```html
   <h2>Sign in to Kodi Reader</h2>
   <p>Your sign-in code is <strong>{{ .Token }}</strong>.</p>
   <p>Enter this code in Ask AI. It expires in 10 minutes.</p>
   <p>If you did not request this code, you can ignore this email.</p>
   ```

5. Set up custom SMTP with a verified sender on a domain you own (for example,
   `login@your-domain.com`). Add the DNS records supplied by the email provider.
   A paid inbox is not needed just for sending codes. Configure sender name and SMTP
   credentials in Supabase, never in the Mac app or repository.
6. Test delivery to an address outside your Supabase project team. The built-in email
   sender is restricted to approved team addresses and is not the production delivery path.

No redirect URL, custom URL scheme, or login website is used by the app's code flow.
If Supabase asks for a project Site URL, it is not a callback for this native flow.

References: [email codes](https://supabase.com/docs/guides/auth/auth-email-passwordless),
[custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp).

## 2. Configure and build the Mac app

Copy `Config/Auth.local.xcconfig.example` to `Config/Auth.local.xcconfig` and replace the
two placeholders. The local file is ignored by Git and read by Debug and Release builds.
Keep the `https:/$()/` syntax: xcconfig treats an unescaped `//` as a comment.

Only the URL and publishable key belong in the app. Never embed a Supabase secret key,
legacy `service_role` key, SMTP password, or AI provider key. The public values are
intentionally visible in the built app's Info.plist. CI can instead supply
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` as Xcode build settings.

```sh
xcodegen generate
xcodebuild -project KodiReader.xcodeproj -scheme KodiReader \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The SDK uses macOS Keychain under service `com.olly.KodiReader.auth`, scoped to the
Supabase project host. Tokens are not written to library JSON or UserDefaults.
For manual persistence checks use a consistently signed build; changing signing
identities or sandbox settings can affect Keychain access.

## 3. Configure the existing Fly backend

Backend repository: `../kodi-reader-ai`. Use Node 22 or newer and run `npm ci`, then
`npm test`. Set these through Fly's secret management UI or secure CLI input:

- `SUPABASE_URL`: same project as the app.
- `SUPABASE_PUBLISHABLE_KEY`: same public key as the app.
- `SUPABASE_SECRET_KEY`: server-only key allowing Supabase admin account deletion.
- `OPENAI_API_KEY`: existing server-only provider key.

`USER_RATE_LIMIT_REQUESTS` defaults to 60 per hour. Existing IP limits remain 60 per
hour, and both are in-memory and reset with the process. They are not a credit ledger
and are not shared across Fly machines. Use a limited rollout until paid usage is built.

No database migrations or application profile table are needed for this phase.
Later credit accounts should reference the verified Supabase user UUID, never the email.

## 4. Release and manual acceptance

1. Configure Supabase and verify real email delivery before distributing the app.
2. On a signed Mac build, verify first signup, returning sign-in, wrong/expired codes,
   resend cooldown, closing the sign-in sheet, relaunch, token refresh, and offline reading.
3. Confirm the draft and passage references survive sign-in and failures. Successful
   sign-in returns to the draft; it never sends the question automatically.
4. Verify sign-out cancels streaming and clears the session. Delete a disposable test
   account; confirm it disappears from Supabase while local books and notes remain.
   If deletion fails, the app keeps the session and displays an error.
5. Release the configured Mac app **before** deploying the authenticated proxy. Then
   deploy the backend promptly: older app versions will receive a sign-in error and must
   update. Do not add a permanent anonymous fallback or auth-disable environment switch.
6. Check `/health`, send a request without a token (expect `401 auth_required`), then
   verify a signed-in streamed reply. Monitor auth failures, 503 errors, SMTP delivery,
   and AI spending without logging tokens, codes, emails, or book content.

The backend returns `503 auth_unavailable` for missing configuration or auth-service
outages. These must not sign the user out or permit anonymous requests. AI provider
authentication failures return 502, not a user-session 401.

Account deletion uses `DELETE /v1/account` with the user's bearer token and deletes only
the user ID returned by Supabase. Signing out affects this Mac's session; already-issued
access tokens expire according to Supabase's session policy. Deleting an account is
checked on every subsequent request through `getUser`, rather than trusting JWT claims alone.

Live Supabase setup, email delivery, and signed-build end-to-end checks require the
project and sender domain to exist; mocked tests do not certify those external services.

## Google sign-in setup (2026-09-26)

The Google Cloud web OAuth client `Kodi Reader Supabase` has been created. The
owner configured its client ID and secret in Supabase and added
`com.olly.KodiReader://auth/callback` to the redirect allowlist. A read of
Supabase's public auth settings confirmed Google and email are enabled; Apple
is still disabled.

The Google client's authorized redirect URI is
`https://hftfeybmgpousanpawgw.supabase.co/auth/v1/callback`. The Google client
secret belongs only in Supabase, never in the app's xcconfig or Info.plist.
`GOOGLE_SIGN_IN_ENABLED = YES` is set in the ignored `Config/Auth.local.xcconfig`
for local signed builds. Distributed builds must carry the same flag after
signed-app acceptance. Native callback capture uses the app's retained `ASWebAuthenticationSession`
with a nonisolated completion handler. Supabase's `launchFlow` overload still
handles the PKCE code exchange and session storage. This avoids the main-actor
assertion in Supabase Swift 2.55.2's browser convenience callback, observed in the
2026-09-26 signed-app crash report when macOS delivered completion on an XPC
background queue.

Real Google sign-in, cancellation, and persistence after relaunch still need
verification in a signed build. If the Google consent app is in Testing mode,
the testing account must be on its test-user list. Apple setup is separate.

## Apple sign-in setup (Developer ID distribution)

Kodi Reader is distributed using Developer ID rather than the Mac App Store.
Apple's [macOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
does not support native Sign in with Apple for Developer ID profiles. The app
therefore uses browser OAuth through Supabase, with the same retained browser
session and nonisolated callback handler as Google. Do not add the native
`com.apple.developer.applesignin` entitlement to the Developer ID build.

1. In Apple Developer → Certificates, Identifiers & Profiles → Identifiers,
   select the App ID `com.olly.KodiReader` (register it if absent). Enable
   Sign in with Apple, configure it as a primary App ID, and save.
2. Register a Services ID, suggested identifier `com.olly.KodiReader.auth` and
   description `Kodi Reader Sign In`. Enable Sign in with Apple for that
   Services ID and associate it with the primary App ID above.
3. Under the Services ID's Website URLs, enter domain
   `hftfeybmgpousanpawgw.supabase.co` and return URL
   `https://hftfeybmgpousanpawgw.supabase.co/auth/v1/callback`. Save.
4. Under Keys, create a Sign in with Apple key associated with the primary
   App ID. Record its Key ID and the developer Team ID (`3FJF74RW5L` for the
   current signing team). Download its `.p8` private key and store it securely,
   outside the repository. Never paste the key into chat or embed it in the app.
5. In Supabase → Authentication → Sign-in providers → Apple, enable Apple,
   set the first Client ID to the Services ID from step 2, and configure its
   OAuth client secret. Generate that secret using the Team ID, Key ID,
   Services ID, and private key via Supabase's documented local/browser tool.
   Do not use the native bundle ID as the OAuth client ID.
6. Keep `com.olly.KodiReader://auth/callback` in Supabase's redirect allowlist.
   Google and Apple share this app return URL.
7. After configuration, set `APPLE_SIGN_IN_ENABLED = YES` in the ignored
   `Config/Auth.local.xcconfig`, build with Developer ID signing, and test
   successful sign-in, cancellation, Hide My Email, and session persistence.
   Keep the flag off until configuration is ready. No Apple private key or
   OAuth client secret belongs in xcconfig or Info.plist.

Apple OAuth client secrets expire after at most six months. Rotate the secret
in Supabase before expiry; retain the private key securely for this purpose.
The owner completed the App ID, Services ID, key, and Supabase configuration on
2026-09-26. Supabase's public settings confirmed Apple, Google, and email are
enabled. `APPLE_SIGN_IN_ENABLED = YES` is set in the ignored local xcconfig.
Real Apple sign-in, Hide My Email, cancellation, and signed-app session
persistence remain pending verification. All 25 authentication tests passed;
mocked tests cover the PKCE callback exchange and storage for both providers.

References: [Apple web setup](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/),
[Supabase Apple provider](https://supabase.com/docs/guides/auth/social-login/auth-apple).