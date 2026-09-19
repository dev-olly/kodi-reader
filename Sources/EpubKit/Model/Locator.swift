import Foundation

public enum DocumentKind: String, Codable, Sendable, Hashable {
    case epub
    case pdf
}

/// A character range on one PDF page. PDFKit exposes page-local character
/// offsets, which remain stable because Kodi reads from its immutable import.
public struct PDFTextRange: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var location: Int
    public var length: Int

    public init(pageIndex: Int, location: Int, length: Int) {
        self.pageIndex = pageIndex
        self.location = location
        self.length = length
    }
}

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
    /// Missing from legacy JSON, where every locator was necessarily EPUB.
    public var kind: DocumentKind
    /// Index into `Publication.readingOrder`.
    public var spineIndex: Int
    public var start: TextPosition
    public var end: TextPosition?
    /// Fraction through the whole book, for the progress slider.
    public var totalProgression: Double?
    /// Snippet of the located text, used to verify or repair the anchor.
    public var text: String?
    /// Populated for PDF text selections. Reading positions and page
    /// bookmarks need only `spineIndex`, which is the zero-based page index.
    public var pdfRanges: [PDFTextRange]?

    public init(
        spineIndex: Int,
        start: TextPosition,
        end: TextPosition? = nil,
        totalProgression: Double? = nil,
        text: String? = nil,
        kind: DocumentKind = .epub,
        pdfRanges: [PDFTextRange]? = nil
    ) {
        self.kind = kind
        self.spineIndex = spineIndex
        self.start = start
        self.end = end
        self.totalProgression = totalProgression
        self.text = text
        self.pdfRanges = pdfRanges
    }

    public static func startOfBook() -> Locator {
        Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0))
    }

    public static func pdfPage(
        _ pageIndex: Int,
        ranges: [PDFTextRange] = [],
        totalProgression: Double? = nil,
        text: String? = nil
    ) -> Locator {
        let first = ranges.first
        return Locator(
            spineIndex: pageIndex,
            start: TextPosition(elementPath: [], offset: first?.location ?? 0),
            end: first.map { TextPosition(elementPath: [], offset: $0.location + $0.length) },
            totalProgression: totalProgression,
            text: text,
            kind: .pdf,
            pdfRanges: ranges.isEmpty ? nil : ranges
        )
    }

    public var isRange: Bool { end != nil }

    private enum CodingKeys: String, CodingKey {
        case kind, spineIndex, start, end, totalProgression, text, pdfRanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .epub
        spineIndex = try container.decode(Int.self, forKey: .spineIndex)
        start = try container.decode(TextPosition.self, forKey: .start)
        end = try container.decodeIfPresent(TextPosition.self, forKey: .end)
        totalProgression = try container.decodeIfPresent(Double.self, forKey: .totalProgression)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        pdfRanges = try container.decodeIfPresent([PDFTextRange].self, forKey: .pdfRanges)
    }
}

/// Colours offered when highlighting a selection, mirroring the familiar set.
public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case underline

    /// Background-fill colours. Notes always use one of these so their quoted
    /// passage remains visibly highlighted rather than relying on a marker dot.
    public static let fillCases: [HighlightColor] = [.yellow, .green, .blue, .pink, .purple]

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
        // The reader stylesheet suppresses the rectangle fill for this style
        // and uses this value for the underline itself.
        case .underline: return "rgba(229, 165, 10, 0.95)"
        }
    }

    /// Next swatch in palette order, wrapping from underline back to yellow.
    public var next: HighlightColor {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .yellow }
        return all[(index + 1) % all.count]
    }

    /// Next background-fill colour, skipping the underline-only style.
    public var nextFill: HighlightColor {
        guard let index = Self.fillCases.firstIndex(of: self) else { return .yellow }
        return Self.fillCases[(index + 1) % Self.fillCases.count]
    }
}
