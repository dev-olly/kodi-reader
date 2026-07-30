import Foundation
import SwiftUI

public enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case sepia
    case quiet
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .quiet: return "Quiet"
        case .dark: return "Dark"
        }
    }

    var textColor: String {
        switch self {
        case .light: return "#1a1a1a"
        case .sepia: return "#4a3c2c"
        case .quiet: return "#d8d6d2"
        case .dark: return "#c9c7c4"
        }
    }

    var backgroundColor: String {
        switch self {
        case .light: return "#ffffff"
        case .sepia: return "#faf0dc"
        case .quiet: return "#42403d"
        case .dark: return "#101010"
        }
    }

    var linkColor: String {
        switch self {
        case .light, .sepia: return "#1a6fd4"
        case .quiet, .dark: return "#6cb0f5"
        }
    }

    var selectionColor: String {
        isDark ? "rgba(120, 180, 255, 0.35)" : "rgba(88, 172, 250, 0.32)"
    }

    public var isDark: Bool {
        self == .dark || self == .quiet
    }

    /// Multiply darkens a highlight on light paper; on dark themes it would
    /// turn the tint to mud, so those lighten instead.
    var highlightBlendMode: String {
        isDark ? "screen" : "multiply"
    }

    /// SwiftUI equivalents, so the window chrome can match the page.
    public var uiBackground: Color {
        switch self {
        case .light: return Color(red: 1, green: 1, blue: 1)
        case .sepia: return Color(red: 0.98, green: 0.94, blue: 0.86)
        case .quiet: return Color(red: 0.26, green: 0.25, blue: 0.24)
        case .dark: return Color(red: 0.06, green: 0.06, blue: 0.06)
        }
    }

    public var uiForeground: Color {
        isDark ? Color.white.opacity(0.86) : Color.black.opacity(0.85)
    }

    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
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
    public var theme: ReaderTheme = .sepia
    public var font: ReaderFont = .serif
    public var fontSize: Double = 19
    public var lineHeight: Double = 1.6
    /// Fraction of the window width used as the side margin, per side.
    public var marginRatio: Double = 0.09
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
        return min(max(raw, 16), max(16, width * 0.35))
    }

    public var verticalMargin: Double {
        max(32, fontSize * 2.6)
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
