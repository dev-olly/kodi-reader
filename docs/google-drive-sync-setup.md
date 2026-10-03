# Google Drive implementation and release setup

## Current delivery state

The Google transport, provider UI, durable per-account journals, and local
deterministic tests are implemented. On 3 October 2026, the existing Google
Cloud project `kodi-reader` was inspected: Drive API is enabled, its only
OAuth client is a web client for Supabase, and the external consent screen is
in Testing with incomplete branding. A Desktop OAuth client is not configured
in `Config/Auth.local.xcconfig`. The app compiles and focused local tests pass,
but live Google Drive authorization, two-Mac testing, production consent, and a
Google-enabled notarized release remain to be completed.
The repository privacy page includes Google Drive sync, but the live site still
shows the earlier iCloud-only policy; publish the updated page before production
OAuth rollout.

## Google configuration

1. Create or select a Google Cloud project for Kodi Reader. Enable the Google
   Drive API. Configure the OAuth consent screen for production, adding Kodi's
   name, homepage, privacy policy, and support contact. Request only
   `https://www.googleapis.com/auth/drive.appdata` for Drive sync.
2. Create an OAuth client of type **Desktop app**. Put its public client ID in
   ignored `Config/Auth.local.xcconfig` as
   `GOOGLE_DRIVE_CLIENT_ID = <client-id>.apps.googleusercontent.com`. Do not add
   a client secret: desktop apps cannot keep one confidential. The Ask AI Google
   sign-in client and scopes are separate.
3. Generate the project with `xcodegen generate`. Build a Debug or Debug-iCloud
   app and verify **Connect Google Drive** opens the system browser, completes
   authorization through a random loopback port, and identifies the account.
   Sandboxed development entitlements include `network.server` for the local
   callback. The refresh token is stored in macOS Keychain; access tokens are
   held only in memory.
4. Before public release, move the external OAuth consent screen to Production.
   External Testing-mode refresh tokens can expire after seven days. Review Drive
   API usage, quota, and project cost controls. Package a Developer ID signed,
   notarized app with `Scripts/package-dmg.sh --icloud --google-drive --notarize`
   and verify the final app's `GoogleDriveClientID` is populated. The release
   script checks this when `--google-drive` is specified.

Google references: [app-data folder](https://developers.google.com/workspace/drive/api/guides/appdata),
[desktop OAuth and PKCE](https://developers.google.com/identity/protocols/oauth2/native-app),
[Drive change feed](https://developers.google.com/workspace/drive/api/reference/rest/v3/changes/list),
[resumable uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), and
[usage limits](https://developers.google.com/workspace/drive/api/guides/limits).

## Local state and conflict behavior

`Sync/selection.json` chooses one provider on this Mac. Existing iCloud state
stays at `Sync/journal.json`; Drive journals are under `Sync/GoogleDrive/<hash of
permission ID>/journal.json`. The stable Drive permission ID isolates accounts.
Each journal stores outgoing changes, last synchronized entities, cursor, server
heads, and this Mac's settings. The local library, book paths, and drawing files
remain in the original local store.

Drive metadata uses individual versioned files in `appDataFolder`. Notes,
bookmarks, book details, and optional conversations have immutable revisions
with parent IDs, so concurrent edits cannot replace each other. Position uses
one mutable checkpoint file per device to bound storage. Metadata fetches do
not download book chunks. Binary chunks are checksum-addressed and at most
16 MiB; uploads use Drive resumable sessions and downloads are verified before
atomic installation. An interrupted upload reuses an already published chunk
by its deterministic name. Tombstones prevent old offline metadata from
resurrecting deleted content. Immutable historical chunks are retained until a
safe multi-device pruning protocol exists, to allow recovery of drawing edits
from offline devices.

On first sync Kodi obtains a start change token, scans metadata, then replays
changes after that token. Received library changes commit locally before the
cursor advances. Enabling AI history starts a full metadata scan so messages
that arrived while it was off are included. Loss of Kodi's known Drive marker
or metadata pauses sync instead of silently restoring the cloud copy.

## Validation

Run focused deterministic tests and the app build:

```sh
swift test --filter GoogleDriveSyncTransportTests
swift test --filter LibrarySyncTests
xcodegen generate
xcodebuild -project KodiReader.xcodeproj -scheme KodiReader \
  -configuration Debug -destination 'platform=macOS' build
```

On **two physical Macs using one Google account**, test both content modes,
different per-Mac choices, optional AI history, offline edits, concurrent note
and drawing edits, deletion, on-demand and offline downloads, a PDF larger than
16 MiB, restart during upload, and the active five-minute remote check. Then
switch one Mac from iCloud to Google and back. Confirm the copy prompt, missing
book handling, separate journals, and unchanged older cloud copy. Repeat with
a different Google account, no connection, revoked permission, rate limiting,
and exhausted Google storage. Verify the iCloud tests and signed build before
publishing an update.
