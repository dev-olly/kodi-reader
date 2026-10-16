import XCTest
import AppKit
import WebKit
@testable import ReaderUI

final class ExcalidrawHostTests: XCTestCase {
    private func scene(_ id: String, x: Double = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["elements": [[
            "id": id, "type": "rectangle", "x": x, "y": 20, "width": 160, "height": 100,
            "angle": 0, "strokeColor": "#245744", "backgroundColor": "#E1EDDB", "fillStyle": "solid",
            "strokeWidth": 2, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "groupIds": [],
            "frameId": NSNull(), "roundness": NSNull(), "seed": 1, "version": 1, "versionNonce": 1,
            "isDeleted": false, "boundElements": [], "updated": 1, "link": NSNull(), "locked": false,
        ]], "appState": ["scrollX": -9999, "scrollY": -9999], "files": [:]])
    }

    private func wait(timeout: TimeInterval = 20, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testLiveCheckpointRendersCompleteSceneAndSwitchesIndependently() throws {
        _ = NSApplication.shared
        let controller = ExcalidrawController()
        controller.load(scene: try scene("first", x: 2500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = controller.makeWebView()
        window.contentView = view
        window.orderBack(nil)
        defer { controller.tearDown(); window.contentView = nil; window.orderOut(nil) }
        var ready = false
        controller.onReady = { ready = true }
        XCTAssertTrue(wait { ready })
        var result: Result<SketchCheckpoint, Error>?
        controller.checkpoint { result = $0 }
        XCTAssertTrue(wait { result != nil })
        let first = try XCTUnwrap(result).get()
        XCTAssertEqual(first.elementCount, 1)
        let image = try XCTUnwrap(first.preview.flatMap { NSImage(data: $0) })
        XCTAssertGreaterThan(image.size.width, image.size.height)
        XCTAssertTrue(String(data: first.scene, encoding: .utf8)!.contains("first"))
        controller.load(scene: try scene("second"))
        result = nil
        controller.checkpoint { result = $0 }
        XCTAssertTrue(wait { result != nil })
        let second = try XCTUnwrap(result).get()
        XCTAssertTrue(String(data: second.scene, encoding: .utf8)!.contains("second"))
        XCTAssertFalse(String(data: second.scene, encoding: .utf8)!.contains("first"))
        var historyCleared: Bool?
        view.evaluateJavaScript("__excalidraw.getScene().elementCount === 1") { historyCleared = $0 as? Bool; _ = $1 }
        XCTAssertTrue(wait { historyCleared != nil })
        XCTAssertEqual(historyCleared, true)
    }

    func testCheckpointRejectsResultsFromPreviousSession() throws {
        _ = NSApplication.shared
        let controller = ExcalidrawController()
        let view = controller.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { controller.tearDown(); window.contentView = nil; window.orderOut(nil) }
        var ready = false; controller.onReady = { ready = true }
        XCTAssertTrue(wait { ready })
        controller.load(scene: try scene("old"))
        var result: Result<SketchCheckpoint, Error>?
        controller.checkpoint { result = $0 }
        controller.load(scene: try scene("new"))
        XCTAssertTrue(wait { result != nil })
        XCTAssertThrowsError(try XCTUnwrap(result).get())
    }

    func testDedicatedRendererWorksWithoutActiveCanvas() throws {
        _ = NSApplication.shared
        var result: Result<Data, Error>?
        ExcalidrawController.renderPreview(scene: try scene("export", x: 9000)) { result = $0 }
        XCTAssertTrue(wait(timeout: 25) { result != nil })
        let png = try XCTUnwrap(result).get()
        XCTAssertNotNil(NSImage(data: png))
        XCTAssertTrue(png.starts(with: [137, 80, 78, 71]))
    }

    func testBundledHostContainsIndexAndAssets() {
        let index = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Resources/Excalidraw"
        )
        XCTAssertNotNil(index, "Excalidraw index.html should ship in the ReaderUI resource bundle")

        let script = Bundle.module.url(
            forResource: "index",
            withExtension: "js",
            subdirectory: "Resources/Excalidraw/assets"
        )
        XCTAssertNotNil(script, "Excalidraw IIFE bundle should ship next to index.html")

        let css = Bundle.module.url(
            forResource: "style",
            withExtension: "css",
            subdirectory: "Resources/Excalidraw/assets"
        )
        XCTAssertNotNil(css)
    }
}
