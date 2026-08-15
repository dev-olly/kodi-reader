import EpubKit
import SwiftUI

/// SwiftUI note preview: explicit blocks for lists/code, inline markdown for bold/italic/links.
struct NoteMarkdownPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(NoteMarkdown.previewBlocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(markdown):
                    inlineText(markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .unorderedList(items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                inlineText(item)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case let .orderedList(items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                inlineText(item)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(code):
                    Text(code.isEmpty ? " " : code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineText(_ markdown: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(markdown)
                .textSelection(.enabled)
        }
    }
}
