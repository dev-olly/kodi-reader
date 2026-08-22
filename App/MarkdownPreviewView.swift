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
                case let .table(header, rows, alignments):
                    tableView(header: header, rows: rows, alignments: alignments)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableView(
        header: [String],
        rows: [[String]],
        alignments: [NoteMarkdown.TableAlignment]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        inlineText(header[column])
                            .fontWeight(.semibold)
                            .gridColumnAlignment(horizontalAlignment(alignments, column: column))
                            .frame(maxWidth: .infinity, alignment: frameAlignment(alignments, column: column))
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            let cell = column < rows[row].count ? rows[row][column] : ""
                            inlineText(cell)
                                .frame(maxWidth: .infinity, alignment: frameAlignment(alignments, column: column))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func horizontalAlignment(
        _ alignments: [NoteMarkdown.TableAlignment],
        column: Int
    ) -> HorizontalAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(
        _ alignments: [NoteMarkdown.TableAlignment],
        column: Int
    ) -> Alignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
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
