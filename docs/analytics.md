# Usage analytics

The Mac app sends a small, pseudonymous event stream to the existing Kodi
website. Vercel Functions validate it and store it in the existing Supabase
project. The administrator dashboard is served at `/analytics`; its data API
requires Google OAuth as `developer.olly@gmail.com`. The former administrator
token is no longer accepted.

## Dashboard sign-in

Open `https://www.kodi-reader.app/analytics`, choose **Sign in with Google**, and
select `developer.olly@gmail.com`. Other Google accounts and email-code sign-ins
cannot access analytics. This gate applies to the data API as well as the page.

The website uses the existing Supabase Google provider with PKCE. Its callback
verifies the current Google access token with Google's user-info endpoint,
requires a verified matching email and Google subject, then issues a signed
owner authorization cookie bound to that Supabase user and session. Every data
request verifies the user with Supabase Auth and checks the owner authorization.
Cookies are HTTP-only, Secure, SameSite=Lax, and scoped to the website host;
dashboard authorization expires after eight hours. Google provider tokens are
discarded after verification. No auth tokens are exposed to dashboard JavaScript.
**Sign out** revokes this website session and clears its cookies.

The exact callback URL must be added to Supabase Authentication → URL
Configuration → Redirect URLs:
`https://www.kodi-reader.app/api/analytics/auth/callback`.
Keep the Mac app's existing `com.olly.KodiReader://auth/callback` entry. The Google
Cloud client's redirect URI remains the existing Supabase `/auth/v1/callback`.
Never add broad preview wildcards to this production allowlist.

### Production verification · 7 November 2026

Deployment `dpl_3amMF9BGJ1sEPLyHsqGEohFVA1PD` is live on the existing Kodi Reader
domains. The exact website callback was added alongside the native callback;
the Google client configuration and database permissions were not changed.
Production has the owner email, publishable key, canonical origin, and a new
server-only session signing secret configured. `ANALYTICS_ADMIN_TOKEN` was removed.

Real browser acceptance passed with `developer.olly@gmail.com`: Google account
selection, callback, live analytics, session restoration after reload, sign-out,
and the cleared dashboard afterward. Anonymous API requests for 7, 30, and 90 days
and a bearer-only request returned 401 with `no-store`; cross-site logout returned
403. All 26 local server and isolated PostgreSQL tests passed, including denial
of other Google accounts, email-code sessions, forged/expired owner markers,
refresh-cookie propagation, provider-token removal, and callback/logout CSRF.

This feature requires both a website deployment and a new Mac app release.
Previously distributed versions do not send events. There is no historical
reading data to backfill, and the dashboard does not substitute sample counts.
The Expo mobile app is not instrumented by this change.

## Mac refinements for 0.4.9

Reader engagement now includes explicitly marked reader-owned note sheets and
their temporary tools, while Settings, authentication, payment and unrelated
windows pause it. Personal reading goals keep their separate main-window policy.
Input timing is scoped to reader-owned windows rather than every app window.

The Mac displays a one-time, non-blocking usage notice with a direct opt-out.
Settings and the privacy policy describe pseudonymous device counts, approximate
upload country, and engagement that includes notes, drawing and Ask AI.

Meaningful note comparisons exclude internal media/reminder references. Drawing
comparisons ignore viewport and autosave metadata, retain their original baseline
across a partial checkpoint failure, and report only after durable persistence.
Note events follow the successful text checkpoint even if later attachment
cleanup fails. These refinements are prepared for the combined 0.4.9 Mac release.
The combined client sends schema-v3 events; keep `004_feature_usage.sql` and
the matching collector deployed before distributing that build. Both are
already deployed as recorded in the feature-usage verification below.

## Deployment status · 30 October 2026

The existing Kodi Reader Supabase project (`hftfeybmgpousanpawgw`) has the
`add_private_usage_analytics` and `enable_analytics_retention` migrations applied.
The analytics tables have RLS enabled, ordinary client access is revoked, and the
daily `analytics-retention` job is active at 03:20 UTC. The 7-, 30-, and 90-day
aggregate queries and a service-role ingestion/deduplication test passed. Test
events were rolled back; no sample usage remains in the production database.

Production deployment `dpl_HJ9b2YzPPzrHVwQL84eRnVmAkiVq` is ready and assigned to
the existing Kodi Reader domains. The dashboard is live at
`https://www.kodi-reader.app/analytics`. Authenticated API checks passed for
7-, 30-, and 90-day reports with `no-store` responses; unauthenticated requests
return 401. The updated privacy notice includes usage analytics and approximate
upload-country observations.

