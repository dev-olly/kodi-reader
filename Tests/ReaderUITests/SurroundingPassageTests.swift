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

        let locator = try middleParagraphLocator(in: reader)

        var passage: ReaderSurroundingPassage?
        reader.extractSurroundingPassage(from: locator) { passage = $0 }
        XCTAssertTrue(spin { passage != nil })

        let result = try XCTUnwrap(passage)
        XCTAssertFalse(result.quote.isEmpty, "Quote should be recovered from the locator")
        XCTAssertTrue(
            result.quote.contains(locator.text ?? "") || (locator.text ?? "").contains(result.quote),
            "Quote should match the selected text"
        )
        XCTAssertFalse(result.before.isEmpty, "Expected paragraphs before a mid-chapter quote")
        XCTAssertFalse(result.after.isEmpty, "Expected paragraphs after a mid-chapter quote")
        XCTAssertFalse(result.before.contains(result.quote))
        XCTAssertFalse(result.after.contains(result.quote))
    }

    private func middleParagraphLocator(in reader: ReaderController) throws -> Locator {
        let script = """
        (function () {
          var paragraphs = Array.from(document.querySelectorAll('p')).filter(function (p) {
            return (p.textContent || '').trim().length > 80;
          });
          if (!paragraphs.length) return null;
          var paragraph = paragraphs[Math.floor(paragraphs.length / 2)];
          var walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT, null);
          var node = walker.nextNode();
          while (node && (node.textContent || '').trim().length < 40) node = walker.nextNode();
          if (!node) return null;
          function pathOfNode(target) {
            var path = [];
            while (target && target !== document.body) {
              var parent = target.parentNode;
              if (!parent) return [];
              path.unshift(Array.prototype.indexOf.call(parent.childNodes, target));
              target = parent;
            }
            return path;
          }
          var text = node.textContent || '';
          var start = Math.min(5, Math.max(0, text.length - 1));
          var end = Math.min(text.length, start + 40);
          return JSON.stringify({
            spineIndex: \(reader.spineIndex),
            start: { elementPath: pathOfNode(node), offset: start },
            end: { elementPath: pathOfNode(node), offset: end },
            text: text.slice(start, end)
          });
        })()
        """
        var payload: String?
        var settled = false
        reader.evaluateForTesting(script) { value in
            payload = value as? String
            settled = true
        }
        XCTAssertTrue(spin(timeout: 5) { settled })
        let json = try XCTUnwrap(payload, "No middle paragraph found")
        return try JSONDecoder().decode(Locator.self, from: Data(json.utf8))
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
