import ReaderUI
import SwiftUI

struct ReferenceReturnChip: View {
    let reader: ReaderController
    let theme: ReaderTheme

    var body: some View {
        HStack(spacing: 0) {
            Button(action: reader.returnFromReference) {
                Label("Back to reading", systemImage: "arrow.left")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .frame(height: 32)
                    .contentShape(.rect)
            }
            .help(reader.referenceReturnChapterTitle.map { "Return to \($0)" } ?? "Return to the original passage")
            .accessibilityIdentifier("return-from-reference")

            Rectangle().fill(theme.border).frame(width: 1, height: 14)

            Button(action: reader.dismissReferenceHistory) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .frame(width: 30, height: 32)
                    .contentShape(.rect)
            }
            .help("Dismiss return history")
            .accessibilityLabel("Dismiss return history")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .background(theme.surface, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border, lineWidth: 0.5) }
        .disabled(reader.isLoading || reader.isReferenceNavigationInProgress)
    }
}
