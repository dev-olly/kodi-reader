import SwiftUI

/// The library shares the quiet green palette of Kodi's desktop library.
struct LibraryPalette {
    let isDark: Bool

    var background: Color { color(0xFAFAF7, 0x1C231F) }
    var sidebar: Color { color(0xF1F3ED, 0x18201A) }
    var surface: Color { color(0xFFFFFF, 0x232D26) }
    var soft: Color { color(0xF4F5F0, 0x29332B) }
    var ink: Color { color(0x27352C, 0xDDE4D9) }
    var muted: Color { color(0x81877B, 0x8F9B8D) }
    var line: Color { color(0xE5E8DF, 0x344035) }
    var accent: Color { color(0x47674C, 0xA8C096) }
    var accentSoft: Color { color(0xE3EBDD, 0x344832) }
    var progress: Color { color(0x8CAA79, 0xA8C096) }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let value = isDark ? dark : light
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct LibraryActionStyle: ButtonStyle {
    let palette: LibraryPalette
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 39)
            .foregroundStyle(prominent ? palette.background : palette.muted)
            .background(prominent ? palette.accent : Color.clear, in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(.rect(cornerRadius: 8))
    }
}
