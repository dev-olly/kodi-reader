import Foundation

/// One-time copy of library data from the Folio / EpubReader locations into
/// the `com.olly.KodiReader` container.
///
/// A bundle-id change is a new sandbox, so the new app cannot see the old
/// container without the temporary home-relative read exception in the
/// entitlements. Copy, do not move; leave the old folder in place.
enum LegacyFolioMigration {
    static let markerName = ".migrated-from-folio"
    static let copiedItems = [
        "library.json",
        "Books",
        "Drawings",
        "Kokoro",
        "ai-models.json",
    ]

    static func run(into destination: URL) {
        copyFiles(into: destination)
    }

    private static func copyFiles(into destination: URL) {
        let fm = FileManager.default
        let marker = destination.appendingPathComponent(markerName)
        let library = destination.appendingPathComponent("library.json")
        guard !fm.fileExists(atPath: marker.path),
              !fm.fileExists(atPath: library.path)
        else { return }

        guard let source = firstExistingSource() else {
            writeMarker(marker)
            return
        }

        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in copiedItems {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path),
                  !fm.fileExists(atPath: to.path)
            else { continue }
            try? fm.copyItem(at: from, to: to)
        }
        writeMarker(marker)
    }

    private static func firstExistingSource() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                "Library/Containers/com.olly.Folio/Data/Library/Application Support/EpubReader",
                isDirectory: true
            ),
            home.appendingPathComponent(
                "Library/Application Support/EpubReader",
                isDirectory: true
            ),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func writeMarker(_ url: URL) {
        try? Data().write(to: url, options: .atomic)
    }
}
