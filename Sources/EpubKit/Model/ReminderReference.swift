import Foundation

/// A portable note link to a reminder. The reminder itself belongs to the book,
/// so deleting or undoing a note reference never deletes the research task.
public struct ReminderReference: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var range: NSRange

    public static func markdown(id: UUID, title: String) -> String {
        let label = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "[\(label)](kodi-reminder://\(id.uuidString))"
    }

    public static func parseLine(_ line: String) -> (UUID, String)? {
        let pattern = #"^\[((?:\\.|[^\]\\])*)\]\(kodi-reminder://([0-9A-Fa-f-]{36})\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)),
              let labelRange = Range(match.range(at: 1), in: line),
              let idRange = Range(match.range(at: 2), in: line),
              let id = UUID(uuidString: String(line[idRange])) else { return nil }
        let title = String(line[labelRange]).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        return (id, title)
    }

    public static func references(in markdown: String) -> [ReminderReference] {
        var result: [ReminderReference] = []
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
                result.append(ReminderReference(id: id, title: title,
                    range: NSRange(location: range.location, length: line.utf16.count)))
            }
            offset = NSMaxRange(range)
        }
        return result
    }

    public static func replacing(in markdown: String, transform: (ReminderReference) -> String) -> String {
        let value = NSMutableString(string: markdown)
        for reference in references(in: markdown).reversed() {
            value.replaceCharacters(in: reference.range, with: transform(reference))
        }
        return value as String
    }

    /// Convert links into portable checkboxes, resolving current titles and state
    /// when the caller has the book's canonical reminder records.
    public static func exporting(_ markdown: String, reminders: [ResearchReminder] = []) -> String {
        let byID = Dictionary(reminders.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return replacing(in: markdown) { reference in
            let reminder = byID[reference.id]
            let title = (reminder?.title ?? reference.title).components(separatedBy: .newlines).joined(separator: " ")
            let escaped = title.reduce(into: "") { output, character in
                if "\\`*_[]<>#|".contains(character) { output.append("\\") }
                output.append(character)
            }
            return "- [\(reminder?.isCompleted == true ? "x" : " ")] \(escaped)"
        }
    }

    public static func commandSuggestionRange(in markdown: String, selection: NSRange) -> NSRange? {
        commandRange(in: markdown, selection: selection, acceptsPrefix: true)
    }

    public static func commandRange(in markdown: String, selection: NSRange) -> NSRange? {
        commandRange(in: markdown, selection: selection, acceptsPrefix: false)
    }

    /// Text following either alias becomes the reminder title on Enter.
    public static func commandTitle(in command: String) -> String {
        for alias in ["/remind", "/task"] where command == alias || command.hasPrefix(alias + " ") || command.hasPrefix(alias + "\t") {
            return String(command.dropFirst(alias.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func commandRange(in markdown: String, selection: NSRange, acceptsPrefix: Bool) -> NSRange? {
        let ns = markdown as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let range = NSRange(location: line.location, length: selection.location - line.location)
        let command = ns.substring(with: range)
        let remainder = ns.substring(with: NSRange(location: selection.location, length: NSMaxRange(line) - selection.location))
        guard !command.isEmpty, remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["/remind", "/task"].contains(where: { alias in
                  (acceptsPrefix && alias.hasPrefix(command)) || command == alias
                      || command.hasPrefix(alias + " ") || command.hasPrefix(alias + "\t")
              }) else { return nil }
        let prefix = ns.substring(to: line.location)
        let probe = Self.markdown(id: UUID(), title: "probe")
        guard references(in: prefix + probe).last?.range.location == line.location else { return nil }
        return range
    }
}
