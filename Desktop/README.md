# Kodi Reader for Windows and Linux

The `Desktop/` app uses Tauri 2, Rust, React and the vendored Kodi EPUB reader.
Its local library, publication parsing, rendering adapters, audio, authentication
and release pipeline are separate from the existing Swift and Expo apps.

**Status:** a working implementation under native verification. Public downloads
remain gated by `release-acceptance.json`. A successful compile or an internal
CI installer does not record a native acceptance pass.

## Verification recorded during implementation

On the macOS development host, 122 Rust tests, 113 desktop JavaScript tests and
39 website tests passed, along with TypeScript, the production frontend build
and strict workspace Clippy. Native UI checks exercised EPUB reading and page
restoration, text selection, saving a Unicode Markdown note and an Excalidraw
attachment in an isolated test library. PocketTTS narration and Whisper
transcription ran with network access disabled after verified model downloads;
the real FFmpeg codec also passed synthetic recording recovery checks.
The Mac test app also passed a visual check that the book stays below the full
reading toolbar and outside side panels when the window is resized.
Forward/back chapter transitions were checked after adding session-scoped
commands; obsolete updates no longer display a false session-ended warning.
The [desktop fixes list](docs/fixes.md) tracks the subsequent paste, note-editor
and slash-command feedback, including checks still pending on real devices.
The functional review also checked library rename/search, global notes, reminder
completion/return-to-source, and PDF selection, rotation/crop, outlines and saved
page/note restoration against the actual Mac test app.
The final live pass verified spoken microphone capture, AAC/M4A saving and local
playback, narration pause/speed/seek, a persisted Ask AI reply, slider keyboard
focus and backward navigation to the previous chapter's last page.
The Library review passed single-menu dismissal and action activation, then
removed and reimported a PDF while preserving its page-three position and note.

The Apple boundary check verifies all 288 starting files, including existing
uncommitted work. Its clean-CI allowance uses recorded commit hashes and does
not depend on a full Git history checkout.
During the November 12 Library review the first full boundary check passed.
A later check detected a concurrent change to `App/AI/AIChatService.swift`;
that file and the recorded baseline were left untouched by the desktop work.

These checks do not establish Windows/Linux native acceptance, live Drive
interoperability, account deletion, microphone denial/device changes, signed
updates or installer data retention. Those release gates remain pending in
`release-acceptance.json`.

## Development

Use Node.js 24 and the Rust 1.90.0 toolchain pinned in `rust-toolchain.toml`.
On Windows install Visual Studio Build Tools with the C++ workload, Windows SDK,
and WebView2. On Ubuntu 24.04 install the native dependencies:

```sh
sudo apt-get install build-essential pkg-config cmake libwebkit2gtk-4.1-dev \
  libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libasound2-dev \
  libsecret-1-dev libdbus-1-dev patchelf
```

From this directory:

```sh
npm ci
npm run check
cargo test --manifest-path src-tauri/Cargo.toml --locked --workspace
npm run desktop:dev
```

The app enables native recording/playback and local speech/transcription. The
standalone services crate also supports builds without speech for focused tests:

```sh
cargo test --manifest-path src-tauri/Cargo.toml -p kodi-desktop-services --all-features
```

The macOS host can run Rust/frontend verification during development. Windows
and Linux installers must be built and exercised on their native systems. Linux
acceptance includes both Wayland and X11, including child-webview layout, DPI,
focus, selection popovers and sidebars.

## Configuration and local data

