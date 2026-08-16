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
