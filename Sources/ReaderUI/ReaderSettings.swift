import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

public enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Soft off-white on charcoal in dark mode — readable without harsh glare.
    var textColor: String {
        switch self {
        case .light: return "#1a1a1a"
        case .dark: return "#dcdcdc"
        }
    }

    var backgroundColor: String {
        switch self {
        case .light: return "#ffffff"
        case .dark: return "#1c1c1e"
        }
    }

    /// Elevated panels / EPUB callouts remapped in dark mode.
    var surfaceColor: String {
        switch self {
        case .light: return "#f2f2f2"
        case .dark: return "#2c2c2e"
        }
    }

    var linkColor: String {
        switch self {
        case .light: return "#1a6fd4"
        case .dark: return "#6cb0f5"
        }
    }

    var selectionColor: String {
        isDark ? "rgba(120, 180, 255, 0.35)" : "rgba(88, 172, 250, 0.32)"
    }

    public var isDark: Bool {
        self == .dark
    }

    /// Multiply darkens a highlight on light paper; on dark themes it would
    /// turn the tint to mud, so those lighten instead.
    var highlightBlendMode: String {
        isDark ? "screen" : "multiply"
    }

    /// SwiftUI equivalents, so the window chrome can match the page.
    public var uiBackground: Color {
        switch self {
        case .light: return .white
        case .dark: return Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
        }
    }

    #if os(macOS)
    /// AppKit / WKWebView under-page color — must match the page to avoid white flashes.
    public var nsBackgroundColor: NSColor {
        switch self {
        case .light:
            return .white
        case .dark:
            return NSColor(calibratedRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
        }
    }
    #endif

    public var uiForeground: Color {
        isDark ? Color(red: 220 / 255, green: 220 / 255, blue: 220 / 255) : Color.black.opacity(0.85)
    }

    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    /// Maps legacy persisted values (`sepia`, `quiet`) onto the two themes.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.dark.rawValue, "quiet":
            self = .dark
        default:
            self = .light
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ReaderFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case serif
    case georgia
    case palatino
    case charter
    case sansSerif

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "New York"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .sansSerif: return "Helvetica"
        }
    }

    var cssStack: String {
        switch self {
        case .system:
            return "-apple-system, \"SF Pro Text\", system-ui, sans-serif"
        case .serif:
            return "\"New York\", \"Iowan Old Style\", Georgia, serif"
        case .georgia:
            return "Georgia, \"Times New Roman\", serif"
        case .palatino:
            return "\"Palatino\", \"Palatino Linotype\", \"Book Antiqua\", serif"
        case .charter:
            return "\"Charter\", \"Bitstream Charter\", Georgia, serif"
        case .sansSerif:
            return "\"Helvetica Neue\", Helvetica, Arial, sans-serif"
        }
    }

    public var isSerif: Bool {
        self != .system && self != .sansSerif
    }
}

/// Everything the reader lets you change about how a page looks.
public struct ReaderSettings: Codable, Equatable, Sendable {
    public var theme: ReaderTheme = .light
    public var font: ReaderFont = .serif
    public var fontSize: Double = 19
    public var lineHeight: Double = 1.68
    /// Fraction of the window width used as the side margin, per side.
    public var marginRatio: Double = 0.11
    public var justified: Bool = true
    public var hyphenated: Bool = true
    public var twoPageSpread: Bool = true
    public var animatePageTurns: Bool = true

    public init() {}

    public static let fontSizeRange: ClosedRange<Double> = 12...32
    public static let lineHeightRange: ClosedRange<Double> = 1.2...2.4
    public static let marginRange: ClosedRange<Double> = 0.03...0.20

    /// Horizontal margin in points for a given window width, clamped so the
    /// text column stays readable at both extremes.
    public func horizontalMargin(forWidth width: Double) -> Double {
        let raw = width * marginRatio
        return min(max(raw, 48), max(48, width * 0.35))
    }

    public var verticalMargin: Double {
        max(56, fontSize * 4.0)
    }

    /// CSS custom properties handed to the injected stylesheet.
    public func cssVariables(forWidth width: Double) -> [String: String] {
        [
            "--font-size": "\(fontSize)px",
            "--line-height": "\(lineHeight)",
            "--font-family": font.cssStack,
            "--text-align": justified ? "justify" : "start",
            "--hyphens": hyphenated ? "auto" : "manual",
            "--color-text": theme.textColor,
            "--color-background": theme.backgroundColor,
            "--color-surface": theme.surfaceColor,
            "--color-link": theme.linkColor,
            "--color-selection": theme.selectionColor,
            "--highlight-blend-mode": theme.highlightBlendMode,
            "--page-margin-x": "\(horizontalMargin(forWidth: width))px",
            "--page-margin-y": "\(verticalMargin)px",
        ]
    }

    /// Options object passed to `__reader.start` and `__reader.configure`.
    public func runtimeOptions(forWidth width: Double) -> [String: Any] {
        [
            "marginX": horizontalMargin(forWidth: width),
            "marginY": verticalMargin,
            "twoPageSpread": twoPageSpread,
            "animatePageTurns": animatePageTurns,
            "variables": cssVariables(forWidth: width),
        ]
    }
}
