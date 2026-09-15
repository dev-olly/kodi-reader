import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

/// Exercises the real rendering path: a `WKWebView` backed by the scheme
/// handler, loading a real book, running reader.js, and paginating.
///
/// The web view is placed in an off-screen window because WebKit skips layout
/// for views with no window, and without layout there are no columns to count.
final class RenderingTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?

    override func tearDown() {
        controller?.tearDown()
        controller = nil
        // Detaching before dropping the window avoids tearing WebKit state out
        // from under a view that is still live.
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func makeReader(
        _ sampleName: String,
        size: CGSize = CGSize(width: 900, height: 700)
    ) throws -> (ReaderController, EPUBBook) {
        let url = SampleBooks.url(sampleName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing \(sampleName). Run Scripts/fetch-samples.sh.")
        }

        let book = try EPUBBook(fileURL: url)
        let controller = ReaderController()
        let webView = controller.makeWebView(for: book)
        webView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)

        self.window = window
        self.controller = controller
        controller.updateViewport(width: size.width)
        return (controller, book)
    }

    /// Spins the run loop until `condition` holds or the timeout elapses.
    @discardableResult
    private func wait(
        timeout: TimeInterval = 15,
        for condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - Tests

    func testLoadsFirstChapterAndPaginates() throws {
        let (reader, _) = try makeReader(SampleBooks.frankenstein)
        reader.start(at: nil, annotations: [])

        XCTAssertTrue(
            wait { !reader.isLoading },
            "Reader never finished loading the first chapter"
        )
        XCTAssertGreaterThanOrEqual(reader.pageCount, 1)
        XCTAssertEqual(reader.spineIndex, 0)
    }

    func testHTTPSLinkFiresOnExternalLink() throws {
        let (reader, _) = try makeReader(SampleBooks.alice)
        reader.start(at: nil, annotations: [])
        XCTAssertTrue(wait { !reader.isLoading }, "Reader never finished loading")

        var opened: URL?
        reader.onExternalLink = { opened = $0 }

        reader.evaluateForTesting(
            "window.webkit.messageHandlers.reader.postMessage({type: 'link', href: 'https://example.com/article'})"
        ) { _ in }

        XCTAssertTrue(wait { opened != nil }, "onExternalLink never fired for an https link")
        XCTAssertEqual(opened?.absoluteString, "https://example.com/article")
    }

    /// A long chapter in a small window must produce several pages, which is
    /// the real proof that the multi-column layout is doing its job.
    func testLongChapterProducesMultiplePages() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 700, height: 500)
        )

        // Pick the largest spine document so there is plenty to paginate.
        let order = book.publication.readingOrder
        let largest = order.indices.max {
            book.container.uncompressedSize(at: order[$0].path)
                < book.container.uncompressedSize(at: order[$1].path)
        } ?? 0

        reader.start(
            at: Locator(spineIndex: largest, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })

        XCTAssertGreaterThan(
            reader.pageCount, 1,
            "A large chapter in a 700x500 viewport should span multiple pages"
        )
    }

    func testTurningPagesAdvancesPosition() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 700, height: 500)
        )

        let order = book.publication.readingOrder
        let largest = order.indices.max {
            book.container.uncompressedSize(at: order[$0].path)
                < book.container.uncompressedSize(at: order[$1].path)
        } ?? 0

        reader.start(
            at: Locator(spineIndex: largest, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 1, "Chapter fits on one page")

        let startPage = reader.page
        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) { reader.page > startPage },
            "nextPage did not advance (page stayed at \(reader.page))"
        )

        let advanced = reader.page
        reader.previousPage()
        XCTAssertTrue(
            wait(timeout: 5) { reader.page < advanced },
            "previousPage did not go back"
        )
    }

    /// A two-column page turn is atomic: duplicate input received while the
    /// smooth turn is settling must not queue a second viewport. Otherwise a
    /// single gesture delivered by two input paths silently drops a full
    /// spread of text (for example the footer jumps from 4 directly to 6).
    func testOverlappingTwoPageTurnsAdvanceExactlyOneSpread() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 1400, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Chapter is too short to test spread turns")

        reader.evaluateForTesting("__reader.goToPage(3, false)") { _ in }
        XCTAssertTrue(wait(timeout: 5) { reader.page == 3 })

        reader.nextPage()
        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) { reader.page != 3 },
            "The spread did not advance"
        )
        XCTAssertEqual(reader.page, 4, "A single turn skipped a complete spread of text")

        // Reset instantly so no animation remains pending, then exercise the
        // symmetric backward path with the same duplicate delivery.
        reader.evaluateForTesting("__reader.goToPage(4, false)") { _ in }
        XCTAssertTrue(wait(timeout: 2) { reader.page == 4 })
        reader.previousPage()
        reader.previousPage()
        XCTAssertTrue(wait(timeout: 5) { reader.page != 4 })
        XCTAssertEqual(reader.page, 3, "A single backward turn skipped a complete spread")
    }

    /// Edge-tap paging must use the page gutter, not the text column. A click
    /// on a paragraph near the left edge used to fall inside the old 15% zone
    /// and turn the page; it must now stay put. A click on the empty margin
    /// still pages.
    func testContentClickDoesNotTurnPage() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 700, height: 500)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 1, "Chapter fits on one page")

        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) { reader.page > 0 },
            "Could not advance off page 0 before testing clicks"
        )

        let pageAfterAdvance = reader.page

        var contentClickTarget: String?
        reader.evaluateForTesting(
            """
            (function () {
              var nodes = document.body.querySelectorAll("p, h1, h2, h3, h4");
              for (var i = 0; i < nodes.length; i++) {
                var node = nodes[i];
                var rect = node.getBoundingClientRect();
                if (rect.width < 8 || rect.height < 8) continue;
                if (rect.top < 0 || rect.top > window.innerHeight) continue;
                var x = rect.left + 8;
                var y = rect.top + Math.min(12, rect.height / 2);
                var hit = document.elementFromPoint(x, y) || node;
                hit.dispatchEvent(new MouseEvent("click", {
                  bubbles: true,
                  cancelable: true,
                  view: window,
                  clientX: x,
                  clientY: y
                }));
                return hit.tagName;
              }
              return null;
            })()
            """
        ) { contentClickTarget = $0 as? String }

        XCTAssertTrue(
            wait { contentClickTarget != nil },
            "Content click script did not run"
        )
        let hitTag = try XCTUnwrap(contentClickTarget, "No visible paragraph to click")
        XCTAssertFalse(
            ["BODY", "HTML"].contains(hitTag),
            "Expected to click a text element, not the page chrome"
        )
        _ = wait(timeout: 0.4) { reader.page != pageAfterAdvance }
        XCTAssertEqual(
            reader.page, pageAfterAdvance,
            "Clicking the text column turned the page"
        )

        var marginClickDone = false
        reader.evaluateForTesting(
            """
            document.body.dispatchEvent(new MouseEvent("click", {
              bubbles: true,
              cancelable: true,
              view: window,
              clientX: 8,
              clientY: Math.floor(window.innerHeight / 2)
            }));
            """
        ) { _ in marginClickDone = true }

        XCTAssertTrue(wait { marginClickDone }, "Margin click script did not run")
        XCTAssertTrue(
            wait(timeout: 5) { reader.page < pageAfterAdvance },
            "Clicking the empty left margin did not go back (page stayed at \(reader.page))"
        )
    }

    func testReportsProgressThroughTheBook() throws {
        let (reader, book) = try makeReader(SampleBooks.frankenstein)

        let lastIndex = book.publication.readingOrder.count - 1
        reader.start(
            at: Locator(spineIndex: lastIndex, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        XCTAssertTrue(wait(timeout: 5) { reader.progress > 0.5 },
                      "Progress at the last chapter was \(reader.progress)")
    }

    /// Position callbacks are what the app persists, so they must arrive with
    /// a usable anchor rather than an empty path.
    func testEmitsPositionWithAnchor() throws {
        let (reader, book) = try makeReader(SampleBooks.frankenstein)

        var received: Locator?
        reader.onPositionChanged = { received = $0 }

        // Spine 0 of a Gutenberg book is the cover, which has no text at all,
        // so anchor onto a chapter that actually contains prose.
        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )

        XCTAssertTrue(wait { !reader.isLoading })
        XCTAssertTrue(wait(timeout: 5) { received != nil }, "No position was reported")
        XCTAssertFalse(
            received?.start.elementPath.isEmpty ?? true,
            "Reported position had no element path, so it could not be restored"
        )
    }

    /// A cover is a single full-page image with no text, and it must still
    /// produce an anchor so that reopening the book lands back on it.
    func testImageOnlyPageStillAnchors() throws {
        let (reader, _) = try makeReader(SampleBooks.frankenstein)

        var received: Locator?
        reader.onPositionChanged = { received = $0 }
        reader.start(at: nil, annotations: [])

        XCTAssertTrue(wait { !reader.isLoading })
        XCTAssertTrue(wait(timeout: 5) { received != nil })
        XCTAssertFalse(
            received?.start.elementPath.isEmpty ?? true,
            "The cover page produced no anchor at all"
        )
    }

    /// Reopening at a saved position must land on the same page.
    func testRestoresSavedPosition() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 700, height: 500)
        )

        let chapter = largestChapterIndex(in: book)
        var latest: Locator?
        reader.onPositionChanged = { latest = $0 }

        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Chapter is too short to test restoring")

        // Read a few pages in, then capture where we ended up.
        reader.nextPage()
        XCTAssertTrue(wait(timeout: 5) { reader.page == 1 })
        reader.nextPage()
        XCTAssertTrue(wait(timeout: 5) { reader.page == 2 })

        let saved = try XCTUnwrap(latest)
        XCTAssertEqual(saved.spineIndex, chapter)

        // Reload the chapter from scratch and restore.
        reader.start(at: saved, annotations: [])
        XCTAssertTrue(wait { !reader.isLoading })
        XCTAssertTrue(
            wait(timeout: 5) { reader.page == 2 },
            "Restored to page \(reader.page) instead of 2"
        )
    }

    /// SwiftUI runs `task` before the representable builds the web view, so
    /// the app calls `start` first. That order must still load the book.
    func testStartBeforeWebViewExistsStillLoads() throws {
        let url = SampleBooks.url(SampleBooks.frankenstein)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let book = try EPUBBook(fileURL: url)
        let size = CGSize(width: 900, height: 700)
        let reader = ReaderController()
        controller = reader

        var received: Locator?
        reader.onPositionChanged = { received = $0 }

        // Deliberately before makeWebView.
        reader.start(at: nil, annotations: [])

        let webView = reader.makeWebView(for: book)
        webView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window

        XCTAssertTrue(
            wait { !reader.isLoading && received != nil },
            "Book never loaded when start() preceded makeWebView()"
        )
    }

    private func largestChapterIndex(in book: EPUBBook) -> Int {
        let order = book.publication.readingOrder
        return order.indices.max {
            book.container.uncompressedSize(at: order[$0].path)
                < book.container.uncompressedSize(at: order[$1].path)
        } ?? 0
    }

    func testNCXOnlyBookAlsoRenders() throws {
        let (reader, _) = try makeReader(SampleBooks.prideAndPrejudice)
        reader.start(at: nil, annotations: [])
        XCTAssertTrue(wait { !reader.isLoading })
        XCTAssertGreaterThanOrEqual(reader.pageCount, 1)
    }

    func testChangingTypographyRepaginates() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 700, height: 500)
        )

        let order = book.publication.readingOrder
        let largest = order.indices.max {
            book.container.uncompressedSize(at: order[$0].path)
                < book.container.uncompressedSize(at: order[$1].path)
        } ?? 0

        reader.start(
            at: Locator(spineIndex: largest, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })

        let before = reader.pageCount
        try XCTSkipUnless(before > 1, "Chapter fits on one page")

        var settings = reader.settings
        settings.fontSize = 30
        reader.settings = settings

        XCTAssertTrue(
            wait(timeout: 6) { reader.pageCount != before },
            "Page count stayed at \(before) after growing the text to 30pt"
        )
        XCTAssertGreaterThan(
            reader.pageCount, before,
            "Larger text should need more pages"
        )
    }

    /// Shrinking below the two-column threshold must recompute pageCount so
    /// Next advances within the chapter instead of stalling or skipping ahead.
    func testResizingToOneColumnRepaginatesAndTurnsPages() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 1400, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })

        let twoColumnCount = reader.pageCount
        try XCTSkipUnless(twoColumnCount > 1, "Chapter fits on one spread")

        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) { reader.page > 0 },
            "Could not advance off page 0 before resizing"
        )
        let spineBefore = reader.spineIndex

        let oneColumnSize = CGSize(width: 800, height: 900)
        window?.setContentSize(oneColumnSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: oneColumnSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: oneColumnSize.width, height: oneColumnSize.height)

        XCTAssertTrue(
            wait(timeout: 6) { reader.pageCount > twoColumnCount },
            "Page count stayed at \(reader.pageCount) after shrinking to one column (was \(twoColumnCount))"
        )
        XCTAssertEqual(reader.spineIndex, spineBefore, "Resize jumped to another chapter")

        let pageAfterResize = reader.page
        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) { reader.page > pageAfterResize && reader.spineIndex == spineBefore },
            "nextPage did not advance within the chapter after resize (page \(reader.page), spine \(reader.spineIndex))"
        )
    }

    /// After a resize the footer page index, JS state, and DOM scroll offset
    /// must describe the same page. A stale `currentPage` with `scrollLeft`
    /// still at 0 is what made Next/Previous appear broken (counter moved,
    /// visible text did not).
    func testResizeKeepsPageIndexAlignedWithScroll() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 1400, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need at least three pages to stand on page 2")

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(
            wait(timeout: 4) { reader.pageCount > 2 },
            "Typography relayout after disabling animation lost pagination"
        )

        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in }
        XCTAssertTrue(
            wait(timeout: 5) { reader.page == 1 },
            "Could not stand on page 2 (index 1) before resizing"
        )

        let before = pagingGeometry(from: reader)
        let beforeWidth = before["innerWidth"] ?? 1
        XCTAssertEqual(
            before["scrollLeft"] ?? -1, beforeWidth, accuracy: 2,
            "Page 2 was not actually visible before resizing: \(before)"
        )

        let oneColumnSize = CGSize(width: 800, height: 900)
        window?.setContentSize(oneColumnSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: oneColumnSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: oneColumnSize.width, height: oneColumnSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                let geo = pagingGeometry(from: reader)
                return pageIndexAgreesWithScroll(geo, swiftPage: reader.page)
                    && reader.spineIndex == chapter
                    && (geo["pageCount"] ?? 0) > 1
            },
            "After resize, reported page \(reader.page) of \(reader.pageCount) disagrees with scroll: \(pagingGeometry(from: reader))"
        )

        let aligned = pagingGeometry(from: reader)
        let scrollBeforeTurn = aligned["scrollLeft"] ?? 0
        let pageBeforeTurn = reader.page
        let spineBefore = reader.spineIndex

        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) {
                let geo = pagingGeometry(from: reader)
                return reader.spineIndex == spineBefore
                    && reader.page > pageBeforeTurn
                    && (geo["scrollLeft"] ?? scrollBeforeTurn) > scrollBeforeTurn + 10
                    && pageIndexAgreesWithScroll(geo, swiftPage: reader.page)
            },
            "nextPage after resize did not move the visible page (page \(reader.page), spine \(reader.spineIndex), geo \(pagingGeometry(from: reader)))"
        )
    }

    /// Sidebar open/close shrinks the web view. Pinning the current position
    /// before that width change must restore the same text, not chapter start.
    func testPinRestoreOnceKeepsPositionAcrossViewportShrink() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 1400, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need at least three pages to stand past the start")

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(
            wait(timeout: 4) { reader.pageCount > 2 },
            "Typography relayout after disabling animation lost pagination"
        )

        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in }
        XCTAssertTrue(
            wait(timeout: 5) { reader.page == 1 },
            "Could not stand on page 2 (index 1) before shrinking"
        )

        XCTAssertFalse(
            currentTextPosition(from: reader).elementPath.isEmpty,
            "No text anchor before shrink"
        )

        var pinned = false
        reader.evaluateForTesting("__reader.pinRestoreCurrentOnce()") { _ in pinned = true }
        XCTAssertTrue(wait(timeout: 2) { pinned }, "pinRestoreCurrentOnce did not run")

        let sidebarSize = CGSize(width: 800, height: 900)
        window?.setContentSize(sidebarSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: sidebarSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: sidebarSize.width, height: sidebarSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                reader.spineIndex == chapter
                    && reader.page > 0
                    && (pagingGeometry(from: reader)["scrollLeft"] ?? 0) > 10
            },
            "Pinned resize jumped to chapter start (page \(reader.page), geo \(pagingGeometry(from: reader)))"
        )
    }

    /// Closing Ask AI (or any leading sidebar) *widens* the web view. The pin
    /// must be taken before that expand, or relayout restores chapter start.
    func testPinRestoreOnceKeepsPositionAcrossViewportExpand() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 800, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need at least three pages to stand past the start")

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(
            wait(timeout: 4) { reader.pageCount > 2 },
            "Typography relayout after disabling animation lost pagination"
        )

        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in }
        XCTAssertTrue(
            wait(timeout: 5) { reader.page == 1 },
            "Could not stand on page 2 (index 1) before expanding"
        )

        let position = currentTextPosition(from: reader)
        XCTAssertFalse(position.elementPath.isEmpty, "No text anchor before expand")

        var pinned = false
        reader.evaluateForTesting("__reader.pinRestoreCurrentOnce()") { _ in pinned = true }
        XCTAssertTrue(wait(timeout: 2) { pinned }, "pinRestoreCurrentOnce did not run")

        let fullSize = CGSize(width: 1400, height: 900)
        window?.setContentSize(fullSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: fullSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: fullSize.width, height: fullSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                reader.spineIndex == chapter
                    && reader.page > 0
                    && (pagingGeometry(from: reader)["scrollLeft"] ?? 0) > 10
                    && isTextPositionInLeadingColumn(position, in: reader)
            },
            "Pinned expand did not keep the reading column leading (page \(reader.page), geo \(pagingGeometry(from: reader)))"
        )
    }

    /// Opening and then closing a sidebar is one resize session. The second
    /// resize must use the passage captured before opening; otherwise reflowed
    /// text from the narrow layout becomes the new anchor and the spread drifts
    /// backward by one physical column when the sidebar closes.
    func testWorkspaceRestoreKeepsOriginalLeadingColumnAcrossRoundTrip() throws {
        let fullSize = CGSize(width: 1400, height: 900)
        let sidebarSize = CGSize(width: 800, height: 900)
        let (reader, book) = try makeReader(SampleBooks.frankenstein, size: fullSize)

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need at least three pages to stand past the start")

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(wait(timeout: 4) { reader.pageCount > 2 })

        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in }
        XCTAssertTrue(wait(timeout: 5) { reader.page == 1 })
        let original = currentTextPosition(from: reader)
        XCTAssertFalse(original.elementPath.isEmpty, "No leading text before opening workspace")
        XCTAssertTrue(
            isTextPositionVisible(original, in: reader)
                && isTextPositionInLeadingColumn(original, in: reader),
            "Current position did not resolve inside the visible leading column"
        )

        reader.beginWorkspaceRestore()
        window?.setContentSize(sidebarSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: sidebarSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: sidebarSize.width, height: sidebarSize.height)
        XCTAssertTrue(
            wait(timeout: 6) { reader.spineIndex == chapter && isTextPositionVisible(original, in: reader) },
            "Workspace opening lost the original passage"
        )

        reader.endWorkspaceRestore()
        window?.setContentSize(fullSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: fullSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: fullSize.width, height: fullSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                reader.spineIndex == chapter
                    && isTextPositionInLeadingColumn(original, in: reader)
            },
            "Workspace round trip moved the original passage out of the leading column (page \(reader.page), geo \(pagingGeometry(from: reader)))"
        )
    }

    /// SwiftUI can widen the WKWebView before an asynchronously enqueued pin
    /// executes. Model that ordering by resetting the DOM scroll first: the
    /// reader must use its last settled text anchor, not the new page-zero probe.
    func testLatePinAfterScrollResetKeepsPositionAcrossResize() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 800, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need at least three pages to stand past the start")

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(wait(timeout: 4) { reader.pageCount > 2 })

        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in }
        XCTAssertTrue(wait(timeout: 5) { reader.page == 1 })

        var positionUpdates = 0
        reader.onPositionChanged = { _ in positionUpdates += 1 }
        var simulated = false
        reader.evaluateForTesting(
            "document.scrollingElement.scrollLeft = 0; "
                + "__reader.pinRestoreCurrentOnce(); "
                + "window.dispatchEvent(new Event('resize'))"
        ) { _ in simulated = true }
        XCTAssertTrue(wait(timeout: 2) { simulated })

        XCTAssertTrue(
            wait(timeout: 6) { positionUpdates > 0 && reader.page > 0 },
            "Late resize pin restored chapter start (page \(reader.page), geo \(pagingGeometry(from: reader)))"
        )
    }

    /// Selection-driven actions (Add Note / Ask AI) need to restore the acted-on
    /// passage, not just the page's first text probe, when a sidebar narrows the
    /// reader.
    func testSpecificPinRestoreKeepsPinnedTextVisibleAcrossViewportShrink() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 1400, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need at least three pages to stand past the start")

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(wait(timeout: 4) { reader.pageCount > 2 })

        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in }
        XCTAssertTrue(wait(timeout: 5) { reader.page == 1 })

        let pinned = try XCTUnwrap(
            visibleTextPosition(from: reader),
            "No visible text position to pin before shrink"
        )
        reader.pinRestoreOnce(to: pinned)
        var genericPinRan = false
        reader.evaluateForTesting("__reader.pinRestoreCurrentOnce()") { _ in genericPinRan = true }
        XCTAssertTrue(wait(timeout: 2) { genericPinRan })

        let sidebarSize = CGSize(width: 800, height: 900)
        window?.setContentSize(sidebarSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: sidebarSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: sidebarSize.width, height: sidebarSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                reader.spineIndex == chapter && isTextPositionVisible(pinned, in: reader)
            },
            "Specific pinned text was not visible after shrink (page \(reader.page), geo \(pagingGeometry(from: reader)))"
        )
    }

    /// The visible scroll position must actually move on a page turn after a
    /// resize — not just the reported page index. Before the fix, `scrollToPage`
    /// used a cached stride captured at the old size, so targets overshot and
    /// clamped to the same spot while the counter kept climbing ("the counter
    /// changes but the page doesn't"). Turns here are instant so the assertion
    /// does not depend on the compositor animating an off-screen window.
    func testScrollPositionActuallyMovesAfterResize() throws {
        let (reader, book) = try makeReader(
            SampleBooks.frankenstein,
            size: CGSize(width: 1400, height: 900)
        )

        let chapter = largestChapterIndex(in: book)
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 1, "Chapter fits on one spread")

        let oneColumnSize = CGSize(width: 800, height: 900)
        window?.setContentSize(oneColumnSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: oneColumnSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: oneColumnSize.width, height: oneColumnSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                let geo = pagingGeometry(from: reader)
                return pageIndexAgreesWithScroll(geo, swiftPage: reader.page)
                    && (geo["innerWidth"] ?? 0) > 0
            },
            "Resize did not settle on an aligned page/scroll pair: \(pagingGeometry(from: reader))"
        )

        let start = pagingGeometry(from: reader)
        let innerWidth = start["innerWidth"] ?? 1
        let maxScroll = start["maxScroll"] ?? 0
        try XCTSkipUnless(maxScroll > innerWidth, "Chapter shorter than two pages at this size")

        // The stride must track the new viewport, not the pre-resize width.
        XCTAssertEqual(innerWidth, oneColumnSize.width, accuracy: 1,
                       "innerWidth did not follow the resize")

        // Instant-turn through the first few pages; each must land exactly on a
        // viewport-width boundary and match the reported page.
        let pagesToWalk = min(3, Int((maxScroll / innerWidth).rounded(.down)))
        try XCTSkipUnless(pagesToWalk >= 1, "Not enough pages to walk")

        for target in 1...pagesToWalk {
            reader.evaluateForTesting("__reader.goToPage(\(target), false)") { _ in }
            XCTAssertTrue(
                wait(timeout: 2) {
                    let now = pagingGeometry(from: reader)
                    return abs((now["scrollLeft"] ?? -1) - Double(target) * innerWidth) <= 2
                        && reader.page == target
                },
                "Page \(target) did not land at the expected offset: \(pagingGeometry(from: reader))"
            )
        }
    }

    private func currentTextPosition(from reader: ReaderController) -> TextPosition {
        var result: TextPosition?
        reader.evaluateForTesting("window.__reader.state().position") { raw in
            guard let body = raw as? [String: Any],
                  let path = body["elementPath"] as? [Int]
            else { return }
            result = TextPosition(elementPath: path, offset: body["offset"] as? Int ?? 0)
        }
        _ = wait(timeout: 2) { result != nil }
        return result ?? TextPosition(elementPath: [], offset: 0)
    }

    private func visibleTextPosition(from reader: ReaderController) -> TextPosition? {
        var result: TextPosition?
        reader.evaluateForTesting(
            """
            (function () {
              function pathOfNode(node) {
                var path = [];
                var current = node;
                while (current && current !== document.body) {
                  var parent = current.parentNode;
                  if (!parent) break;
                  path.unshift(Array.prototype.indexOf.call(parent.childNodes, current));
                  current = parent;
                }
                return path;
              }
              var xs = [window.innerWidth * 0.75, window.innerWidth * 0.25, window.innerWidth * 0.5];
              var ys = [window.innerHeight * 0.72, window.innerHeight * 0.58, window.innerHeight * 0.42];
              for (var yi = 0; yi < ys.length; yi++) {
                for (var xi = 0; xi < xs.length; xi++) {
                  var range = document.caretRangeFromPoint(xs[xi], ys[yi]);
                  if (!range || !range.startContainer) continue;
                  if (range.startContainer === document.body) continue;
                  if (range.startContainer.nodeType !== Node.TEXT_NODE) continue;
                  return {
                    elementPath: pathOfNode(range.startContainer),
                    offset: range.startOffset
                  };
                }
              }
              return null;
            })()
            """
        ) { raw in
            guard let body = raw as? [String: Any],
                  let path = body["elementPath"] as? [Int]
            else { return }
            result = TextPosition(elementPath: path, offset: body["offset"] as? Int ?? 0)
        }
        _ = wait(timeout: 2) { result != nil }
        return result
    }

    private func isTextPositionVisible(_ position: TextPosition, in reader: ReaderController) -> Bool {
        guard let encoded = jsonString([
            "elementPath": position.elementPath,
            "offset": position.offset,
        ]) else { return false }

        var result: Bool?
        reader.evaluateForTesting(
            """
            (function (position) {
              function nodeAtPath(path) {
                var node = document.body;
                for (var i = 0; i < path.length; i++) {
                  node = node.childNodes[path[i]];
                  if (!node) return null;
                }
                return node;
              }
              var node = nodeAtPath(position.elementPath || []);
              if (!node || node.nodeType !== Node.TEXT_NODE) return false;
              var range = document.createRange();
              var offset = Math.min(Math.max(position.offset || 0, 0), node.textContent.length);
              range.setStart(node, offset);
              range.setEnd(node, Math.min(offset + 1, node.textContent.length));
              var rect = range.getBoundingClientRect();
              return rect.width > 0 &&
                rect.height > 0 &&
                rect.right >= 0 &&
                rect.left <= window.innerWidth &&
                rect.bottom >= 0 &&
                rect.top <= window.innerHeight;
            })(\(encoded))
            """
        ) { result = $0 as? Bool }
        _ = wait(timeout: 2) { result != nil }
        return result == true
    }

    private func isTextPositionInLeadingColumn(
        _ position: TextPosition,
        in reader: ReaderController
    ) -> Bool {
        guard let encoded = jsonString([
            "elementPath": position.elementPath,
            "offset": position.offset,
        ]) else { return false }

        var result: Bool?
        reader.evaluateForTesting(
            """
            (function (position) {
              var node = document.body;
              for (var i = 0; i < position.elementPath.length; i++) {
                node = node.childNodes[position.elementPath[i]];
                if (!node) return false;
              }
              if (node.nodeType !== Node.TEXT_NODE) return false;
              var range = document.createRange();
              var offset = Math.min(Math.max(position.offset || 0, 0), node.textContent.length);
              range.setStart(node, offset);
              range.setEnd(node, Math.min(offset + 1, node.textContent.length));
              var rect = range.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0 &&
                rect.left >= 0 && rect.left < window.innerWidth / 2;
            })(\(encoded))
            """
        ) { result = $0 as? Bool }
        _ = wait(timeout: 2) { result != nil }
        return result == true
    }

    private func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private func pagingGeometry(from reader: ReaderController) -> [String: Double] {
        var result: [String: Double]?
        reader.evaluateForTesting(
            """
            (function () {
              var el = document.documentElement;
              var state = window.__reader.state();
              return {
                scrollLeft: el.scrollLeft,
                innerWidth: window.innerWidth,
                maxScroll: el.scrollWidth - el.clientWidth,
                pageCount: state.pageCount,
                page: state.page
              };
            })()
            """
        ) { result = ($0 as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } }
        _ = wait(timeout: 2) { result != nil }
        return result ?? [:]
    }

    private func pageIndexAgreesWithScroll(_ geo: [String: Double], swiftPage: Int) -> Bool {
        let innerWidth = geo["innerWidth"] ?? 0
        let scrollLeft = geo["scrollLeft"] ?? -1
        let jsPage = geo["page"] ?? -1
        guard innerWidth > 0 else { return false }
        return abs(scrollLeft - Double(swiftPage) * innerWidth) <= 2
            && abs(jsPage - Double(swiftPage)) < 0.5
    }
}

enum SampleBooks {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Samples")
    }

    static let frankenstein = "frankenstein.epub"
    static let alice = "alice.epub"
    static let prideAndPrejudice = "pride-and-prejudice.epub"

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