The original deployment used a random `ANALYTICS_ADMIN_TOKEN`. That retired
administrator key was saved in this Mac's login Keychain under
service **Kodi Reader Analytics**, account **admin-2026-10-24**, label
**Kodi Reader Analytics Dashboard**. It is no longer used for dashboard access.
No administrator key is stored in this repo.

The owner approved configuring `ANALYTICS_SUPABASE_SERVICE_KEY` on 30 October.
The existing project's server key is saved as a masked Production Secret in
Vercel, and the owner completed two-factor reauthentication for redeployment.
No server key was printed or saved in this repository. This deployment supports
the Kodi Reader 0.4.8 Mac client; earlier distributed versions do not send events.

On 30 October 2026, the owner approved and applied `003_usage_v2.sql` as
production migration `20261030162740_usage_analytics_v2`. The current collector
can now use the two-argument ingestion function for request outcomes, meaningful
editing sessions, and approximate upload-country observations. Production smoke
tests passed for both ingestion signatures and the dashboard; their temporary
events were rolled back. Analytics tables retain RLS, ordinary roles have no
table or RPC access, and the functions use service-role-only invoker permissions.
The local API and isolated PostgreSQL integration suite passed all 13 tests,
including reapplication and role restrictions. The optional
`002_server_usage.sql` migration is not required for device telemetry and remains
unapplied.

The local dashboard now also displays real, aggregate account and AI credit-ledger
history captured through the connected Supabase administrator tool. This saved
snapshot is explicitly labeled with its capture time; refreshing the page does
not query production or make the data live. No credentials or individual account
records are included. The local file is ignored by Git and excluded from builds.

`002_server_usage.sql` is a reviewed, tested proposal to add these aggregate
records to the authenticated production dashboard RPC. **It has not been applied
to production.** Automatic approval review rejected its new service-only access
to private auth/credit aggregates without explicit approval. The local snapshot
does not change production permissions or require the Supabase server key.

## Existing account and AI records

When `server_metrics` is available, the leading cards show registered accounts
(all time, excluding deleted users), accounts whose latest sign-in falls in the
selected period, AI accounts with a credit reservation in the period, and AI
request reservations in the period. Registration and AI ledger history are
separate from the anonymous device telemetry below them.

The latest auth sign-in is not a session log: it cannot reconstruct daily active
users or all sign-ins, and opening an already signed-in app may not update it.
Account counts also omit people who read without signing in.

AI request dates come from the credit ledger, not reservation expiry dates.
`reserve` records an accepted request, `answer` records a charged request, and
`release` records a refund or expired reservation. Charged requests can include
an intentional disconnect after generated text. Refunds can include errors,
cancellations, or expiry, so these do not establish completion or failure rates.
Each kind is counted by its own timestamp; period outcomes can relate to requests
reserved before the period. No prompts, response text, IDs, or balances are shown.

Reading time and device/feature counts say **Not measured yet** when no device
telemetry is available. Historical account and AI activity cannot establish how
many people were reading or how much time they spent reading.

## What the dashboard measures

- Active devices: distinct random installation IDs with activity in the period.
- Reading devices: installations with reading activity; both EPUB and PDF are
  covered, including saved webpages read through the reader.
- AI devices: installations with Ask AI request activity. Completed, failed,
  intentionally stopped, and unknown outcomes are matched to requests started
  in the selected period using telemetry-only request IDs.
- Reader engagement: short intervals while the reader workspace is visible and
  the app is in the foreground, including notes, drawing, and Ask AI. Counting
  pauses after two minutes without an interaction.
- New and returning devices, foreground activations, page turns, imports, highlights, new notes/sketches and
  meaningful successful editing sessions, web opens, and app version adoption.
  Repeated autosaves do not inflate editing-session counts.
  Text-note counts ignore internal drawing, audio, and reminder links. Drawing
  counts compare visible elements and referenced image content, ignoring canvas
  viewport, selection, theme, and autosave metadata. Retrying a partial drawing
  checkpoint preserves the original editing intent until persistence succeeds.
- Approximate upload-country totals, supplied by Vercel connection metadata.
  No GPS location, city, or raw IP address is retained in analytics storage.

### Reminders, drawing, recording, and listening

Schema version 3 adds these measurements to the Mac app. The server and dashboard
must be updated before distributing the instrumented app. Already released apps
cannot report historical activity for these features. The dashboard labels
missing collection capability **Not measured yet**, rather than showing zero.

- Reminders: successful creation, title updates, completion, reopening, deletion,
  undo restoration, and source navigation. Unchanged saves and failed persistence
  do not count. A source-open event means navigation was requested, not that a
  research task was finished.
- Sketching: existing new drawings and meaningful editing sessions, plus opening
  an existing drawing and deleting a saved drawing. Existing version-2 creation
  and editing counts remain visible. A drawing time or stroke count is not
  inferred from an open editor, and restored content does not count as creation.
