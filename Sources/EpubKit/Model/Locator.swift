import Foundation

/// A point inside a spine document.
///
/// This is a simplified EPUB CFI. `elementPath` is the chain of child indices
/// from the document body down to a text node, which stays valid because the
/// book's markup never changes, and unlike a scroll offset it survives font
/// size, window size, and theme changes.
public struct TextPosition: Codable, Hashable, Sendable {
    public var elementPath: [Int]
    public var offset: Int

    public init(elementPath: [Int], offset: Int) {
        self.elementPath = elementPath
        self.offset = offset
    }
}

/// A resolved position in the book, used for both reading progress and the
/// endpoints of an annotation.
public struct Locator: Codable, Hashable, Sendable {
    /// Index into `Publication.readingOrder`.
    public var spineIndex: Int
    public var start: TextPosition
    public var end: TextPosition?
    /// Fraction through the whole book, for the progress slider.
    public var totalProgression: Double?
    /// Snippet of the located text, used to verify or repair the anchor.
    public var text: String?

    public init(
        spineIndex: Int,
        start: TextPosition,
        end: TextPosition? = nil,
        totalProgression: Double? = nil,
        text: String? = nil
    ) {
        self.spineIndex = spineIndex
        self.start = start
        self.end = end
        self.totalProgression = totalProgression
        self.text = text
    }

    public static func startOfBook() -> Locator {
        Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0))
    }

    public var isRange: Bool { end != nil }
}

/// Colours offered when highlighting a selection, mirroring the familiar set.
public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case underline

    public var displayName: String {
        switch self {
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .underline: return "Underline"
        }
    }

    /// CSS colour applied by the reader stylesheet.
    public var cssValue: String {
        switch self {
        case .yellow: return "rgba(255, 214, 69, 0.45)"
        case .green: return "rgba(126, 217, 87, 0.40)"
        case .blue: return "rgba(88, 172, 250, 0.38)"
        case .pink: return "rgba(255, 138, 178, 0.40)"
        case .purple: return "rgba(191, 143, 249, 0.40)"
        case .underline: return "transparent"
        }
    }

    /// Next swatch in palette order, wrapping from underline back to yellow.
    public var next: HighlightColor {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .yellow }
        return all[(index + 1) % all.count]
    }
}
