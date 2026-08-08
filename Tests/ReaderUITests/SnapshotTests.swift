import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

/// Renders pages to PNGs so the typography and layout can actually be looked
/// at. `takeSnapshot` captures the web view's own rendering in-process, which
/// needs no screen recording permission and shows exactly what the reader
/// draws rather than whatever happens to be on the display.
///
/// Output lands in `Snapshots/` at the repo root.
final class SnapshotTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?

    override func tearDown() {
        controller?.tearDown()
        controller = nil
        // Detach the web view before dropping the window; closing a window
        // that still hosts a live WKWebView tears down WebKit state that the
        // snapshot machinery may still be holding.
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots")
    }

    func testRenderThemes() throws {
        for theme in ReaderTheme.allCases {
            var settings = ReaderSettings()
            settings.theme = theme
            settings.twoPageSpread = false
            try renderPage(
                named: "theme-\(theme.rawValue)",
                settings: settings,
                size: CGSize(width: 900, height: 700)
            )
        }
    }

    func testRenderTwoPageSpread() throws {
        var settings = ReaderSettings()
        settings.theme = .light
        settings.twoPageSpread = true
        try renderPage(
            named: "two-page-spread",
            settings: settings,
            size: CGSize(width: 1400, height: 900)
        )
    }

    func testRenderTypographyExtremes() throws {
        var large = ReaderSettings()
        large.theme = .light
        large.fontSize = 30
        large.lineHeight = 2.0
        large.marginRatio = 0.16
        large.twoPageSpread = false
        try renderPage(named: "large-text", settings: large, size: CGSize(width: 900, height: 700))

        var compact = ReaderSettings()
        compact.theme = .light
        compact.fontSize = 13
        compact.lineHeight = 1.3
        compact.marginRatio = 0.04
        compact.justified = false
        compact.twoPageSpread = false
        try renderPage(named: "small-text", settings: compact, size: CGSize(width: 900, height: 700))
    }

    func testRenderHighlight() throws {
        var settings = ReaderSettings()
        settings.theme = .light
        settings.twoPageSpread = false
        try renderPage(
            named: "highlight",
            settings: settings,
            size: CGSize(width: 900, height: 700),
            addHighlight: true
        )
    }

    func testRenderDarkHighlight() throws {
        var settings = ReaderSettings()
        settings.theme = .dark
        settings.twoPageSpread = false
        try renderPage(
            named: "highlight-dark",
            settings: settings,
            size: CGSize(width: 900, height: 700),
            addHighlight: true
        )
    }

    // MARK: - Rendering

    private func renderPage(
        named name: String,
        settings: ReaderSettings,
        size: CGSize,
        addHighlight: Bool = false
    ) throws {
        let url = SampleBooks.url(SampleBooks.frankenstein)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let book = try EPUBBook(fileURL: url)
        let reader = ReaderController(settings: settings)
        controller = reader

        let webView = reader.makeWebView(for: book)
        webView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Programmatic windows release themselves on close, which leaves the
        // test holding a dangling reference.
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        reader.updateViewport(width: size.width)

        // The prose chapters read better than the cover for judging type.
        let order = book.publication.readingOrder
        let chapter = order.indices.max {
            book.container.uncompressedSize(at: order[$0].path)
                < book.container.uncompressedSize(at: order[$1].path)
        } ?? 0

        var anchor: TextPosition?
        reader.onPositionChanged = { anchor = $0.start }
        reader.start(
            at: Locator(spineIndex: chapter, start: TextPosition(elementPath: [], offset: 0)),
            annotations: []
        )
        XCTAssertTrue(spin { !reader.isLoading && anchor != nil }, "\(name): never loaded")

        if addHighlight, let anchor {
            reader.setAnnotations([
                Annotation(
                    locator: Locator(
                        spineIndex: chapter,
                        start: anchor,
                        end: TextPosition(
                            elementPath: anchor.elementPath,
                            offset: anchor.offset + 180
                        )
                    ),
                    text: "a highlighted passage",
                    note: "with a note",
                    color: .yellow
                )
            ])
        }

        // Let layout, fonts, and highlight painting settle before capturing.
        _ = spin(timeout: 1.2) { false }

        let image = try snapshot(webView)
        try write(image, named: name)
    }

    private func snapshot(_ webView: WKWebView) throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true

        var result: NSImage?
        var failure: Error?
        var finished = false

        webView.takeSnapshot(with: configuration) { image, error in
            result = image
            failure = error
            finished = true
        }
        XCTAssertTrue(spin(timeout: 12) { finished }, "Snapshot timed out")

        if let failure { throw failure }
        return try XCTUnwrap(result, "Snapshot produced no image")
    }

    private func write(_ image: NSImage, named name: String) throws {
        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return XCTFail("Could not encode \(name) as PNG")
        }
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("SNAPSHOT \(url.path)")
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