- Recording: actual microphone starts, pauses, resumes, saved takes, discarded
  takes, and recording failures. A take is saved only after the audio and note
  reference have been persisted successfully. Denied permission and preparation
  failures never count as a recording start.
- Listening: text-to-speech playback starts, pauses, resumes, explicit stops,
  completed narrations, and failures. Starts count once when audio first plays,
  not once per synthesized passage. This measures text-to-speech narration,
  separately from playback of saved audio notes.

Each group shows distinct active devices and counts in the selected UTC period.
Recording and listening include separate whole-second activity totals; pauses,
permission prompts, model downloads, and speech synthesis gaps are excluded.
Audio that continues in the background can count. These durations can overlap
foreground reader engagement and must not be added to it as unique time. Each
heartbeat is limited to 1–60 seconds, including delayed timer ticks. Changing
analytics consent resets the clocks so disabled time cannot be backfilled.

Lifecycle actions are counted by their own event times. A take saved or narration
finished in this period may have started earlier, and a narration can fail before
playback starts. These aggregate counts do not establish per-session completion
or failure rates. There are no audio, reminder, drawing, or document identifiers,
titles, text, recordings, transcripts, voice names, or file paths in these events.

`feature_usage` contains `reminders`, `sketching`, `recording`, and `listening`
groups. Metric values include current and previous-period totals; `devices` is a
distinct count across the group's events, not a sum of action-level devices.
Availability is reported separately for the current and previous periods, so a
period before instrumentation is not presented as a measured zero. Coverage
indicates how many active installations sent version-3 events and how many
still use older telemetry. Counts cover received events only; no backfill or
fabricated activity is provided.

Production migration `usage_analytics_feature_usage_v3` and website deployment
`dpl_AZUJTqRd1TjRhCtNmU5D876LzbSZ` were applied on 7 November 2026. Live database
checks covered new ingestion, retry deduplication, separate audio durations,
aggregate counts, and restricted RPC permissions; all temporary events were
rolled back. The owner-authenticated production dashboard displays the four
feature cards, preserves existing drawing counts, and marks new measurements
unavailable until a version-3 client reports activity. All 27 website/database
tests, 87 Mac authentication/analytics tests, the Mac app build, and the
hardware-free recording/narration harnesses passed. The instrumented Mac app is
included in the combined 0.4.9 Mac release preparation.

One person on two Macs counts as two devices. Reinstalling or resetting the
analytics identifier can also produce a new device. A device returning after its
installation record was removed by the 180-day inactivity cleanup counts as new.
These measurements cannot
establish a precise count of individual people. They cover instrumented releases
with analytics enabled and successful event delivery. The ingestion endpoint is
public to support account-free reading, so these are product usage metrics rather
than authenticated financial records.

The period selector supports 7, 30, and 90 days, with UTC calendar days including
today. Previous-period comparisons use the corresponding elapsed time, so a
partial current day is compared with a partial prior day. Trend points are daily
unique counts; adding them does not produce a period's unique device count.

## Production setup

1. Apply `docs/analytics/001_analytics.sql` to your Supabase project using
   its SQL editor or an administrator database connection. It creates only
   analytics-specific objects; it does not change the credit ledger or auth users.
   The migration enables row-level security, denies ordinary clients direct
   access, and grants analytics RPC execution only to `service_role`. Enable
   `pg_cron` and run the retention job at the end of the migration, or schedule
   `select public.analytics_prune();` daily through an existing scheduler. This
   removes raw events and inactive installation records after 180 days.
   Then apply `docs/analytics/003_usage_v2.sql` and
   `docs/analytics/004_feature_usage.sql` for the current collector and dashboard.
   They preserve the original ingestion signatures for older clients and add no
   access to authentication or billing records.
2. Add these server environment variables to the **kodi-reader** Vercel project:
   - `ANALYTICS_SUPABASE_URL`: the Supabase project URL.
   - `ANALYTICS_SUPABASE_SERVICE_KEY`: a Supabase server secret key or legacy
     service-role JWT. Never use a publishable key here.
   - `ANALYTICS_SUPABASE_PUBLISHABLE_KEY`: the same project's publishable key,
     used for the separate user Auth client. Never use the service key here.
   - `ANALYTICS_ADMIN_EMAIL`: `developer.olly@gmail.com`, the only allowed owner.
   - `ANALYTICS_SESSION_SECRET`: a unique random server-only signing secret of at
     least 32 bytes. Save as a Vercel Production Secret, never in browser code.
   - `ANALYTICS_SITE_URL`: `https://www.kodi-reader.app`, the canonical origin.
   Remove the retired `ANALYTICS_ADMIN_TOKEN`; it grants no access in this version.
   Add the exact callback above to Supabase's redirect allowlist and keep Google
   enabled. No database migration or analytics table permission change is needed.
