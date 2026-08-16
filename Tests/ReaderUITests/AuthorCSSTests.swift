import AppKit
import EpubKit
import WebKit
import XCTest
import ZIPFoundation
@testable import ReaderUI

/// Calibre/Kindle conversions style the page through generated classes
/// (`.calibre { padding: 0; font-size: 1em; line-height: 1.2 }`) that outrank
/// a bare `body` rule. These tests pin the reader against that cascade so
/// pagination, margins, and the type sliders keep working.
final class AuthorCSSTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?
    private var bookURL: URL?

    override func tearDown() {
        controller?.tearDown()
        controller = nil
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        if let bookURL {
            try? FileManager.default.removeItem(at: bookURL)
        }
        bookURL = nil
        super.tearDown()
    }

    func testCalibreBodyClassCannotZeroPageMargins() throws {
        let size = CGSize(width: 700, height: 500)
        let (reader, _) = try makeCalibreReader(size: size)
        XCTAssertTrue(wait { !reader.isLoading })

        let box = bodyBox(from: reader)
        let expectedPad = reader.settings.horizontalMargin(forWidth: size.width)
        XCTAssertEqual(
            box["paddingLeft"] ?? -1, expectedPad, accuracy: 1,
            "Author .calibre padding-left: 0 leaked through: \(box)"
        )
        XCTAssertEqual(
            box["paddingRight"] ?? -1, expectedPad, accuracy: 1,
            "Author .calibre padding-right: 0 leaked through: \(box)"
        )
        XCTAssertEqual(
            box["marginLeft"] ?? -1, 0, accuracy: 0.5,
            "Author body margin should be cleared: \(box)"
        )
        XCTAssertEqual(
            box["marginRight"] ?? -1, 0, accuracy: 0.5,
            "Author body margin should be cleared: \(box)"
        )
    }

    func testCalibreFontSizeSliderScalesTypeAndRepaginates() throws {
        let (reader, _) = try makeCalibreReader(size: CGSize(width: 700, height: 500))
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 1, "Fixture fit on one page")

        let beforeCount = reader.pageCount
        let beforeSize = bodyBox(from: reader)["fontSize"] ?? 0
        XCTAssertEqual(beforeSize, reader.settings.fontSize, accuracy: 1)

        var settings = reader.settings
        settings.fontSize = 30
        reader.settings = settings

        XCTAssertTrue(
            wait(timeout: 6) { reader.pageCount > beforeCount },
            "Page count stayed at \(reader.pageCount) after growing type (was \(beforeCount))"
        )
        XCTAssertEqual(
            bodyBox(from: reader)["fontSize"] ?? 0, 30, accuracy: 1,
            "Body font-size did not follow the slider"
        )
    }

    func testCalibreLineHeightSliderReachesParagraphs() throws {
        let (reader, _) = try makeCalibreReader(size: CGSize(width: 700, height: 500))
        XCTAssertTrue(wait { !reader.isLoading })

        let before = paragraphLineHeight(from: reader)
        XCTAssertGreaterThan(before, 0, "Could not read a paragraph line-height")

        var settings = reader.settings
        settings.lineHeight = 2.4
        reader.settings = settings

        XCTAssertTrue(
            wait(timeout: 6) {
                let now = paragraphLineHeight(from: reader)
                return now > before + 2
            },
            "Paragraph line-height stayed at \(paragraphLineHeight(from: reader)) (was \(before))"
        )
    }

    func testCalibreStrideMatchesViewportAndSurvivesResize() throws {
        let startSize = CGSize(width: 900, height: 700)
        let (reader, _) = try makeCalibreReader(size: startSize)
        XCTAssertTrue(wait { !reader.isLoading })
        try XCTSkipUnless(reader.pageCount > 2, "Need several pages to walk")

        // Let the initial window-resize debounce finish so a late relayout
        // cannot snap us back to page 0 after the jump below.
        _ = wait(timeout: 0.4) { false }

        let start = pagingGeometry(from: reader)
        let innerWidth = start["innerWidth"] ?? 1
        XCTAssertEqual(
            start["stride"] ?? -1, innerWidth, accuracy: 2,
            "Measured stride drifted from the viewport: \(start)"
        )

        var jumped = false
        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in jumped = true }
        XCTAssertTrue(wait { jumped }, "goToPage script did not run")
        XCTAssertTrue(
            wait(timeout: 5) {
                let now = pagingGeometry(from: reader)
                return pageIndexAgreesWithScroll(now, swiftPage: reader.page)
                    && reader.page == 1
            },
            "Page 2 did not land on a viewport boundary: \(pagingGeometry(from: reader))"
        )

        let oneColumnSize = CGSize(width: 700, height: 700)
        window?.setContentSize(oneColumnSize)
        window?.contentView?.frame = CGRect(origin: .zero, size: oneColumnSize)
        window?.contentView?.layoutSubtreeIfNeeded()
        reader.updateViewport(width: oneColumnSize.width, height: oneColumnSize.height)

        XCTAssertTrue(
            wait(timeout: 6) {
                let geo = pagingGeometry(from: reader)
                return pageIndexAgreesWithScroll(geo, swiftPage: reader.page)
                    && abs((geo["stride"] ?? -1) - (geo["innerWidth"] ?? 0)) <= 2
            },
            "After resize, page/scroll/stride disagreed: \(pagingGeometry(from: reader))"
        )

        let aligned = pagingGeometry(from: reader)
        let scrollBefore = aligned["scrollLeft"] ?? 0
        let pageBefore = reader.page
        reader.nextPage()
        XCTAssertTrue(
            wait(timeout: 5) {
                let geo = pagingGeometry(from: reader)
                return reader.page > pageBefore
                    && (geo["scrollLeft"] ?? scrollBefore) > scrollBefore + 10
                    && pageIndexAgreesWithScroll(geo, swiftPage: reader.page)
            },
            "nextPage after resize did not move the visible page: \(pagingGeometry(from: reader))"
        )
    }

    /// The book that surfaced the bug is a Calibre Kindle conversion. If it is
    /// in the local library, pin the same invariants against the real file.
    func testRockefellerConversionHonorsPageBoxAndPaging() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.olly.Folio/Data/Library/Application Support/EpubReader/Books/B08HM8G5VD.epub"
            )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Rockefeller EPUB not in the local library")

        let size = CGSize(width: 800, height: 700)
        let chapter = max(0, (try EPUBBook(fileURL: url)).publication.readingOrder.count / 4)
        let (reader, _) = try makeReader(
            fileURL: url,
            size: size,
            deleteOnTearDown: false,
            locator: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0))
        )
        XCTAssertTrue(wait { !reader.isLoading })

        let expectedPad = reader.settings.horizontalMargin(forWidth: size.width)
        let box = bodyBox(from: reader)
        XCTAssertEqual(box["paddingLeft"] ?? -1, expectedPad, accuracy: 1, "Rockefeller still has zero padding: \(box)")
        XCTAssertEqual(box["marginLeft"] ?? -1, 0, accuracy: 0.5, "Rockefeller still has author body margin: \(box)")
        XCTAssertEqual(box["fontSize"] ?? 0, reader.settings.fontSize, accuracy: 1)

        try XCTSkipUnless(reader.pageCount > 1, "Chapter fit on one page")
        _ = wait(timeout: 0.4) { false }
        var jumped = false
        reader.evaluateForTesting("__reader.goToPage(1, false)") { _ in jumped = true }
        XCTAssertTrue(wait { jumped })
        XCTAssertTrue(
            wait(timeout: 5) {
                pageIndexAgreesWithScroll(pagingGeometry(from: reader), swiftPage: reader.page)
                    && reader.page == 1
            },
            "Rockefeller page 2 did not match scroll: \(pagingGeometry(from: reader))"
        )
    }

    // MARK: - Harness

    private func makeCalibreReader(
        size: CGSize
    ) throws -> (ReaderController, EPUBBook) {
        let url = try CalibreFixture.writeEPUB()
        return try makeReader(fileURL: url, size: size, deleteOnTearDown: true)
    }

    private func makeReader(
        fileURL: URL,
        size: CGSize,
        deleteOnTearDown: Bool,
        locator: Locator? = nil
    ) throws -> (ReaderController, EPUBBook) {
        if deleteOnTearDown { bookURL = fileURL }
        let book = try EPUBBook(fileURL: fileURL)
        var settings = ReaderSettings()
        settings.animatePageTurns = false
        let controller = ReaderController(settings: settings)
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
        controller.updateViewport(width: size.width, height: size.height)
        controller.start(at: locator, annotations: [])
        return (controller, book)
    }

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

    private func bodyBox(from reader: ReaderController) -> [String: Double] {
        numberMap(
            from: reader,
            """
            (function () {
              var s = getComputedStyle(document.body);
              return {
                paddingLeft: parseFloat(s.paddingLeft),
                paddingRight: parseFloat(s.paddingRight),
                marginLeft: parseFloat(s.marginLeft),
                marginRight: parseFloat(s.marginRight),
                fontSize: parseFloat(s.fontSize),
                lineHeight: parseFloat(s.lineHeight)
              };
            })()
            """
        )
    }

    private func paragraphLineHeight(from reader: ReaderController) -> Double {
        var result: Double?
        reader.evaluateForTesting(
            """
            (function () {
              var p = document.querySelector("p");
              if (!p) return 0;
              return parseFloat(getComputedStyle(p).lineHeight);
            })()
            """
        ) { result = ($0 as? NSNumber)?.doubleValue }
        _ = wait(timeout: 2) { result != nil }
        return result ?? 0
    }

    private func pagingGeometry(from reader: ReaderController) -> [String: Double] {
        numberMap(
            from: reader,
            """
            (function () {
              var el = document.scrollingElement || document.documentElement;
              var body = document.body;
              var s = getComputedStyle(body);
              var gap = !s.columnGap || s.columnGap === "normal" ? 0 : parseFloat(s.columnGap);
              var stride = el.clientWidth
                - parseFloat(s.marginLeft) - parseFloat(s.marginRight)
                - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight)
                + gap;
              var state = window.__reader.state();
              return {
                scrollLeft: el.scrollLeft,
                innerWidth: window.innerWidth,
                maxScroll: el.scrollWidth - el.clientWidth,
                pageCount: state.pageCount,
                page: state.page,
                stride: stride
              };
            })()
            """
        )
    }

    private func pageIndexAgreesWithScroll(_ geo: [String: Double], swiftPage: Int) -> Bool {
        let innerWidth = geo["innerWidth"] ?? 0
        let scrollLeft = geo["scrollLeft"] ?? -1
        let jsPage = geo["page"] ?? -1
        guard innerWidth > 0 else { return false }
        return abs(scrollLeft - Double(swiftPage) * innerWidth) <= 2
            && abs(jsPage - Double(swiftPage)) < 0.5
    }

    private func numberMap(from reader: ReaderController, _ script: String) -> [String: Double] {
        var result: [String: Double]?
        reader.evaluateForTesting(script) {
            result = ($0 as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        _ = wait(timeout: 2) { result != nil }
        return result ?? [:]
    }
}

/// Minimal EPUB 2 whose stylesheet matches a Calibre Kindle conversion:
/// `<body class="calibre">` with padding, font-size, and line-height pinned
/// through classes that outrank the reader's element selectors.
enum CalibreFixture {
    static func writeEPUB() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibre-fixture-\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)

        let mimetype = Data("application/epub+zip".utf8)
        try add(mimetype, path: "mimetype", to: archive, compression: .none)
        try add(containerXML, path: "META-INF/container.xml", to: archive)
        try add(packageOPF, path: "content.opf", to: archive)
        try add(ncx, path: "toc.ncx", to: archive)
        try add(stylesheet, path: "stylesheet.css", to: archive)
        try add(chapterHTML, path: "text/chapter.html", to: archive)
        return url
    }

    private static func add(
        _ data: Data,
        path: String,
        to archive: Archive,
        compression: CompressionMethod = .deflate
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static let containerXML = Data("""
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.utf8)

    private static let packageOPF = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Calibre Fixture</dc:title>
        <dc:language>en</dc:language>
        <dc:identifier id="bookid">calibre-fixture</dc:identifier>
      </metadata>
      <manifest>
        <item id="css" href="stylesheet.css" media-type="text/css"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="ch1" href="text/chapter.html" media-type="application/xhtml+xml"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="ch1"/>
      </spine>
    </package>
    """.utf8)

    private static let ncx = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head>
        <meta name="dtb:uid" content="calibre-fixture"/>
      </head>
      <docTitle><text>Calibre Fixture</text></docTitle>
      <navMap>
        <navPoint id="n1" playOrder="1">
          <navLabel><text>Letter 3</text></navLabel>
          <content src="text/chapter.html"/>
        </navPoint>
      </navMap>
    </ncx>
    """.utf8)

    private static let stylesheet = Data("""
    .calibre {
      display: block;
      font-size: 1em;
      line-height: 1.2;
      padding-left: 0;
      padding-right: 0;
      margin: 0 5pt;
    }
    .calibre1 { display: block; }
    .calibre7 {
      display: block;
      font-size: 1em;
      line-height: 1.2;
      margin-bottom: 1.77%;
      margin-top: 0%;
      text-indent: 2.2em;
    }
    """.utf8)

    private static var chapterHTML: Data {
        let sentence = "There is an allegory that is very meaningful and provided many insights about work, character, and the difference between heaven and hell. "
        let paragraph = String(repeating: sentence, count: 5)
        let paragraphs = (0..<48).map { "<p class=\"calibre7\">\(paragraph) (\($0))</p>" }.joined(separator: "\n")
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>Letter 3</title>
            <link rel="stylesheet" type="text/css" href="../stylesheet.css"/>
          </head>
          <body class="calibre">
            <div class="calibre1">
              \(paragraphs)
            </div>
          </body>
        </html>
        """.utf8)
    }
}
