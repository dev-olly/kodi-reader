# Usage analytics

The Mac app sends a small, pseudonymous event stream to the existing Kodi
website. Vercel Functions validate it and store it in the existing Supabase
project. The administrator dashboard is served at `/analytics`; its data API
requires a separate, server-only administrator token.

This feature requires both a website deployment and a new Mac app release.
Previously distributed versions do not send events. There is no historical
reading data to backfill, and the dashboard does not substitute sample counts.
The Expo mobile app is not instrumented by this change.

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

`ANALYTICS_SUPABASE_URL` and a random `ANALYTICS_ADMIN_TOKEN` are configured for
Production. The administrator key is saved in this Mac's login Keychain under
service **Kodi Reader Analytics**, account **admin-2026-10-24**, label
**Kodi Reader Analytics Dashboard**. No administrator key is stored in this repo.

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
- New devices, sessions, page turns, imports, highlights, new notes/sketches and
  meaningful successful editing sessions, web opens, and app version adoption.
  Repeated autosaves do not inflate editing-session counts.
- Approximate upload-country totals, supplied by Vercel connection metadata.
  No GPS location, city, or raw IP address is retained in analytics storage.

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
   Then apply `docs/analytics/003_usage_v2.sql` for the current collector and
   dashboard. It preserves the original ingestion signature for older clients
   and adds no access to authentication or billing records.
2. Add these server environment variables to the **kodi-reader** Vercel project:
   - `ANALYTICS_SUPABASE_URL`: the Supabase project URL.
   - `ANALYTICS_SUPABASE_SERVICE_KEY`: a Supabase server secret key or legacy
     service-role JWT. Never use a publishable key here.
   - `ANALYTICS_ADMIN_TOKEN`: a unique random secret of at least 32 characters.
     Generate it in your password manager, and keep it there for dashboard login.
3. Deploy this website with the project's existing **Root Directory = website**
   and **Other** framework preset. `node build.mjs` copies only public website
   files to `dist`; API handlers remain Vercel Functions. No npm dependencies are
   needed. Node 24 is selected by `website/package.json`.
4. Open `/analytics` on the deployed website and enter the administrator token.
   The token stays in the current page's memory; reloading or signing out requires
   entering it again. It is sent only as a bearer header to the data API. Do not
   put it in URLs, app configuration, public JavaScript, or source control.
5. Build, sign, and distribute the updated Mac app through the normal release
   procedure. Release builds send events to
   `https://www.kodi-reader.app/api/analytics/events`. An HTTPS endpoint may be
   overridden through the `KodiAnalyticsURL` Info.plist key for a separate build.
   Debug and test builds do not collect or transmit production analytics.
6. Use the released app to open a book, turn pages, and send an Ask AI request.
   Refresh the dashboard and verify distinct activity, reading time, and request
   outcomes. Test the Privacy switch: disabled analytics must leave the reader
   and Ask AI usable without new events.

Use a separate Supabase project and different admin token for development or
preview deployments. Copy environment variables through your platform's secret
manager. This repository does not contain or generate production credentials.

## Local checks and preview

```sh
cd website
node --test server/*.test.mjs
node build.mjs
cd ..
node Scripts/analytics-dev.mjs
```

The preview prints `http://127.0.0.1:4173/analytics`. Without configured server
environment variables, the real API returns an explicit configuration error.
There is no built-in demo login or fabricated dataset. To test storage locally,
provide the three environment variables for a separate development Supabase
project before starting the preview server. Keep any local `.env` files ignored.

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
an event name, optional whole seconds of engagement time, and closed properties
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

Settings → Privacy → **Share anonymous usage analytics** is enabled by default
in release builds. Turning it off cancels uploads, clears unsent events, and
removes the saved installation identifier. Turning it on creates a new identifier.
Already received records are not associated with the account and are not removed
by account deletion. See the website's updated privacy notice for user-facing
details.

The dashboard and API use `no-store`, reject unauthenticated data requests, and
return aggregate data rather than installation identifiers. The dashboard has a
restrictive content security policy, no third-party assets, and a noindex header.
The ingestion endpoint bounds payloads, validates every field, and applies a
database-backed per-installation event limit. Provider access logs can still
contain request metadata; do not enable request-body or authorization logging.