3. Deploy this website with the project's existing **Root Directory = website**
   and **Other** framework preset. `node build.mjs` copies only public website
   files to `dist`; API handlers remain Vercel Functions. `npm ci` installs the
   pinned Supabase Auth dependencies. Node 24 is selected by `website/package.json`.
4. Open `/analytics` on the deployed website and sign in with the owner Google
   account. Check that another account is refused, a direct unauthenticated data
   request returns 401, and signing out returns to the sign-in panel. A valid
   owner session is restored after a reload until its eight-hour limit.
5. Build, sign, and distribute the updated Mac app through the normal release
   procedure. Release builds send events to
   `https://www.kodi-reader.app/api/analytics/events`. An HTTPS endpoint may be
   overridden through the `KodiAnalyticsURL` Info.plist key for a separate build.
   Debug and test builds do not collect or transmit production analytics.
6. Use the released app to open a book, turn pages, and send an Ask AI request.
   Refresh the dashboard and verify distinct activity, reading time, and request
   outcomes. Test the Privacy switch: disabled analytics must leave the reader
   and Ask AI usable without new events.

Use a separate Supabase project and different signing secret for development or
preview deployments. Copy environment variables through your platform's secret
manager. This repository does not contain or generate production credentials.

## Local checks and preview

```sh
cd website
npm ci
node --test server/*.test.mjs
node build.mjs
cd ..
node Scripts/analytics-dev.mjs
```

The preview prints `http://127.0.0.1:4173/analytics`. Without configured server
environment variables, the real API returns an explicit configuration error.
There is no built-in demo login or fabricated dataset. To test storage locally,
provide the server environment variables for a separate development Supabase
project before starting the preview server. Set `ANALYTICS_SITE_URL` to
`http://127.0.0.1:4173` and allow its exact `/api/analytics/auth/callback` URL in
that development project's Auth settings. Only explicit local development uses
non-Secure cookies; Vercel and production always require HTTPS. Keep any local
`.env` files ignored.

For the saved, real production aggregate snapshot already prepared on this Mac:

```sh
ANALYTICS_LOCAL_SNAPSHOT="$PWD/.analytics-local/snapshot.json" node Scripts/analytics-dev.mjs
```

The snapshot file contains `{version: 1, captured_at, periods: {7, 30, 90}}`;
each period uses the dashboard response shape plus `server_metrics`. The local
server requires this explicit environment variable, binds only to `127.0.0.1`,
checks Host/Origin/Fetch-Site, and serves the read-only data at
`/api/analytics/local-snapshot`. Other websites cannot read it through CORS, and
the deployed website has no snapshot route. Keep the directory mode `0700` and
snapshot mode `0600`. To refresh the underlying data, capture new aggregates with
the authorized Supabase tool with `docs/analytics/snapshot.sql`; the page's
Refresh button only rereads the file.

Regenerate the Xcode project with `xcodegen generate` before running the
`KodiReaderAuthTests` target, which includes analytics privacy, lifecycle,
queue, and reading-time checks.

## Privacy and delivery

The payload schema permits only event/installation/session UUIDs, event time,
an event name, optional whole seconds of engagement/recording/listening time, and closed properties
for platform, version, build, document format, schema version, general AI error
category, and a telemetry-only AI request UUID. The country observation is
supplied separately by the Vercel collector rather than the app payload.
Unknown fields are rejected, including content and account identifiers. No
account authorization or cookies are attached to telemetry requests.

The app retains up to 500 unsent events for up to seven days and uploads at most
50 per batch. The queue survives restart. Retries preserve event UUIDs, and the
database deduplicates them before counting. Network or storage failure does not
interrupt reading or AI. Events may be lost if an app is offline long enough,
its bounded queue fills, it quits before transmission, or telemetry is disabled.

Settings → Privacy → **Share usage analytics** is enabled by default
in release builds. Turning it off cancels uploads, clears unsent events, and
removes the saved installation identifier. Turning it on creates a new identifier.
Already received records are not associated with the account and are not removed
by account deletion. See the website's updated privacy notice for user-facing
details. A one-time non-modal notice explains the feature and includes an
immediate opt-out. This preference is independent of local reading goals.

The dashboard and API use `no-store`, reject unauthenticated data requests, and
return aggregate data rather than installation identifiers. The dashboard has a
restrictive content security policy, no third-party assets, and a noindex header.
The ingestion endpoint bounds payloads, validates every field, and applies a
database-backed per-installation event limit. Provider access logs can still
contain request metadata; do not enable request-body or authorization logging.
