import AppKit
import SwiftUI

private struct PaletteFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TestPalette: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            palette(width: 500, height: 44, name: "wide")
            palette(width: 260, height: 82, name: "compact")
        }
    }

    private func palette(width: CGFloat, height: CGFloat, name: String) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PaletteFrameKey.self,
                        value: [name: geometry.frame(in: .named("surface"))]
                    )
                }
            }
    }
}

@main
struct HighlightPopoverLayoutTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        check(
            surface: CGSize(width: 800, height: 600),
            anchor: CGRect(x: 740, y: 550, width: 40, height: 20),
            expected: CGRect(x: 288, y: 496, width: 500, height: 44),
            variant: "wide"
        )
        check(
            surface: CGSize(width: 800, height: 600),
            anchor: CGRect(x: 0, y: 0, width: 20, height: 20),
            expected: CGRect(x: 12, y: 30, width: 500, height: 44),
            variant: "wide"
        )
        check(
            surface: CGSize(width: 320, height: 400),
            anchor: CGRect(x: 280, y: 350, width: 20, height: 20),
            expected: CGRect(x: 48, y: 258, width: 260, height: 82),
            variant: "compact"
        )
        check(
            surface: CGSize(width: 800, height: 100),
            anchor: CGRect(x: 390, y: 35, width: 20, height: 30),
            expected: CGRect(x: 150, y: 44, width: 500, height: 44),
            variant: "wide"
        )
        check(
            surface: CGSize(width: 860, height: 690),
            anchor: CGRect(x: 740, y: 550, width: 40, height: 20),
            expected: CGRect(x: 328, y: 526, width: 500, height: 44),
            variant: "wide",
            padding: EdgeInsets(top: 30, leading: 40, bottom: 60, trailing: 20)
        )
        print("Highlight palette stays within viewport edges and chooses its compact layout on narrow surfaces.")
    }

    @MainActor
    private static func check(
        surface: CGSize, anchor: CGRect, expected: CGRect, variant: String,
        padding: EdgeInsets = EdgeInsets()
    ) {
        var measured: [String: CGRect] = [:]
        let content = HighlightPopoverLayout(anchor: anchor) {
            TestPalette()
        }
        .padding(padding)
        .coordinateSpace(name: "surface")
        .onPreferenceChange(PaletteFrameKey.self) { measured = $0 }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: surface),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: surface)
        window.orderBack(nil)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if let frame = measured[variant], matches(frame, expected) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(measured.count == 1, "Expected only the visible palette, got \(measured)")
        let actual = measured[variant]
        precondition(actual.map { matches($0, expected) } == true,
                     "For \(surface) and anchor \(anchor), expected \(variant) \(expected), got \(measured)")
        window.contentView = nil
        window.orderOut(nil)
    }

    private static func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) < 0.5 && abs(actual.minY - expected.minY) < 0.5
            && abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5
    }
}
