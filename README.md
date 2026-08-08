# Kodi Reader

A lightweight native EPUB reader for macOS. Paginated reading, typography and
theme controls, and highlights with notes — without the store, the sync, or the
library management.

## Requirements

- macOS 14 or later
- Xcode 15.4 or later (the project builds on any Xcode from 15.4 through 26.x)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project file

```sh
brew install xcodegen
```

## Building

```sh
xcodegen generate
open KodiReader.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project KodiReader.xcodeproj -scheme KodiReader -configuration Debug build
```

The `.xcodeproj` is generated from `project.yml` and is not committed, so
regenerate it after pulling changes that touch the project layout.

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

## How it works

```
EpubKit    parsing and persistence, no UI, portable to iOS
ReaderUI   the rendering engine: scheme handler, reader.js, reader.css
App        the SwiftUI macOS app
```

**Why a custom engine.** The obvious choice would be the
[Readium Swift toolkit](https://github.com/readium/swift-toolkit), but it is
UIKit-only and the maintainers have
[no short-term plans for macOS](https://github.com/readium/swift-toolkit/issues/783).
`WKWebView` has the same API on macOS and iOS, so building a thin engine on top
of it keeps the door open for an iOS port. The only third-party dependency is
ZIPFoundation.

**Serving the book.** A `WKURLSchemeHandler` answers `epubreader://` requests
straight from the ZIP. Nothing is extracted to disk, no local HTTP server is
involved, and the whole book shares one origin so relative links between
chapters resolve on their own. Spine documents get the reader stylesheet and
runtime injected into their `<head>` on the way through.

**Pagination.** The body is a CSS multi-column box one viewport tall. Content
overflows sideways into further columns and a page turn scrolls the document by
one viewport width. That stride only holds if the column gap is exactly twice
the horizontal margin, which is the invariant `reader.js` maintains when it
computes the layout — it is what lets one-column and two-column spreads share
the same paging code.

**Anchoring.** Reading positions and highlight endpoints are stored as a chain
of `childNode` indices from `<body>` plus a character offset, which is a
simplified EPUB CFI. Because the book's markup never changes, the anchor stays
valid across font size, margin, theme, and window size changes, none of which a
scroll offset would survive. Pages with no text at all, like a cover, fall back
to anchoring on an element.

**Highlights** are painted as absolutely positioned rects over the text, blended
with `multiply` on light themes and `screen` on dark ones so the glyphs stay
readable. Drawing them on top rather than behind is what lets a click land on a
highlight and open its note.

**Storage** is a single JSON file in Application Support holding reading
positions, annotations, bookmarks, and settings. Opened books are copied into
the app’s sandbox library so Recents can reopen them without asking again.

## Not included

No library shelf, DRM/LCP, sync, OPDS catalogues, audiobooks, or fixed-layout
EPUB. Books are opened with `Cmd-O` or by dropping them on the window, and the
welcome screen lists what you were reading recently.

## Renaming the app

The product name lives in `project.yml`:

```yaml
PRODUCT_NAME: Kodi Reader
```

Change it and re-run `xcodegen generate`. The bundle identifier (`com.olly.Folio`)
is separate so existing sandboxed library data keeps working across renames.
