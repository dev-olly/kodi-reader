# iCloud implementation and release setup

## Current delivery state

The implementation and deterministic two-store tests are present. The normal
Debug/Release configurations retain their existing no-iCloud signing.
On 2026-09-29, container `iCloud.com.olly.KodiReader` was registered and assigned
to the App ID, and CloudKit and Push Notifications were saved. An Apple
Development certificate and Mac development profile were created and installed.
The **Kodi Reader iCloud Developer ID** profile is installed and expires on
2044-09-24. The signed Debug-iCloud reader and smoke target build successfully.
The complete schema in `cloudkit-schema-v1.ckdb` passed CloudKit Console
validation, was imported into Development, and was deployed to Production.
The Developer ID build was notarized and stapled successfully (submission
`b6ba72b9-9bbd-4835-af66-317ce3ad2845`). The test DMG is
`.build/releases/KodiReader-iCloud-test.dmg`. Two physical Macs and a reader
round trip against Production still require verification before release.

Verified on 2026-09-29: all **179** Swift package tests pass, including **33**
sync tests and new native fetch-scope and callback-context regressions. The
signed Development smoke test passes all **6** checks: notes/bookmarks/position
and a 2 MiB drawing, no disabled categories, a chunked 17 MiB PDF downloaded on
request, optional large AI history, concurrent offline note recovery, removal
of a download, and deletion with asset cleanup. Its report is under sandbox
Application Support, run `42ECE8CE-FF5C-4101-99DF-81ACAC12C0C4`.

The **26** authentication tests, note-editor checks and updater lifecycle checks
also passed during this implementation. Release packaging verified the
Production entitlements, embedded profile, Developer ID signature, hardened
runtime and notarization ticket. This is a one-Mac integration test; it does
not verify cross-device push delivery or the real reader on two physical Macs.
Follow [the two-Mac checklist](icloud-two-mac-test.md) before publishing.

## Apple configuration

Use team **3FJF74RW5L**, App ID **com.olly.KodiReader**, and container
**iCloud.com.olly.KodiReader**.

1. In Certificates, Identifiers & Profiles, register the container. Enable
   iCloud with CloudKit and assign this container to Kodi Reader. Enable Push
   Notifications for engine notifications, preserving existing capabilities.
2. Generate a Mac development provisioning profile for this App ID and the
   installed Apple Development certificate. Use a properly signed build for
   live tests, rather than adding cloud entitlements to an ad-hoc binary.
3. Generate a Developer ID provisioning profile named **Kodi Reader iCloud
   Developer ID** for the same App ID and Developer ID Application certificate.
   Install it in Xcode's provisioning profile directory. The profile must permit
   the container, CloudKit service, application identifier, and production push.
4. Generate the Xcode project and build the iCloud scheme:

   ```sh
   xcodegen generate
   xcodebuild -project KodiReader.xcodeproj -scheme KodiReader-iCloud \
     -configuration Debug-iCloud -destination 'platform=macOS' \
     -allowProvisioningUpdates build
   ```

`Debug-iCloud` uses Development CloudKit. `Release-iCloud` uses Production.
Both set `iCloudSyncEnabled=YES` in the built Info.plist. Normal ad-hoc builds
leave it NO and never construct a CKContainer, so the reader remains usable
without Apple provisioning.

