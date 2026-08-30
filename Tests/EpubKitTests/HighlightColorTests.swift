import XCTest
@testable import EpubKit

final class HighlightColorTests: XCTestCase {
    func testNextAdvancesThroughPalette() {
        XCTAssertEqual(HighlightColor.yellow.next, .green)
        XCTAssertEqual(HighlightColor.green.next, .blue)
        XCTAssertEqual(HighlightColor.blue.next, .pink)
        XCTAssertEqual(HighlightColor.pink.next, .purple)
        XCTAssertEqual(HighlightColor.purple.next, .underline)
    }

    func testNextWrapsFromUnderlineToYellow() {
        XCTAssertEqual(HighlightColor.underline.next, .yellow)
    }

    func testNextCyclesTheFullPalette() {
        var color = HighlightColor.yellow
        var seen: [HighlightColor] = [color]
        for _ in 1..<HighlightColor.allCases.count {
            color = color.next
            seen.append(color)
        }
        XCTAssertEqual(seen, Array(HighlightColor.allCases))
        XCTAssertEqual(color.next, .yellow)
    }
}
