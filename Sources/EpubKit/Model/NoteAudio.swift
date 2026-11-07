import Foundation

/// A recording's small, portable metadata. Audio bytes live in AudioStore.
public struct NoteAudio: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var duration: TimeInterval
    public var createdAt: Date
    public var modifiedAt: Date
    public var waveform: [Float]
    /// Optional saved text for this attachment; generating it never changes the audio file.
    public var transcript: String?

    public init(id: UUID = UUID(), title: String, duration: TimeInterval = 0,
                createdAt: Date = Date(), modifiedAt: Date = Date(), waveform: [Float] = [], transcript: String? = nil) {
        self.id = id
        self.title = title
        self.duration = duration
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.waveform = waveform
        self.transcript = transcript
    }

    public var markdown: String { AudioReference.markdown(id: id, title: title) }
}

/// Recordings are standalone links outside fenced code, just like sketches.
public struct AudioReference: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var range: NSRange

    public static func markdown(id: UUID, title: String) -> String {
        let label = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "[\(label)](kodi-audio://\(id.uuidString))"
    }

    public static func parseLine(_ line: String) -> (UUID, String)? {
        let pattern = #"^\[((?:\\.|[^\]\\])*)\]\(kodi-audio://([0-9A-Fa-f-]{36})\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)),
              let labelRange = Range(match.range(at: 1), in: line),
              let idRange = Range(match.range(at: 2), in: line),
              let id = UUID(uuidString: String(line[idRange])) else { return nil }
        let title = String(line[labelRange]).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        return (id, title)
    }

    public static func references(in markdown: String) -> [AudioReference] {
        var result: [AudioReference] = []
        var fence: (Character, Int)?
        let ns = markdown as NSString
        var offset = 0
        while offset < ns.length {
            let range = ns.lineRange(for: NSRange(location: offset, length: 0))
            let line = ns.substring(with: range).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if let open = fence {
                        if open.0 == marker, count >= open.1,
                           trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (marker, count) }
                    offset = NSMaxRange(range)
                    continue
                }
            }
            if fence == nil, let (id, title) = parseLine(line) {
                result.append(AudioReference(id: id, title: title,
                    range: NSRange(location: range.location, length: line.utf16.count)))
            }
            offset = NSMaxRange(range)
        }
        return result
    }

    public static func replacing(in markdown: String, transform: (AudioReference) -> String) -> String {
        let value = NSMutableString(string: markdown)
        for reference in references(in: markdown).reversed() {
            value.replaceCharacters(in: reference.range, with: transform(reference))
        }
        return value as String
    }

    public static func commandRange(in markdown: String, selection: NSRange) -> NSRange? {
        commandRange(in: markdown, selection: selection, acceptsPrefix: false)
    }

    public static func commandSuggestionRange(in markdown: String, selection: NSRange) -> NSRange? {
        commandRange(in: markdown, selection: selection, acceptsPrefix: true)
    }

    private static func commandRange(in markdown: String, selection: NSRange, acceptsPrefix: Bool) -> NSRange? {
        let ns = markdown as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let start = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let range = NSRange(location: start, length: selection.location - start)
        let command = ns.substring(with: range)
        guard !command.isEmpty, acceptsPrefix ? "/audio".hasPrefix(command) : command == "/audio" else { return nil }
        let prefix = ns.substring(to: start)
        let probe = Self.markdown(id: UUID(), title: "probe")
        guard references(in: prefix + probe).last?.range.location == start else { return nil }
        return range
    }
}
