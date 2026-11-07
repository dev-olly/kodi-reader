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

    @MainActor
    func testNarrationStartsAtViewportAndSkipsHiddenAndNavigationText() async throws {
        let (reader, chapter) = try loadTextChapter(waitForPosition: false)
        let deadline = Date().addingTimeInterval(5)
        while reader.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(reader.isLoading)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            reader.evaluateForTesting("""
                document.body.insertAdjacentHTML('beforeend',
                  '<nav>Skip this navigation sentinel</nav>' +
                  '<p style="display: none">Skip this hidden sentinel</p>' +
                  '<p>Read <em>this</em> final sentinel.</p>');
                __reader.notifyState();
                """) { _ in continuation.resume() }
        }
        let opening = await reader.narrationTextFromViewport()
        let chapterText = try XCTUnwrap(opening)
        XCTAssertTrue(chapterText.hasSuffix("Read this final sentinel."))
        XCTAssertFalse(chapterText.contains("Skip this"))

        reader.nextPage()
        let pageDeadline = Date().addingTimeInterval(5)
        while reader.page == 0 && Date() < pageDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(reader.page, 0)
        let page = reader.page
        let remaining = await reader.narrationTextFromViewport()
        let remainingText = try XCTUnwrap(remaining)
        XCTAssertLessThan(remainingText.count, chapterText.count)
        XCTAssertFalse(remainingText.contains(chapterText.prefix(80)))
        XCTAssertTrue(remainingText.hasSuffix("Read this final sentinel."))
        XCTAssertEqual(reader.page, page)
        XCTAssertEqual(reader.spineIndex, chapter)

        let extractedPassages = await reader.narrationPassages()
        let passages = try XCTUnwrap(extractedPassages)
        XCTAssertFalse(passages.isEmpty)
        XCTAssertTrue(passages.allSatisfy { $0.text.utf16.count <= 400 })
        let passage = try XCTUnwrap(passages.last)
        reader.showNarrationPassage(passage.locator)
        let highlighted = await withCheckedContinuation { continuation in
            reader.evaluateForTesting("CSS.highlights.get('kodi-narration').values().next().value.toString()") {
                continuation.resume(returning: $0 as? String)
            }
        }
        XCTAssertEqual(highlighted, passage.text)
        XCTAssertEqual(reader.page, page, "A spoken cue should allow independent browsing")
        XCTAssertTrue(reader.annotations.isEmpty)
        reader.showNarrationPassage(nil)
        let clearedRangeCount = await withCheckedContinuation { continuation in
            reader.evaluateForTesting("CSS.highlights.get('kodi-narration').size") {
                continuation.resume(returning: $0 as? Int)
            }
        }
        XCTAssertEqual(clearedRangeCount, 0)

        let book = try XCTUnwrap(reader.book)
        let followingChapter = try await ReaderController.narrationPassages(in: book, chapter: chapter)
        XCTAssertGreaterThan(followingChapter.count, passages.count)
        XCTAssertEqual(reader.spineIndex, chapter)
        XCTAssertEqual(reader.page, page, "Preparing narration in a second WebKit context must preserve the visible page")

        let selectionJSON = await withCheckedContinuation { continuation in
            reader.evaluateForTesting("""
                (() => {
                  document.body.insertAdjacentHTML('beforeend', '<p id="audio-selection">Before <em>café 🌿</em> after. Leave this unread.</p>');
                  const paragraph = document.getElementById('audio-selection');
                  function path(node) {
                    const result = [];
                    while (node !== document.body) {
                      result.unshift(Array.from(node.parentNode.childNodes).indexOf(node));
                      node = node.parentNode;
                    }
                    return result;
                  }
                  return JSON.stringify({
                    spineIndex: \(chapter),
                    start: {elementPath: path(paragraph.querySelector('em').firstChild), offset: 0},
                    end: {elementPath: path(paragraph.lastChild), offset: 6}
                  });
                })()
                """) { continuation.resume(returning: $0 as? String) }
        }
        let selectionLocator = try JSONDecoder().decode(Locator.self, from: Data(try XCTUnwrap(selectionJSON).utf8))
        let selection = ReaderSelection(text: "café 🌿 after", locator: selectionLocator, rect: .zero)
        let selectedPassages = await reader.narrationPassages(selection: selection)
        XCTAssertEqual(selectedPassages?.map(\.text), ["café 🌿 after"])
        let fromHere = await reader.narrationPassages(from: selectionLocator)
        XCTAssertTrue(fromHere?.first?.text.hasPrefix("café 🌿 after") == true)
        XCTAssertTrue(fromHere?.last?.text.contains("Leave this unread.") == true,
                      "Listen from Here should continue beyond the selection")
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

    private func loadTextChapter(waitForPosition: Bool = true) throws -> (ReaderController, Int) {
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
        if waitForPosition {
            XCTAssertTrue(spin { !reader.isLoading && ready })
        }
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
