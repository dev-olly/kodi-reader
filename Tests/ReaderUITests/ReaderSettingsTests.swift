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
        XCTAssertEqual(settings.readAloudVoiceID, "af_heart")
        XCTAssertEqual(settings.readAloudRate, 1.0)
    }

    func testReadAloudSettingsRoundTrip() throws {
        var settings = ReaderSettings()
        settings.readAloudVoiceID = "bf_emma"
        settings.readAloudRate = 1.25
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: data)
        XCTAssertEqual(decoded.readAloudVoiceID, "bf_emma")
        XCTAssertEqual(decoded.readAloudRate, 1.25, accuracy: 0.001)
    }

    func testNoteEditorPlacementRoundTrip() throws {
        var settings = ReaderSettings()
        settings.noteEditorPlacement = .sidebar
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: data)
        XCTAssertEqual(decoded.noteEditorPlacement, .sidebar)
    }
}
