import SwiftUI

/// A short-delay hover tooltip that replaces the slow system `.help()` delay.
struct QuickHelpModifier: ViewModifier {
    let text: String
    var delay: TimeInterval = 0.25

    @State private var isVisible = false
    @State private var showWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isVisible {
                    Text(text)
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
                        .zIndex(1000)
                }
            }
            .onHover { hovering in
                showWork?.cancel()
                showWork = nil

                if hovering {
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.1)) {
                            isVisible = true
                        }
                    }
                    showWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                } else {
                    withAnimation(.easeOut(duration: 0.08)) {
                        isVisible = false
                    }
                }
            }
            .accessibilityHint(text)
    }
}

extension View {
    /// Shows `text` under the view after a short hover delay (default 0.25s).
    func quickHelp(_ text: String, delay: TimeInterval = 0.25) -> some View {
        modifier(QuickHelpModifier(text: text, delay: delay))
    }
}
