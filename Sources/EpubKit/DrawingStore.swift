import Foundation

/// Sidecar files for Excalidraw scenes, one JSON file per annotation.
///
/// Scenes live outside `library.json` because they can be large (especially
/// with embedded images) and the library file is decoded on every launch.
public final class DrawingStore: @unchecked Sendable {
    private struct PendingScene {
        var data: Data
        var bookID: String
        var work: DispatchWorkItem
    }

    private let rootDirectory: URL
    private let queue = DispatchQueue(label: "drawing-store", qos: .utility)
    private let lock = NSLock()
    private var pendingSaves: [UUID: PendingScene] = [:]

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var drawingsDirectory: URL {
        rootDirectory.appendingPathComponent("Drawings", isDirectory: true)
    }

    public func sceneURL(bookID: String, annotationID: UUID) -> URL {
        bookDirectory(for: bookID)
            .appendingPathComponent("\(annotationID.uuidString).excalidraw.json")
    }

