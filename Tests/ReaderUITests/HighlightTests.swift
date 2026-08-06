import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

/// Verifies that annotations actually paint into the document.
final class HighlightTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?

    override func tearDown() {
        controller?.tearDown()
        controller = nil
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    func testHighlightPaintsRects() throws {
        let (reader, chapter) = try loadTextChapter()

        // Anchor onto real text: take the reported position and widen it into
        // a range, which is what a user selection produces.
        let anchor = try XCTUnwrap(reportedPosition, "No position was reported")
        let annotation = Annotation(
            locator: Locator(
                spineIndex: chapter,
                start: anchor,
                end: TextPosition(elementPath: anchor.elementPath, offset: anchor.offset + 25)
            ),
            text: "highlighted passage",
            color: .yellow
        )

        reader.setAnnotations([annotation])

        let count = try XCTUnwrap(
            waitForNumber(
                reader,
                "document.querySelectorAll('.reader-highlight-rect').length"
            ) { $0 > 0 }
        )
        XCTAssertGreaterThan(count, 0, "The highlight produced no rects")
    }

    func testRemovingAnnotationClearsRects() throws {
        let (reader, chapter) = try loadTextChapter()
        let anchor = try XCTUnwrap(reportedPosition)

        reader.setAnnotations([
            Annotation(
                locator: Locator(
                    spineIndex: chapter,
                    start: anchor,
                    end: TextPosition(elementPath: anchor.elementPath, offset: anchor.offset + 25)
                ),
                text: "highlighted passage",
                color: .green
            )
        ])
        _ = waitForNumber(reader, "document.querySelectorAll('.reader-highlight-rect').length") { $0 > 0 }

        reader.setAnnotations([])
        let after = waitForNumber(
            reader,
            "document.querySelectorAll('.reader-highlight-rect').length"
        ) { $0 == 0 }
        XCTAssertEqual(after, 0, "Rects survived removing the annotation")
    }

    /// Highlights are positioned from layout, so they must be repainted when
    /// the text reflows or they would sit over the wrong words.
    func testHighlightSurvivesTypographyChange() throws {
        let (reader, chapter) = try loadTextChapter()
        let anchor = try XCTUnwrap(reportedPosition)

        reader.setAnnotations([
            Annotation(
                locator: Locator(
                    spineIndex: chapter,
                    start: anchor,
                    end: TextPosition(elementPath: anchor.elementPath, offset: anchor.offset + 25)
                ),
                text: "highlighted passage",
                color: .blue
            )
        ])
        _ = waitForNumber(reader, "document.querySelectorAll('.reader-highlight-rect').length") { $0 > 0 }

        var settings = reader.settings
        settings.fontSize = 26
        reader.settings = settings

        let after = waitForNumber(
            reader,
            "document.querySelectorAll('.reader-highlight-rect').length"
        ) { $0 > 0 }
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(after ?? 0, 0, "Highlight vanished after changing the text size")
    }

    /// The theme's text colour must actually reach the prose.
    ///
    /// A light theme can look correct purely because the book's own default is
    /// black, so this checks a dark theme, where failing to apply the colour
    /// leaves black text on a black page.
    func testDarkThemeAppliesTextColorToParagraphs() throws {
        let (reader, _) = try loadTextChapter()

        var settings = reader.settings
        settings.theme = .dark
        reader.settings = settings
        _ = spin(timeout: 1) { false }

        let script = """
        (function () {
          var p = document.querySelector('p');
          if (!p) return 'no-paragraph';
          return getComputedStyle(p).color;
        })()
        """

        var color: String?
        var settled = false
        reader.evaluateForTesting(script) { value in
            color = value as? String
            settled = true
        }
        XCTAssertTrue(spin(timeout: 5) { settled })

        let computed = try XCTUnwrap(color)
        let channels = computed
            .components(separatedBy: CharacterSet(charactersIn: "rgba(), "))
            .compactMap(Int.init)
        XCTAssertEqual(channels.count >= 3, true, "Unparseable colour: \(computed)")

        // The dark theme's #c9c7c4 is light; anything near black means the
        // theme colour was overridden somewhere.
        let brightness = (channels[0] + channels[1] + channels[2]) / 3
        XCTAssertGreaterThan(
            brightness, 140,
            "Paragraph text rendered at brightness \(brightness) (\(computed)) on the dark theme"
        )
    }

    /// A broken locator should still paint when the quote exists in the chapter.
    func testRepairsBrokenLocatorFromQuote() throws {
        let (reader, chapter) = try loadTextChapter()

        let quote = try XCTUnwrap(firstParagraphSnippet(reader), "No paragraph text to quote")
        var resolutions: [AnchorResolution] = []
        reader.onAnchorsResolved = { resolutions = $0 }

        let broken = Annotation(
            locator: Locator(
                spineIndex: chapter,
                start: TextPosition(elementPath: [999, 999], offset: 0),
                end: TextPosition(elementPath: [999, 999], offset: 5)
            ),
            text: quote,
            color: .yellow
        )
        reader.setAnnotations([broken])

        let count = waitForNumber(
            reader,
            "document.querySelectorAll('.reader-highlight-rect').length"
        ) { $0 > 0 }
        XCTAssertGreaterThan(count ?? 0, 0, "Repaired highlight produced no rects")

        XCTAssertTrue(spin(timeout: 5) { resolutions.contains { $0.status == .repaired } })
        let repaired = try XCTUnwrap(resolutions.first { $0.status == .repaired })
        XCTAssertNotNil(repaired.locator)
        XCTAssertNotEqual(repaired.locator?.start.elementPath, [999, 999])
    }

    func testOrphansMissingQuote() throws {
        let (reader, chapter) = try loadTextChapter()

        var resolutions: [AnchorResolution] = []
        reader.onAnchorsResolved = { resolutions = $0 }

        reader.setAnnotations([
            Annotation(
                locator: Locator(
                    spineIndex: chapter,
                    start: TextPosition(elementPath: [999], offset: 0)
                ),
                text: "this-quote-definitely-does-not-exist-in-frankenstein-xyz",
                color: .pink
            )
        ])

        XCTAssertTrue(spin(timeout: 5) { resolutions.contains { $0.status == .orphaned } })
        let count = waitForNumber(
            reader,
            "document.querySelectorAll('.reader-highlight-rect').length"
        ) { $0 == 0 }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Harness

    private var reportedPosition: TextPosition?

    private func firstParagraphSnippet(_ reader: ReaderController) -> String? {
        var snippet: String?
        var settled = false
        let script = """
        (function () {
          var p = document.querySelector('p');
          if (!p) return null;
          var text = (p.textContent || '').replace(/\\s+/g, ' ').trim();
          return text.slice(0, 40);
        })()
        """
        reader.evaluateForTesting(script) { value in
            snippet = value as? String
            settled = true
        }
        _ = spin(timeout: 5) { settled }
        guard let snippet, snippet.count >= 12 else { return nil }
        return snippet
    }

    private func loadTextChapter() throws -> (ReaderController, Int) {
        let url = SampleBooks.url(SampleBooks.frankenstein)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let book = try EPUBBook(fileURL: url)
        let size = CGSize(width: 800, height: 600)
        let reader = ReaderController()
        controller = reader

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
        reader.updateViewport(width: size.width)

        let order = book.publication.readingOrder
        let chapter = order.indices.max {
            book.container.uncompressedSize(at: order[$0].path)
                < book.container.uncompressedSize(at: order[$1].path)
        } ?? 0

        reader.onPositionChanged = { [weak self] in self?.reportedPosition = $0.start }
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )

        XCTAssertTrue(spin { !reader.isLoading && self.reportedPosition != nil })
        return (reader, chapter)
    }

    private func waitForNumber(
        _ reader: ReaderController,
        _ script: String,
        timeout: TimeInterval = 6,
        until predicate: @escaping (Int) -> Bool
    ) -> Int? {
        var latest: Int?
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var settled = false
            reader.evaluateForTesting(script) { value in
                latest = (value as? NSNumber)?.intValue
                settled = true
            }
            _ = spin(timeout: 2) { settled }
            if let latest, predicate(latest) { return latest }
            _ = spin(timeout: 0.15) { false }
        }
        return latest
    }

    @discardableResult
    private func spin(timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