`.env.example` lists the public desktop client configuration. Copy it to `.env`
and fill in the public configuration. `npm run tauri`, `desktop:dev`, and
`desktop:build` load it for the native build; exported shell/CI values take
precedence. Supabase publishable keys and installed-app Google OAuth identifiers
are client configuration. Server API keys and Supabase service-role keys belong
on the server.
`KODI_GOOGLE_CLIENT_SECRET`, when provided, is the value from the downloaded
Google **Desktop app** client configuration. It is optional and public in a
distributed native app; it accompanies PKCE and the loopback callback. Do not
substitute web-server or service-account credentials. See Google's
[installed-app OAuth guidance](https://developers.google.com/identity/protocols/oauth2/native-app).

Ask AI and Google Drive become available after their public client configuration
is provided. Basic offline reading does not require either account. Credentials
stay in Windows Credential Manager or Linux Secret Service. A Linux desktop needs
an unlocked Secret Service implementation for account sign-in to persist.

The app uses its platform application-data directory. `library.json` stores
reading state and metadata; `Books/` holds immutable imported originals,
`Covers/` covers, and `Drawings/` and `Audio/` note attachments. Library changes
are validated and replaced atomically, with `library.backup.json` retaining the
previous readable snapshot. Corrupt primary files are preserved before backup
recovery. Unsupported future schemas fail without resetting the library.

The new local JSON schema uses Unix timestamps and camelCase fields. Google Drive
projects supported data into the existing Mac sync wire format with explicit
timestamp conversion. The desktop `library.json` is not a file to copy over a
Mac or iOS library. Existing PDFKit `pdfRanges` are retained; PDF.js geometry is
local until cross-renderer compatibility is established. The native acceptance
guide requires actual Mac round trips before a public release.

## Audio codec and speech models

Recording uses native audio capture and a separate, audio-only FFmpeg executable
for AAC/M4A encoding, resampling, playback speed and transcription WAV creation.
Development may set `KODI_FFMPEG_PATH` to an installed FFmpeg executable. Distribution
builds use the pinned, source-verified codec:

```sh
# Linux, with curl, make, a C compiler, xz and GnuPG installed:
bash scripts/build-ffmpeg.sh x86_64-unknown-linux-gnu
node scripts/codec-smoke.mjs src-tauri/binaries/kodi-ffmpeg-x86_64-unknown-linux-gnu
```

On Windows, install MSYS2 UCRT64, GCC, make, curl, tar, xz and GnuPG, then run
`scripts/build-ffmpeg.ps1`. The GitHub workflow performs this setup automatically.
The source checksum and FFmpeg signing-key fingerprint are fixed in the builder.
Each distribution includes the corresponding source archive, license and exact
build flags. GPL, version-3 and nonfree components and network protocols are
disabled.

Speech models and reference voices download on demand with pinned hashes and
sizes from `src-tauri/crates/desktop-services/src/model-catalog.json`. The model
licenses and attribution accompany the catalog/downloads. Narration and
transcription run locally after installation; verify them with networking
disabled as part of native acceptance.

## Packaging and release

`desktop.yml` builds internal Windows NSIS and Linux AppImage/DEB/RPM installers,
runs core/frontend tests and a real Linux X11 WebDriver smoke. These artifacts
are for testing and carry no public release claim.

`desktop-release.yml` is manually dispatched for an existing `desktop-vX.Y.Z`
tag at the selected commit. It requires all native evidence and actual signing
credentials, builds with speech enabled, verifies Windows Authenticode, creates
Tauri updater signatures, and prepares a **draft** GitHub release for review.
Publication remains a separate release action. Configure the protected GitHub
environments `desktop-release` and `desktop-publish` with the required reviewers.

Required environment secrets are `TAURI_SIGNING_PRIVATE_KEY`, its optional
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, `WINDOWS_CERTIFICATE_BASE64`, and
`WINDOWS_CERTIFICATE_PASSWORD`. Public environment variables are
`KODI_UPDATER_PUBLIC_KEY`, `KODI_UPDATER_ENDPOINT`,
`KODI_WINDOWS_TIMESTAMP_URL`, and the configured public account identifiers.
Public releases require the Supabase URL/publishable key and Google installed-app
client ID; an internal offline-only build cannot accidentally become a public
release. `KODI_PAYMENTS_ENABLED` defaults to `NO` and can be set through the
release environment to match the production feature flag.
The updater endpoint must use HTTPS. No placeholder key or unsigned fallback is
accepted. AppImage and NSIS use the app updater; installed DEB/RPM updates must
also be verified through their package installation path.

Run `npm run check:release` to see outstanding release requirements. Follow
[native acceptance](docs/native-acceptance.md) and preserve its evidence with the
candidate commit and installer checksums. See [third-party notices](THIRD_PARTY_NOTICES.md).