Apple references: [private database storage](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase),
[CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5),
[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

## Schema

The private database has three custom zones:

- `KodiLibraryV1`: book metadata, individual annotations, bookmarks, position.
- `KodiAIHistoryV1`: individual saved conversations; excluded from scheduled
  and manual record transfers while AI history is disabled.
- `KodiAssetsV1`: explicitly transferred binary chunks and their ownership roots.
  This zone is excluded from engine metadata fetches.

One native engine manages the private database and persists its checkpoint under
`KodiPrivateV1`. This adjusts the original two-engine design to respect Apple's
[one-engine-per-database restriction in Production](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/database).
Both manual and scheduled fetch scopes exclude assets and disabled AI history.
Existing development per-zone checkpoints trigger a fresh metadata fetch;
durable local edits, ancestors, tombstones and record versions are retained.

The record types and custom fields are:

- `KodiEntity`: `schemaVersion` INT64, `bookID` STRING, `kind` STRING, `deleted`
  INT64, `payload` BYTES, `payloadBlob` BYTES. The payload is a portable versioned
  entity. Above 256 KiB it becomes a chunked asset manifest in `payloadBlob`.
- `KodiAssetRoot`: `bookID` STRING, `scope` STRING.
- `KodiAssetGroup`: `parent` REFERENCE to the root, with delete-self semantics.
- `KodiChunk`: `hash` STRING, `file` ASSET, `parent` REFERENCE to its group with
  delete-self semantics. Each group holds at most 750 chunk references.

The transport uses record-ID fetches and record-zone changes, so no custom query
indexes are needed. Binary record IDs include the entity scope and whole-blob
hash. Chunks are immutable and checksum-addressed, with a maximum size of 16 MiB.
Deleting an asset root cascades through its groups and chunks. Content-free
metadata tombstones remain durable. Cleanup receipts prevent repeated full-zone
asset scans on every sync.

An explicit re-import after a synchronized deletion first clears the old book
tombstone without publishing a file manifest, then uses fresh asset generations.
This prevents delayed cleanup from removing replacement chunks. Recovery entries
from concurrent whole-book deletions remain local when reopened. Re-enabling sync
after an account change clears old file manifests; books not downloaded on this
Mac must be located again rather than publishing references into another account.

Create all fields in the Development schema before release: exercise metadata,
drawings, files, deletion, and an AI conversation over 256 KiB. A schema created
only from small notes will omit `payloadBlob` and asset record types. Export the
complete Development schema using CloudKit Console or `cktool`, review it, and
deploy it to Production. Apple's [cktool walkthrough](https://developer.apple.com/videos/play/wwdc2021/10118/)
explains schema export, validation, and import. Credentials belong in Keychain,
not this repository, command logs, or shell history.

## Local persistence and merge behavior

`LibraryStore` keeps `library.json`, imported Books, and Drawing sidecars. Its
additive v5 migration first makes `library.before-icloud.json` and normalizes
legacy conversations to stable IDs. Local IDs and file paths remain local.
Missing book files retain their local records and cannot upload until located.

`Sync/journal.json` is atomic and stores outgoing changes, ancestors, server
record fields, engine checkpoints, deletion/cleanup receipts, deferred merges,
device ID, and this Mac's preferences. Local uploads are captured only from
successfully persisted library snapshots. Incoming entities and recovery copies
are committed before engine checkpoint updates. Interrupted transfers resume
from verified cached chunks; final reconstructed files install atomically.

An account change archives the previous journal under `Sync/Accounts/` on explicit
re-enablement. It preserves local files and requires acknowledgement before the
new account receives this Mac's library. A deleted known record zone or externally
deleted metadata record pauses sync rather than restoring removed cloud data.

Conflicts use a synchronized ancestor for each entity. Independent annotation
fields merge; divergent text or drawings retain deterministic recovery copies.
Chat prefix extensions merge; divergent histories preserve recovered threads.
Position uses modification time and a stable device-ID tie breaker. Active
editors defer merges; active readers keep their current viewport.

## Validation before release

### Live smoke test on one Mac

Development signing is configured on this Mac. To rerun the test:

```sh
Scripts/test-icloud-live.sh
```

This builds the separate `KodiReader-SyncSmoke` scheme with the official App ID
and a Development profile, verifies its signature, entitlements, and profile,
then exercises the real private CloudKit database through two isolated local
stores. The test disables automatic engine scheduling, following Apple's
[native integration test example](https://github.com/apple/sample-cloudkit-sync-engine/blob/main/Tests/SyncTests.swift),
to control simulated devices independently; the reader keeps automatic sync
and registers for remote notifications. It does not read Kodi Reader's normal local library or call an AI API.
The signed live run passes. Its generated data covers notes, bookmarks, position, a 2 MiB drawing, a valid
17 MiB PDF, on-demand download, per-client preferences, optional large AI
history, concurrent offline edits, removal of a download, and book deletion.
The local `--fixture-check` passes: PDFKit opens the generated PDF as one page,
and its bytes exceed the 16 MiB transfer boundary. The launcher passes shell
syntax validation, and an unsigned smoke binary exits cleanly before contacting
CloudKit. The fixture-only and unsigned-guard checks do not connect to Apple's service; the full signed test does.

Successful runs delete only their uniquely identified synthetic book and
collect its assets; durable tombstones remain. Failed or interrupted runs keep
their fixture for inspection. The console prints the report location under
`Application Support/KodiReaderCloudKitSmoke/<run UUID>/result.json` in the app's
sandbox. Build and verification output is retained under `.build/`. Failed test fixtures
can be removed with the signed Development smoke executable's
`--cleanup-run <run UUID>` option. It verifies the local synthetic PDF hash and
both local/server fixture labels before tombstoning that exact book and
collecting its assets; it never deletes a zone or the real library. The failed
fixtures created during implementation have been cleaned up.
This supplements, and does not replace, testing two physical Macs.

### Reader and persistence checks

Run the repository checks:

```sh
swift test
xcodebuild -project KodiReader.xcodeproj -scheme KodiReader \
  -configuration Debug -destination 'platform=macOS' test
Scripts/test-note-editor.sh
Scripts/test-updater.sh /absolute/path/to/build/products/Debug
```

The sync tests cover two stores, disabled categories, drawing conflicts, recovery
IDs, deletion and whole-book recovery, restart, identity renames, corrupted and
interrupted downloads, large history, storage exhaustion, account changes,
editor deferral, first-enable position merges, and migration. They inject a
transport; they do not prove Apple's native service behavior.

On **two physical Macs with the same iCloud account**, verify both modes and
different per-Mac settings, then optional AI history. Check on-demand download,
offline download removal, files over 16 MiB, large drawings and history, offline
edits, concurrent field/text/drawing/chat edits, reading positions, hidden books,
and deletion while the other Mac is offline. Confirm an active reader does not
jump and an open editor or streamed AI reply survives a remote edit. Verify no
Apple account, quota exhaustion, sign-out/account switch, cleared cloud data,
disabled transfers, and app restart after interrupted uploads/downloads.

Inspect CloudKit Console to confirm asset-zone records are not fetched during
notes-only metadata sync, manifests appear only after chunks, tombstones persist,
and deletion removes binary assets. Inspect Console logs: only counts and error
codes should appear, never note text, books, or conversation contents.

## Distribution

The schema and profiles are configured. To create a new distribution build:

```sh
KODI_DERIVED_DATA="$PWD/.build/ICloudReleaseDerivedData" \
KODI_PACKAGE_STAGING="$PWD/.build/dmg-icloud" \
KODI_DMG_PATH="$PWD/.build/releases/KodiReader-iCloud-test.dmg" \
Scripts/package-dmg.sh --icloud --notarize
```

Packaging uses Release-iCloud and preserves the app's resolved entitlements
during final signing, including its embedded provisioning profile. It fails if
the profile or container is missing. Check the final app's Production environment,
CloudKit and push entitlements, profile expiry, Developer ID signature, hardened
runtime, and notarization ticket. Install the final DMG on both Macs and repeat a
small sync round trip against Production before publishing. Keep ad-hoc and
no-iCloud builds available for local work.
