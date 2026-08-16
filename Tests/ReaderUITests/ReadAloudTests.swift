import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

final class ReadAloudTests: XCTestCase {
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

    func testExtractUtterancesReturnsSentencesWithLocators() throws {
        let (reader, _) = try loadTextChapter()

        var utterances: [ReaderUtterance]?
        reader.extractUtterances(from: nil) { utterances = $0 }
        XCTAssertTrue(spin { utterances != nil })

        let list = try XCTUnwrap(utterances)
        XCTAssertGreaterThan(list.count, 3, "Expected several sentences from a real chapter")
        XCTAssertTrue(list.contains { $0.text.split(separator: " ").count >= 4 })
        for utterance in list.prefix(8) {
            XCTAssertFalse(utterance.text.isEmpty)
            XCTAssertFalse(utterance.start.elementPath.isEmpty)
            XCTAssertFalse(utterance.end.elementPath.isEmpty)
        }
    }

    func testShortUtterancesAreMergedIntoNeighbors() throws {
        let (reader, _) = try loadTextChapter()

        var utterances: [ReaderUtterance]?
        reader.extractUtterances(from: nil) { utterances = $0 }
        XCTAssertTrue(spin { utterances != nil })

        let list = try XCTUnwrap(utterances)
        let unmerged = list.dropLast().filter { $0.text.count < 60 }
        XCTAssertTrue(
            unmerged.isEmpty,
            "Short fragments should merge into the next utterance: \(unmerged.map(\.text))"
        )
    }

    func testReadingRangeDoesNotShiftLocatorsOrPageCount() throws {
        let (reader, _) = try loadTextChapter()
        let pageCount = reader.pageCount

        var before: [String: Any]?
        reader.evaluateForTesting("__reader.state()") { before = $0 as? [String: Any] }
        XCTAssertTrue(spin { before != nil })

        var utterances: [ReaderUtterance]?
        reader.extractUtterances(from: nil) { utterances = $0 }
        XCTAssertTrue(spin { utterances != nil })
        let first = try XCTUnwrap(utterances?.first)

        reader.setReadingRange(
            Locator(spineIndex: reader.spineIndex, start: first.start, end: first.end)
        )

        let rectCount = waitForNumber(
            reader,
            "document.querySelectorAll('.reader-reading-rect').length"
        ) { $0 > 0 }
        XCTAssertGreaterThan(rectCount ?? 0, 0, "Reading range produced no overlay rects")
        XCTAssertEqual(reader.pageCount, pageCount)

        var after: [String: Any]?
        reader.evaluateForTesting("__reader.state()") { after = $0 as? [String: Any] }
        XCTAssertTrue(spin { after != nil })

        let beforePath = intPath(before?["position"])
        let afterPath = intPath(after?["position"])
        XCTAssertEqual(afterPath, beforePath, "Reading overlay shifted locator paths")

        reader.setReadingRange(nil)
        let cleared = waitForNumber(
            reader,
            "document.querySelectorAll('.reader-reading-rect').length"
        ) { $0 == 0 }
        XCTAssertEqual(cleared, 0)
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

    private func intPath(_ position: Any?) -> [Int]? {
        guard let body = position as? [String: Any] else { return nil }
        if let path = body["elementPath"] as? [Int] { return path }
        if let numbers = body["elementPath"] as? [NSNumber] { return numbers.map(\.intValue) }
        return nil
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
