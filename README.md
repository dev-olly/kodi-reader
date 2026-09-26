<img src="website/assets/kodi-logo.svg" width="80" height="80" alt="Kodi Reader logo">

# Kodi Reader

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight native EPUB and PDF reader for macOS. Paginated reading, typography and
theme controls, highlights with notes and drawings, configurable Ask AI, webpage
reading, and a distraction-free interface — without the store, the sync, or
the library management.

![Kodi Reader showing a highlighted passage and note](docs/screenshots/app-overview.png)

Kodi Reader is **not affiliated with** the [Kodi media center](https://kodi.tv/)
or the XBMC Foundation.

## Features

### Book and document reading
Paginated EPUB rendering with typography, margin, and theme controls, plus native PDF reading with fit-to-page zoom and adaptive two-page spreads. Position and progress survive layout changes and app relaunches.

![Book reading](docs/screenshots/app-reading.png)

### Notes taking
Text highlights in multiple colors, each with an attached note, stored alongside the book.

![Highlight with a note](docs/screenshots/app-note-editor.png)

### Visual notes
Freeform sketches per highlight via a bundled, offline [Excalidraw](https://excalidraw.com/) editor.

![Visual notes with Excalidraw](docs/screenshots/app-draw.png)

### Ask AI
Opt-in OpenAI-powered chat about the book, with per-book chat threads and surrounding-passage context sent for better answers.

![Ask AI](docs/screenshots/app-ask-ai.png)

### Open web apps and websites
Load an article or page, extract the readable content, and read it in the same paginated view as a book.

![Open web app or website](docs/screenshots/app-web.png)

## Status

Source is public under MIT. Issues are welcome for bugs. **Pull requests are
not the goal right now** — this is a source-available personal project, not a
contributor funnel. See [NOTICE.md](NOTICE.md) for third-party licenses and
[SECURITY.md](SECURITY.md) to report vulnerabilities privately.

For implementation details, see [How Kodi Reader works](docs/how-it-works.md).

A macOS disk image is published on [GitHub Releases](https://github.com/dev-olly/kodi-reader/releases/latest). Release builds are signed with Developer ID and notarized by Apple. You can also build from source (Xcode 16.3 or later).

The site is deployed on Vercel at [www.kodi-reader.app](https://www.kodi-reader.app/).
The linked Vercel project's **Root Directory must be `website`**, with the Other
framework preset. Git deployments then use `website/vercel.json` and serve only
the static site. Deploying the repository root puts the homepage under `/website/`
and leaves `/` returning 404. After production deployments, verify the homepage,
its assets, and the download link on both the apex and `www` domains.

## Privacy

- Books, PDFs, highlights, notes, and drawings stay on this Mac (sandbox
  Application Support). EPUBs are read directly from their archives and PDFs
  remain byte-for-byte unchanged; Kodi annotations are stored separately.
- There is no analytics or telemetry.
- **Ask AI** is opt-in. Quoted passages and chat are sent to the hosted Kodi AI
  proxy, which forwards requests to OpenAI. The OpenAI API key lives only on the
  server, never in the Mac app. Kodi AI uses a stronger default model tuned for
  simple explanations with references to the passages you attach.
- Ask AI requires email-code sign-in through Supabase. Supabase stores the account
  email and authentication records; the configured email provider delivers login codes.
  Session tokens stay in macOS Keychain. The AI proxy validates the session and applies
  temporary per-account/IP request limits; it does not log tokens or book passages.
  Sign out or delete the account from the Ask AI account menu. Local books, notes, and
  conversations remain on this Mac after either action.
- Opened webpages are fetched and converted locally. There are no extra
  network calls beyond the page itself.

## Requirements

- macOS 15 or later
- Xcode 16.3 or later (Swift 6.1 is required by the authentication SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project file
- Node.js/npm only when changing the bundled Excalidraw drawing host

```sh
brew install xcodegen
```

## Setup

For hosted Ask AI, follow [the email authentication setup guide](docs/ask-ai-auth-setup.md).
Without Supabase configuration the reader works normally, but AI sign-in is unavailable.

### Install the app

Kodi Reader checks for updates quietly on launch and daily. An **Update available**
button appears in the home header and reading/browser toolbar only when a new version
is available. Click it to download, then **Restart to update** when ready. Choose
**Kodi Reader → Check for Updates…** to check manually. **Settings → Updates** controls automatic checks
and optional automatic downloads/installations. Updating keeps local reading data.
Users on v0.3.0 or earlier need to install v0.3.1 manually once to get the updater.

Download `KodiReader.dmg` from
[GitHub Releases](https://github.com/dev-olly/kodi-reader/releases/latest),
open it, and drag `Kodi Reader.app` into Applications.

Current releases are signed with Developer ID and notarized by Apple. macOS
will still show its normal confirmation the first time an Internet-downloaded
app is opened.

### Build from source

Clone the repository and install XcodeGen:

```sh
git clone https://github.com/dev-olly/kodi-reader.git
cd kodi-reader
brew install xcodegen
```

Debug builds use ad-hoc signing so they run locally without distribution
credentials. Release builds require the project's Developer ID certificate.
On a machine with multiple Xcode versions, point the shell at the Xcode you want:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Generate the Xcode project and open it:

```sh
xcodegen generate
open KodiReader.xcodeproj
```

Or build from the command line. Debug builds on this machine should disable
code signing:

```sh
xcodegen generate
xcodebuild \
  -project KodiReader.xcodeproj \
  -scheme KodiReader \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The `.xcodeproj` is generated from `project.yml` and is not committed, so
regenerate it after pulling changes that touch the project layout.

The bundle identifier is `com.olly.KodiReader`. Product name lives in
`project.yml` as `PRODUCT_NAME: Kodi Reader`.

### Brand assets

The shared logo master is [`website/assets/kodi-logo.svg`](website/assets/kodi-logo.svg).
It uses solid forest green (`#245744`) and a white k with an upward-turning page.
To regenerate the macOS app icon, welcome-screen image, website PNGs, and favicons
after editing the master, run on macOS:

```sh
swift Scripts/generate-brand-assets.swift
```

Generated assets are committed, so normal builds do not need this step.

### Publish in-app updates

The app uses [Sparkle](https://sparkle-project.org/documentation/) with a signed
`appcast.xml` served from this repository's `main` branch. Sparkle 2.10.0 is pinned
in `project.yml`; update archives and the feed both require Ed25519 signatures.
The private signing key stays in the release Mac's login Keychain under account
`com.olly.KodiReader`. Only `SUPublicEDKey` is committed. Preserve this Keychain
key when moving release machines; never commit or publish the private key.

For each release:

1. Increase **both** `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION`
   in `project.yml`, and write `docs/releases/<version>.md`.
2. Run `./Scripts/package-dmg.sh --notarize`.
3. Run `./Scripts/generate-appcast.sh` to generate and sign the feed using Sparkle.
   The tool embeds release notes and checks the signing key and notarization ticket.
4. Publish `KodiReader.dmg` to the matching GitHub release (`v<version>`).
5. Commit and push `appcast.xml` **after** the download is public. Installed apps
   can then discover the update. Do not edit the signed feed by hand.

The DMG script signs Sparkle's nested helpers before signing the outer app.
Debug builds enable Sparkle's sandbox installer service; Release builds are
unsandboxed and use the normal installer. Development-only library-validation
exceptions are kept out of Release entitlements.

## Testing

```sh
./Scripts/fetch-samples.sh   # downloads three Project Gutenberg books
swift test
```

`EpubKitTests` covers container and metadata parsing against real books;
`ReaderUITests` drives a live `WKWebView` through the whole rendering path and
asserts that pagination, page turns, progress, and position restoring all work.
Tests skip rather than fail if the sample books have not been downloaded.

### Looking at pages

```sh
swift test --filter SnapshotTests
open Snapshots/
```

This renders real pages to PNGs in `Snapshots/` using `WKWebView.takeSnapshot`,
covering every theme, a two-column spread, the typography extremes, and
highlights on both light and dark backgrounds. It captures the web view's own
output in-process, so it needs no screen recording permission and shows what
the reader actually draws rather than whatever is on the display.

It is worth doing after any change to `reader.css`. Assertions cannot tell you
that a page is *ugly*, and a theme bug that made dark mode black-on-black
passed every functional test before the snapshots exposed it.

## Rebuilding the Excalidraw host

The drawing editor is a bundled, offline Excalidraw build. npm is only needed
when changing that host:

```sh
cd Tools/excalidraw-host
npm ci
npm run build
```

That writes static assets into `Sources/ReaderUI/Resources/Excalidraw/`. Commit
those generated files so the app builds without Node.

## Not included

No library shelf, DRM/LCP, OCR, password-protected PDF support, sync, OPDS
catalogues, bundled audiobooks, or fixed-layout EPUB. EPUBs and PDFs are opened
with `Cmd-O` or by dropping them on the window; articles and websites can be
opened from a URL. The welcome screen lists what you were reading recently.
