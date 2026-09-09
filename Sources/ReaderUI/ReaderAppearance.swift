import SwiftUI

/// Shared native and web palette. Keep page backgrounds identical across renderers.
public extension ReaderTheme {
    var inkHex: String { isDark ? "#E9EEE9" : "#192A24" }
    var pageHex: String { isDark ? "#202522" : "#FFFFFF" }
    var surfaceHex: String { isDark ? "#282E2A" : "#F0F5F1" }
    var accentHex: String { isDark ? "#ACD5B4" : "#245744" }
    var mutedHex: String { isDark ? "#AFBEB4" : "#59675F" }
    var borderHex: String { isDark ? "#46544B" : "#D9E2DC" }
    var accent: Color { Color(readerHex: accentHex) }
    var surface: Color { Color(readerHex: surfaceHex) }
    var muted: Color { Color(readerHex: mutedHex) }
    var border: Color { Color(readerHex: borderHex) }
}

extension Color {
    init(readerHex: String) {
        let value = UInt32(readerHex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255, opacity: 1)
    }
}
