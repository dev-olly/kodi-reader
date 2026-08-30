import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

final class SurroundingPassageTests: XCTestCase {
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

    func testExtractSurroundingPassageIncludesNeighboringBlocks() throws {
        let (reader, _) = try loadTextChapter()

        var utterances: [ReaderUtterance]?
        reader.extractUtterances(from: nil) { utterances = $0 }
        XCTAssertTrue(spin { utterances != nil })

        let list = try XCTUnwrap(utterances)
        XCTAssertGreaterThan(list.count, 6, "Need a mid-chapter sentence with neighbors")
        let mid = list[list.count / 2]
        let locator = Locator(
            spineIndex: reader.spineIndex,
            start: mid.start,
            end: mid.end,
            text: mid.text
        )

        var passage: ReaderSurroundingPassage?
        reader.extractSurroundingPassage(from: locator) { passage = $0 }
        XCTAssertTrue(spin { passage != nil })

        let result = try XCTUnwrap(passage)
        XCTAssertFalse(result.quote.isEmpty, "Quote should be recovered from the locator")
        XCTAssertTrue(
            result.quote.contains(mid.text) || mid.text.contains(result.quote),
            "Quote should match the selected utterance"
        )
        XCTAssertFalse(result.before.isEmpty, "Expected paragraphs before a mid-chapter quote")
        XCTAssertFalse(result.after.isEmpty, "Expected paragraphs after a mid-chapter quote")
        XCTAssertFalse(result.before.contains(result.quote))
        XCTAssertFalse(result.after.contains(result.quote))
    }

    // MARK: - Harness

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

        var ready = false
        reader.onPositionChanged = { _ in ready = true }
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(spin { !reader.isLoading && ready })
        return (reader, chapter)
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
