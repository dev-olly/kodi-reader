# How Kodi Reader works

```
EpubKit    EPUB/PDF models, parsing, and persistence, no app UI
ReaderUI   the EPUB web renderer and native PDFKit reading surface
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

**PDFs** use Apple's PDFKit in a native paged view. Kodi stores page-local text
ranges for highlights and rebuilds transient PDF annotations when a document
opens, so neither the original PDF nor the imported library copy is modified.
Scanned pages remain viewable but need embedded text for selection and Ask AI.

**Storage** is a single JSON file in Application Support holding reading
positions, annotations, bookmarks, and settings. Opened books are copied into
the app’s sandbox library so Recents can reopen them without asking again.
Excalidraw scenes live as sidecar files next to that JSON
(`Drawings/<bookID>/<annotationID>.excalidraw.json`) so the library stays small.

