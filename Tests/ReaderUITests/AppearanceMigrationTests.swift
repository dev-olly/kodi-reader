import XCTest
import EpubKit
@testable import ReaderUI

final class AppearanceMigrationTests: XCTestCase {
    func testMigrationBacksUpAndPreservesLaterChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: url)
        var original = ReaderSettings()
        original.theme = .dark
        original.fontSize = 27
        original.lineHeight = 1.3
        original.font = .sansSerif
        original.justified = true
        original.twoPageSpread = false
        original.readAloudRate = 1.5
        original.readAloudVoiceID = "bf_emma"
        original.noteEditorPlacement = .sheet
        store.saveSettings(original)
        let migrated = try store.migrateAppearanceSettings(defaultSettings: ReaderSettings()) {
            $0.applyAppearanceDefaults()
        }
        XCTAssertEqual(store.settingsBeforeAppearanceMigration(ReaderSettings.self), original)
        XCTAssertEqual(migrated.font, .serif)
        XCTAssertEqual(migrated.fontSize, 19)
        XCTAssertEqual(migrated.lineHeight, 1.8)
        XCTAssertFalse(migrated.justified)
        XCTAssertEqual(migrated.noteEditorPlacement, .sidebar)
        XCTAssertEqual(migrated.theme, .dark)
        XCTAssertFalse(migrated.twoPageSpread)
        XCTAssertEqual(migrated.readAloudRate, 1.5)
        XCTAssertEqual(migrated.readAloudVoiceID, "bf_emma")
        var changed = migrated
        changed.fontSize = 24
        changed.noteEditorPlacement = .sheet
        store.saveSettings(changed)
        store.flush()
        let reopened = LibraryStore(fileURL: url)
        let second = try reopened.migrateAppearanceSettings(defaultSettings: ReaderSettings()) {
            XCTFail("Migration must not run again")
            $0.applyAppearanceDefaults()
        }
        XCTAssertEqual(second, changed)
        XCTAssertEqual(reopened.settingsBeforeAppearanceMigration(ReaderSettings.self), original)
    }

    func testFreshStoreAndLegacyDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let settings = try store.migrateAppearanceSettings(defaultSettings: ReaderSettings()) {
            $0.applyAppearanceDefaults()
        }
        XCTAssertEqual(settings.lineHeight, 1.8)
        XCTAssertNil(store.settingsBeforeAppearanceMigration(ReaderSettings.self))
        var legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data("{}".utf8))
        legacy.applyAppearanceDefaults()
        XCTAssertEqual(legacy, settings)
    }

    func testNativeAndWebPaletteUseSameValues() {
        for theme in ReaderTheme.allCases {
            var settings = ReaderSettings()
            settings.theme = theme
            let css = settings.cssVariables(forWidth: 1100)
            XCTAssertEqual(css["--color-background"], theme.pageHex)
            XCTAssertEqual(css["--color-text"], theme.inkHex)
            XCTAssertEqual(css["--color-surface"], theme.surfaceHex)
            XCTAssertEqual(css["--color-link"], theme.accentHex)
        }
    }
}
