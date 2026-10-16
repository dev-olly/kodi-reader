# Kodi Reader for iOS

A native-feeling mobile variant of [Kodi Reader](https://github.com/dev-olly/kodi-reader),
built with Expo SDK 57, Expo Router, and `@expo/ui` SwiftUI components. iOS 26
Liquid Glass is used for the reader chrome, the tab bar, and native sheets.

## What it does

- Imports EPUB and PDF files from the Files app, or adds two bundled Project
  Gutenberg samples (Alice in Wonderland, Frankenstein).
- Paginated EPUB reading with the same `reader.js` and `reader.css` engine as
  the Mac app, hosted in a `WKWebView`. Swipe or tap the edges to turn pages,
  tap the centre to show or hide the chrome.
- Highlights in five colours plus underline, with notes. Positions and
  highlights use the same simplified-CFI anchors as the Mac app, so they survive
  font and theme changes.
- Typography and theme controls (New York, Georgia, Palatino, Charter, Helvetica,
  San Francisco; size, line spacing, margins, justify, hyphenation).
- Notes tab across all books with Markdown export via the share sheet.
- Open any web page in the in-app browser and save it as a reader-mode book
  (Readability extraction, images inlined, packaged as a one-chapter EPUB).
- PDFs open in the native WebKit PDF viewer (read-only, no highlights yet).

## Layout

```
src/app/                 Expo Router routes
  (tabs)/library|notes|settings   native tab bar with a Stack per tab
  reader/contents.tsx    table of contents (form sheet)
  reader/typography.tsx  appearance controls (form sheet, @expo/ui Form)
  web/index.tsx          in-app browser with "Save as Book"
  note/[bookId]/[annotationId].tsx   note editor (form sheet)
src/reader/              ReaderOverlay (the reader), ReaderWebView bridge, runtime install, settings → CSS
src/reader/runtime/      reader.js + reader.css copied from the Mac app, plus bridge.js
src/lib/epub/            unzip (fflate), OPF/NCX/nav parsing, path helpers
src/lib/web/article.ts   Readability result → EPUB (port of ArticleEPUBBuilder)
src/lib/store.ts         library.json store (positions, annotations, settings)
src/components/          GlassSurface, HighlightPalette, BookRow, AppearanceForm
```

Data lives under the app's Documents directory in `Kodi/`:
`library.json`, `Books/`, `Extracted/`, `Covers/`, `runtime/`.

Book IDs hash the complete publication identifier, or the file contents when an
identifier is absent. Reader web views can access only their book's extraction
directory, including a local copy of the trusted reader runtime. A content
security policy disables publisher scripts, frames and network requests.

## How the reader stays fast

- The reader is a persistent layer above the navigation stack
  (`src/reader/ReaderOverlay.tsx`), not a route. Its web views are created once
  at launch, so WebKit's content process is already running when a book opens.
  Opening a book is a page navigation, and reopening the same book is instant.
- Each chapter file is written with its own boot data (runtime options, reading
  position, highlights) in `<head>`. `bridge.js` lays the page out on
  `DOMContentLoaded` without waiting on round trips through the JS thread.
- A second web view preloads the next chapter behind the visible one. Reading
  past a chapter end, or jumping to it from Contents, swaps it to the front.
- Set `DEBUG_TIMING` in `src/reader/ReaderWebView.tsx` to log load stages.

## Running

```sh
npm install
npx expo run:ios            # needs Xcode 26 and CocoaPods
```

`@expo/ui` and `expo-glass-effect` need a development build; Expo Go is not
enough. On this Mac CocoaPods lives in a user-local Ruby 3.3, so run:

```sh
export PATH="$HOME/.local/ruby-env/bin:$PATH" LANG=en_US.UTF-8
npx expo run:ios --device "iPhone 17 Pro"
```

In development builds, `kodi://library?addSamples=1` imports the bundled
sample books without touching the UI (handy for simulator testing).

Liquid Glass renders on iOS 26 simulators and devices; older systems get a
translucent fallback with the same geometry.

## Not yet ported

Ask AI, cloud sync, Excalidraw drawings, and PDF highlights.

## Checks

Use Node.js 24, then run `npm ci`, `npm test`, `npx tsc --noEmit`,
`npx expo lint --no-cache`, and `npx expo export --platform ios`.
GitHub Actions runs these checks for mobile changes. The regression tests use
asynchronous native-service adapters; they do not replace an iOS simulator test.

On macOS, an optional native WebKit smoke test checks protected XHTML loading,
pagination, fragment navigation, position restore and highlight painting:

```sh
node tests/webkit-fixture.cjs /tmp/kodi-webkit-smoke
swiftc tests/webkit-smoke.swift -o /tmp/kodi-webkit-smoke-test
/tmp/kodi-webkit-smoke-test /tmp/kodi-webkit-smoke
```
