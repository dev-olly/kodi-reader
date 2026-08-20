import XCTest
@testable import ReaderUI

final class ExcalidrawHostTests: XCTestCase {
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
