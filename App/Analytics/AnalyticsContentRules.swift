import CryptoKit
import EpubKit
import Foundation

/// Local comparisons only. Content, fingerprints, and document identifiers never
/// become event properties or leave the Mac.
enum AnalyticsContentRules {
    static func textNote(_ markdown: String) -> String {
        let withoutSketches = SketchReference.replacing(in: markdown) { _ in "" }
        let withoutAudio = AudioReference.replacing(in: withoutSketches) { _ in "" }
        let withoutReminders = ReminderReference.replacing(in: withoutAudio) { _ in "" }
        return withoutReminders.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func drawingSignature(_ scene: Data?) -> Data? {
        guard let scene,
              let object = try? JSONSerialization.jsonObject(with: scene) as? [String: Any],
              let elements = object["elements"] as? [[String: Any]] else { return nil }
        // App state contains viewport, zoom, selection, theme and tool changes.
        // Only the visible elements and their referenced image content matter.
        let visible = elements.filter { ($0["isDeleted"] as? Bool) != true }.map { element in
            element.filter { !["version", "versionNonce", "updated", "lastCommittedPoint"].contains($0.key) }
        }
        let fileIDs = Set(visible.compactMap { $0["fileId"] as? String })
        let files = (object["files"] as? [String: [String: Any]] ?? [:]).filter { fileIDs.contains($0.key) }.mapValues { file in
            file.filter { ["dataURL", "mimeType"].contains($0.key) }
        }
        guard let canonical = try? JSONSerialization.data(withJSONObject: ["elements": visible, "files": files], options: [.sortedKeys]) else { return nil }
        return Data(SHA256.hash(data: canonical))
    }
}
