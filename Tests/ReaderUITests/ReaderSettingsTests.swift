import XCTest
@testable import ReaderUI

final class ReaderSettingsTests: XCTestCase {
    func testNoteEditorPlacementDefaultsWhenMissing() throws {
        let json = """
        {
          "theme": "dark",
          "font": "serif",
          "fontSize": 19,
          "lineHeight": 1.68,
          "marginRatio": 0.11,
          "justified": true,
          "hyphenated": true,
          "twoPageSpread": true,
          "animatePageTurns": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ReaderSettings.self, from: json)
        XCTAssertEqual(settings.noteEditorPlacement, .sheet)
        XCTAssertEqual(settings.theme, .dark)
    }

    func testNoteEditorPlacementRoundTrip() throws {
        var settings = ReaderSettings()
        settings.noteEditorPlacement = .sidebar
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: data)
        XCTAssertEqual(decoded.noteEditorPlacement, .sidebar)
    }
}
