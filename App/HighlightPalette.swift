import AppKit
import EpubKit
import ReaderUI
import SwiftUI

/// Actions shown next to a fresh selection or an existing highlight.
struct HighlightPalette: View {
    let onPick: (HighlightColor) -> Void
    let onAddNote: () -> Void
    let onAskAI: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void
    var currentColor: HighlightColor? = nil
    var hasNote = false
    var hasAttachedContent = false
    var onDelete: (() -> Void)? = nil
    var onListenFromHere: (() -> Void)? = nil
    var onAddReminder: (() -> Void)? = nil

    @State private var copied = false
    @State private var copyGeneration = 0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            palette(compact: false)
            palette(compact: true)
        }
        .shadow(radius: 8, y: 3)
    }

    private func palette(compact: Bool) -> some View {
        PointerCursorContainer {
            Group {
                if compact {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            colorButtons
                            Spacer(minLength: 10)
                            dismissButton
                        }
                        Divider()
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            actionButtons
                            removeButton
                        }
                    }
                    .frame(width: 280)
                } else {
                    HStack(spacing: 10) {
                        colorButtons
                        Divider().frame(height: 20)
                        actionButtons
                        if onDelete != nil {
                            Divider().frame(height: 20)
                            removeButton
                        }
                        Divider().frame(height: 20)
                        dismissButton
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, copied ? 26 : 0)
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .fixedSize()
    }

    private var colorButtons: some View {
        ForEach(HighlightColor.allCases, id: \.self) { color in
            Button { onPick(color) } label: {
                swatch(for: color)
                    .padding(3)
                    .frame(minHeight: 32)
                    .contentShape(.rect)
                    .overlay {
                        if currentColor == color {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.primary, lineWidth: 1.5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(color.displayName)
            .accessibilityLabel(color.displayName + " highlight")
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: onAddNote) {
            Label(hasNote ? "Edit Note" : "Note", systemImage: "text.badge.plus")
                .modifier(PaletteActionTarget())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("highlight-note")
        .help(currentColor == nil ? "Highlight and add a note" : "Open note for this highlight")

        if let onAddReminder {
            Button(action: onAddReminder) {
                Label("Remind", systemImage: "bell.badge")
                    .modifier(PaletteActionTarget())
            }
            .buttonStyle(.plain)
            .help("Add a reminder to research this later")
            .accessibilityLabel("Add reminder")
        }

        Button(action: onAskAI) {
            Label("Ask AI", systemImage: "sparkles")
                .modifier(PaletteActionTarget())
        }
        .buttonStyle(.plain)
        .help(currentColor == nil ? "Ask AI about this selection" : "Ask AI about this highlight")

        if let onListenFromHere {
            Button(action: onListenFromHere) {
                Label("Listen from Here", systemImage: "speaker.wave.2")
                    .modifier(PaletteActionTarget())
            }
            .buttonStyle(.plain)
            .help("Listen from the start of this passage")
        }

        Button(action: copyTapped) {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .modifier(PaletteActionTarget())
                .foregroundStyle(copied ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied to clipboard" : currentColor == nil ? "Copy selected text" : "Copy highlighted text")
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .fixedSize()
                    .offset(y: 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var removeButton: some View {
        if let onDelete {
            Button(action: onDelete) {
                Label(hasAttachedContent ? "Delete" : "Clear Highlight",
                      systemImage: hasAttachedContent ? "trash" : "eraser")
                    .modifier(PaletteActionTarget())
            }
            .buttonStyle(.plain)
            .help(hasAttachedContent ? "Delete highlight and its note or drawing" : "Clear this highlight")
            .accessibilityLabel(hasAttachedContent ? "Delete highlight and its note or drawing" : "Clear Highlight")
            .accessibilityIdentifier("remove-highlight")
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss highlight toolbar")
    }

    private func copyTapped() {
        onCopy()
        withAnimation(.easeInOut(duration: 0.15)) {
            copied = true
        }
        copyGeneration += 1
        let generation = copyGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if generation == copyGeneration {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copied = false
                }
            }
        }
    }

    @ViewBuilder
    private func swatch(for color: HighlightColor) -> some View {
        if color == .underline {
            VStack(spacing: 2) {
                Text("A").font(.system(size: 12, weight: .semibold))
                Rectangle().frame(height: 2)
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(.primary)
        } else {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(.black.opacity(0.12)) }
        }
    }
}

/// The full label rectangle responds, including space around and between glyphs.
private struct PaletteActionTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 4)
            .frame(minHeight: 32)
            .contentShape(.rect)
    }
}

/// Hosts the palette in AppKit so a pointing-hand cursor wins over WKWebView’s I-beam.
private struct PointerCursorContainer<Content: View>: NSViewRepresentable {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> PointerCursorHost {
        let host = PointerCursorHost()
        host.clipsToBounds = false
        let hosting = PointerCursorHostingView(rootView: content)
        hosting.clipsToBounds = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        context.coordinator.hosting = hosting
        return host
    }

    func updateNSView(_ nsView: PointerCursorHost, context: Context) {
        context.coordinator.hosting?.rootView = content
        nsView.invalidateIntrinsicContentSize()
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PointerCursorHost, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hosting: PointerCursorHostingView<Content>?
    }
}

/// Skips `super.resetCursorRects()` so descendant `Text` views cannot install an I-beam.
private final class PointerCursorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class PointerCursorHost: NSView {
    private var trackingArea: NSTrackingArea?
    private var isInside = false

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let hosting = subviews.first else { return .zero }
        return hosting.fittingSize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        NSCursor.pointingHand.set()
    }

    // WKWebView underneath resets the I-beam on every move, so reassert the
    // pointing hand each time while the pointer is over the bar.
    override func mouseMoved(with event: NSEvent) {
        guard isInside else { return }
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isInside = false }
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}


extension HighlightColor {
    var swiftUIColor: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.27)
        case .green: return Color(red: 0.49, green: 0.85, blue: 0.34)
        case .blue: return Color(red: 0.35, green: 0.67, blue: 0.98)
        case .pink: return Color(red: 1.0, green: 0.54, blue: 0.70)
        case .purple: return Color(red: 0.75, green: 0.56, blue: 0.98)
        case .underline: return Color(red: 0.90, green: 0.65, blue: 0.04)
        }
    }
}
