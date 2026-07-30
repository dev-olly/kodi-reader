import XCTest
@testable import EpubKit

/// Locates the Project Gutenberg books in `Samples/`.
///
/// They are downloaded by `Scripts/fetch-samples.sh` rather than committed, so
/// tests that need them skip when they are absent.
enum SampleBooks {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EpubKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Samples")
    }

    /// EPUB 3 with a navigation document.
    static let frankenstein = "frankenstein.epub"
    /// EPUB 3 with a navigation document, small.
    static let alice = "alice.epub"
    /// NCX-only table of contents.
    static let prideAndPrejudice = "pride-and-prejudice.epub"

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Opens a sample, skipping the test when the download step has not run.
    static func open(_ name: String) throws -> EPUBBook {
        let url = self.url(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing \(name). Run Scripts/fetch-samples.sh to download it.")
        }
        return try EPUBBook(fileURL: url)
    }
}
