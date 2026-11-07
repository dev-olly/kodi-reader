import AppKit
import EpubKit
import WebKit
import XCTest
import ZIPFoundation
@testable import ReaderUI

final class ReferenceNavigationTests: XCTestCase {
    private var window: NSWindow?
    private var reader: ReaderController?
    private var files: [URL] = []

    override func tearDown() {
        reader?.tearDown()
        window?.contentView = nil
        window?.orderOut(nil)
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func testSameChapterAndNestedReferencesReturnOneStepAtATime() throws {
        let reader = try makeReader()
        var pauses = 0
        reader.onReferenceNavigationWillBegin = { pauses += 1 }
        let origin = try position(reader)
        click("local", reader)
        XCTAssertTrue(wait { reader.canReturnFromReference && !reader.isReferenceNavigationInProgress })
        XCTAssertGreaterThan(reader.page, 0)
        XCTAssertEqual(pauses, 1)
        reader.returnFromReference()
        reader.returnFromReference()
        XCTAssertTrue(wait { !reader.canReturnFromReference && !reader.isReferenceNavigationInProgress })
        XCTAssertTrue(isVisible(origin, reader))

        click("second", reader)
        XCTAssertTrue(wait { reader.spineIndex == 1 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        click("third", reader)
        XCTAssertTrue(wait { reader.spineIndex == 2 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        reader.returnFromReference()
        XCTAssertTrue(wait { reader.spineIndex == 1 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        XCTAssertTrue(reader.canReturnFromReference)
        reader.returnFromReference()
        XCTAssertTrue(wait { reader.spineIndex == 0 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        XCTAssertFalse(reader.canReturnFromReference)
        XCTAssertTrue(isVisible(origin, reader))
        XCTAssertEqual(pauses, 3, "Returning must not invoke the reference-follow callback")
    }

    func testRightColumnClickReturnsToOriginalSpreadAfterReflow() throws {
        let reader = try makeReader(width: 1400)
        _ = evaluate(reader, "__reader.goToPage(2, false)")
        XCTAssertTrue(wait { reader.page == 2 })
        let origin = try position(reader)
        _ = evaluate(reader, """
            (() => {
              const link = document.createElement('a');
              link.id = 'right-column-reference'; link.href = 'two.xhtml#ref'; link.textContent = '[1]';
              link.style.cssText = 'position:fixed;right:100px;top:120px';
              document.body.appendChild(link);
              return link.getBoundingClientRect().left > innerWidth / 2;
            })()
            """)
        click("right-column-reference", reader)
        XCTAssertTrue(wait { reader.spineIndex == 1 && !reader.isReferenceNavigationInProgress })
        var settings = reader.settings
        settings.fontSize += 4
        reader.settings = settings
        window?.setContentSize(CGSize(width: 900, height: 800))
        reader.updateViewport(width: 900, height: 800)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        reader.returnFromReference()
        XCTAssertTrue(wait { reader.spineIndex == 0 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        XCTAssertTrue(isVisible(origin, reader), "Return must use the source passage rather than an obsolete page number")
    }

    func testInvalidNoOpExternalAndOrdinaryJumpsDoNotAddHistory() throws {
        let reader = try makeReader()
        var pauses = 0
        reader.onReferenceNavigationWillBegin = { pauses += 1 }
        var external: URL?
        reader.onExternalLink = { external = $0 }
        for id in ["noop", "missing-fragment", "missing-path", "external"] { click(id, reader) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(reader.canReturnFromReference)
        XCTAssertFalse(reader.isReferenceNavigationInProgress)
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(external?.host, "example.com")
        reader.go(to: Locator(spineIndex: 1, start: TextPosition(elementPath: [], offset: 0)))
        XCTAssertTrue(wait { !reader.isLoading && reader.spineIndex == 1 })
        XCTAssertFalse(reader.canReturnFromReference)

        reader.go(to: .startOfBook())
        XCTAssertTrue(wait { !reader.isLoading && reader.spineIndex == 0 })
        let origin = try position(reader)
        click("bad-cross-fragment", reader)
        XCTAssertTrue(wait { pauses == 1 && !reader.isLoading && !reader.isReferenceNavigationInProgress && reader.spineIndex == 0 })
        XCTAssertFalse(reader.canReturnFromReference)
        XCTAssertTrue(isVisible(origin, reader), "A missing fragment in another chapter should recover the source passage")
    }

    func testFailedChapterLoadStillAllowsReturnAndDismissal() throws {
        let reader = try makeReader()
        click("broken", reader)
        XCTAssertTrue(wait { reader.errorMessage != nil && !reader.isLoading })
        XCTAssertTrue(reader.canReturnFromReference)
        reader.returnFromReference()
        XCTAssertTrue(wait { reader.spineIndex == 0 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        XCTAssertFalse(reader.canReturnFromReference)
        XCTAssertNil(reader.errorMessage)
        click("second", reader)
        XCTAssertTrue(wait { reader.spineIndex == 1 && !reader.isReferenceNavigationInProgress })
        reader.dismissReferenceHistory()
        XCTAssertFalse(reader.canReturnFromReference)
    }

    func testHistoryIsBoundedRetainedWhileBrowsingAndClearedOnBookChange() throws {
        let reader = try makeReader()
        for index in 0..<34 {
            click(index % 2 == 0 ? "second" : "first", reader)
            let chapter = index % 2 == 0 ? 1 : 0
            XCTAssertTrue(wait { reader.spineIndex == chapter && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        }
        reader.nextPage()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(reader.canReturnFromReference)
        var returned = 0
        while reader.canReturnFromReference && returned < 40 {
            reader.returnFromReference()
            XCTAssertTrue(wait { !reader.isLoading && !reader.isReferenceNavigationInProgress })
            returned += 1
        }
        XCTAssertEqual(returned, 32)
        click("second", reader)
        XCTAssertTrue(wait { reader.canReturnFromReference && !reader.isReferenceNavigationInProgress })
        let replacementURL = try fixture()
        _ = reader.makeWebView(for: try EPUBBook(fileURL: replacementURL))
        XCTAssertFalse(reader.canReturnFromReference)
        reader.tearDown()
        XCTAssertFalse(reader.canReturnFromReference)
    }

    func testRapidClicksAndStaleSourceMessagesCannotCreateExtraReturns() throws {
        let reader = try makeReader()
        _ = evaluate(reader, "document.getElementById('second').click(); document.getElementById('second').click()")
        XCTAssertTrue(wait { reader.spineIndex == 1 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        _ = evaluate(reader, "window.webkit.messageHandlers.reader.postMessage({type:'link',href:'three.xhtml#ref',documentID:'stale',spineIndex:1,position:{elementPath:[],offset:0}})")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(reader.spineIndex, 1)
        reader.returnFromReference()
        reader.returnFromReference()
        XCTAssertTrue(wait { reader.spineIndex == 0 && !reader.isLoading && !reader.isReferenceNavigationInProgress })
        XCTAssertFalse(reader.canReturnFromReference)
    }

    private func makeReader(width: CGFloat = 700) throws -> ReaderController {
        let book = try EPUBBook(fileURL: fixture())
        var settings = ReaderSettings()
        settings.animatePageTurns = false
        let reader = ReaderController(settings: settings)
        self.reader = reader
        let view = reader.makeWebView(for: book)
        let size = CGSize(width: width, height: 800)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        self.window = window
        reader.updateViewport(width: width, height: 800)
        reader.start(at: nil, annotations: [])
        XCTAssertTrue(wait { !reader.isLoading })
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return reader
    }

    private func click(_ id: String, _ reader: ReaderController) {
        _ = evaluate(reader, "document.getElementById('\(id)').click()")
    }

    private func position(_ reader: ReaderController) throws -> TextPosition {
        let value = try XCTUnwrap(evaluate(reader, "JSON.stringify(__reader.state().position)") as? String)
        return try JSONDecoder().decode(TextPosition.self, from: Data(value.utf8))
    }

    private func isVisible(_ position: TextPosition, _ reader: ReaderController) -> Bool {
        let encoded = String(data: try! JSONEncoder().encode(position), encoding: .utf8)!
        return evaluate(reader, """
            (() => {
              const p = \(encoded); let node = document.body;
              for (const index of p.elementPath) node = node.childNodes[index];
              const range = document.createRange(); range.setStart(node, p.offset);
              range.setEnd(node, Math.min(node.length, p.offset + 1));
              const rect = range.getBoundingClientRect();
              return rect.left >= -1 && rect.left < innerWidth && rect.top >= -1 && rect.top < innerHeight;
            })()
            """) as? Bool == true
    }

    private func evaluate(_ reader: ReaderController, _ script: String) -> Any? {
        var value: Any?
        var done = false
        reader.evaluateForTesting(script) { value = $0; done = true }
        XCTAssertTrue(wait { done })
        return value
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("references-\(UUID().uuidString).epub")
        files.append(url)
        let archive = try Archive(url: url, accessMode: .create)
        let paragraphs = (0..<32).map { index in
            "<p id='p\(index)'>" + String(repeating: "A reference leads to another passage while this source remains available for return. ", count: 8) + "</p>"
        }.joined()
        let chapters = [
            "one.xhtml": "<h1 id='top'>Reading</h1><a id='local' href='#local%2Dtarget'>Local reference</a> <a id='second' href='two.xhtml#ref'>Second chapter</a> <a id='broken' href='broken.xhtml#ref'>Broken</a> <a id='noop' href='#top'>No move</a> <a id='missing-fragment' href='#absent'>Missing fragment</a> <a id='missing-path' href='missing.xhtml'>Missing path</a> <a id='bad-cross-fragment' href='two.xhtml#absent'>Missing cross chapter fragment</a> <a id='external' href='https://example.com'>Web</a>" + paragraphs + "<h2 id='local-target'>Local reference target</h2><p>Reference details.</p>",
            "two.xhtml": "<h1 id='ref'>Reference chapter</h1><a id='third' href='three.xhtml#ref'>Another reference</a> <a id='first' href='one.xhtml#top'>Reading chapter</a>" + paragraphs,
            "three.xhtml": "<h1 id='ref'>Nested reference</h1><p>Nested reference details.</p>"
        ]
        var entries = chapters.mapValues { "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Reference fixture</title></head><body>\($0)</body></html>" }
        entries["mimetype"] = "application/epub+zip"
        entries["META-INF/container.xml"] = "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"
        entries["content.opf"] = """
            <package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='id'>
            <metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title>Reference fixture</dc:title><dc:identifier id='id'>\(UUID())</dc:identifier><dc:language>en</dc:language></metadata>
            <manifest><item id='one' href='one.xhtml' media-type='application/xhtml+xml'/><item id='two' href='two.xhtml' media-type='application/xhtml+xml'/><item id='three' href='three.xhtml' media-type='application/xhtml+xml'/><item id='broken' href='broken.xhtml' media-type='application/xhtml+xml'/></manifest>
            <spine><itemref idref='one'/><itemref idref='two'/><itemref idref='three'/><itemref idref='broken'/></spine></package>
            """
        for (path, content) in entries {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }
}
