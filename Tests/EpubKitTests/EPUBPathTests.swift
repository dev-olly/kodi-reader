import XCTest
@testable import EpubKit

final class EPUBPathTests: XCTestCase {
    func testResolvesSiblingHref() {
        XCTAssertEqual(
            EPUBPath.resolve(href: "chapter1.xhtml", relativeTo: "OEBPS/content.opf"),
            "OEBPS/chapter1.xhtml"
        )
    }

    func testResolvesParentTraversal() {
        XCTAssertEqual(
            EPUBPath.resolve(href: "../images/cover.jpg", relativeTo: "OEBPS/text/content.opf"),
            "OEBPS/images/cover.jpg"
        )
    }

    func testResolvesRootRelativeHref() {
        XCTAssertEqual(
            EPUBPath.resolve(href: "/OEBPS/a.xhtml", relativeTo: "OEBPS/content.opf"),
            "OEBPS/a.xhtml"
        )
    }

    func testStripsFragmentWhenResolving() {
        XCTAssertEqual(
            EPUBPath.resolve(href: "chapter1.xhtml#section-2", relativeTo: "OEBPS/toc.ncx"),
            "OEBPS/chapter1.xhtml"
        )
    }

    func testDecodesPercentEncoding() {
        XCTAssertEqual(
            EPUBPath.resolve(href: "my%20chapter.xhtml", relativeTo: "OEBPS/content.opf"),
            "OEBPS/my chapter.xhtml"
        )
    }

    func testHandlesPackageAtArchiveRoot() {
        XCTAssertEqual(
            EPUBPath.resolve(href: "chapter1.xhtml", relativeTo: "content.opf"),
            "chapter1.xhtml"
        )
    }

    func testSplitFragment() {
        let withFragment = EPUBPath.splitFragment("a.xhtml#frag")
        XCTAssertEqual(withFragment.path, "a.xhtml")
        XCTAssertEqual(withFragment.fragment, "frag")

        let withoutFragment = EPUBPath.splitFragment("a.xhtml")
        XCTAssertEqual(withoutFragment.path, "a.xhtml")
        XCTAssertNil(withoutFragment.fragment)

        // A trailing hash carries no target.
        XCTAssertNil(EPUBPath.splitFragment("a.xhtml#").fragment)
    }

    func testMimeTypes() {
        XCTAssertEqual(EPUBPath.mimeType(forPath: "a/b.xhtml"), "application/xhtml+xml")
        XCTAssertEqual(EPUBPath.mimeType(forPath: "a/B.CSS"), "text/css")
        XCTAssertEqual(EPUBPath.mimeType(forPath: "cover.jpeg"), "image/jpeg")
        XCTAssertEqual(EPUBPath.mimeType(forPath: "font.woff2"), "font/woff2")
        XCTAssertEqual(EPUBPath.mimeType(forPath: "mystery.bin"), "application/octet-stream")
    }
}
