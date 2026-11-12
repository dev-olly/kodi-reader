import EpubKit
import SwiftUI

/// SwiftUI note preview: explicit blocks for lists/code, inline markdown for bold/italic/links.
struct NoteMarkdownPreview: View {
    let text: String
    var sketchPreview: ((UUID) -> Data?)? = nil
    var sketchModifiedAt: ((UUID) -> Date?)? = nil
    var onOpenSketch: ((UUID) -> Void)? = nil
    var onRenameSketch: ((UUID) -> Void)? = nil
    var audio: AudioNoteEditorContext? = nil
    var reminders: ReminderNoteEditorContext? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(NoteMarkdown.previewBlocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .reminder(id, title):
                    let reminder = reminders?.reminder(id)
                    ReminderInlineRow(title: reminder?.title ?? title,
                        isCompleted: reminder?.isCompleted ?? false, isAvailable: reminder != nil,
                        onToggle: reminders.map { context in { context.onToggle(id) } },
                        onEdit: reminders.map { context in { context.onEdit(id) } },
                        sourceTitle: reminder?.chapterTitle)
                case let .audio(id, title):
                    if let audio { audio.player(id: id, title: title, isDark: colorScheme == .dark) }
                    else { Label(title, systemImage: "waveform").foregroundStyle(.secondary) }
                case let .sketch(id, title):
                    SketchPreviewCard(
                        title: title,
                        preview: sketchPreview?(id),
                        modifiedAt: sketchModifiedAt?(id),
                        isDark: colorScheme == .dark,
                        onRename: onRenameSketch.map { rename in { rename(id) } }
                    ) { onOpenSketch?(id) }
                case let .paragraph(markdown):
                    if let audio, let id = AudioDraftReference.parse(markdown.trimmingCharacters(in: .whitespacesAndNewlines)), id == audio.draftID {
                        audio.recorder(isDark: colorScheme == .dark)
                    } else {
                        inlineText(markdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                case let .taskList(items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.checked ? Color.accentColor : .secondary)
                                inlineText(item.text)
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
        if markdown.contains("<u>") {
            Text(AttributedString(RichNoteCodec.decode(markdown, dark: colorScheme == .dark)))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
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
}

struct SketchPreviewCard: View {
    let title: String
    let preview: Data?
    var modifiedAt: Date? = nil
    var isDark: Bool = false
    var onRename: (() -> Void)? = nil
    let onOpen: () -> Void

    private var palette: SketchCardStyle.Palette { SketchCardStyle.palette(dark: isDark) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                ZStack(alignment: .bottomTrailing) {
                    Color(nsColor: palette.paper)
                    previewImage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(18)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: SketchCardStyle.color(0x405249)))
                        .padding(6)
                        .background(Color(nsColor: SketchCardStyle.color(0xE0E5D9)), in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .aspectRatio(SketchCardStyle.previewAspectRatio, contentMode: .fit)
                .frame(minHeight: SketchCardStyle.minimumPreviewHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open sketch: " + title)

            GeometryReader { geometry in
                footer(compact: geometry.size.width < 280)
                    .frame(width: geometry.size.width, height: SketchCardStyle.footerHeight)
            }
            .frame(height: SketchCardStyle.footerHeight)
            .background(Color(nsColor: palette.surface))
        }
        .frame(maxWidth: SketchCardStyle.maximumWidth)
        .clipShape(RoundedRectangle(cornerRadius: SketchCardStyle.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SketchCardStyle.cornerRadius, style: .continuous)
                .stroke(Color(nsColor: palette.border), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 11) {
            if !compact {
                Image(systemName: "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(nsColor: palette.actionInk))
                    .frame(width: 32, height: 36)
                    .background(Color(nsColor: palette.iconSurface), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: palette.ink))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(SketchCardStyle.editedLabel(modifiedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: palette.muted))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel("Open sketch: " + title)

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if !compact { Text("Open") }
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: palette.actionInk))
                .frame(width: compact ? 32 : 76, height: 32)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(nsColor: palette.actionBorder), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open sketch: " + title)

            Menu {
                Button("Open sketch", systemImage: "arrow.up.right", action: onOpen)
                if let onRename {
                    Button("Rename…", systemImage: "pencil", action: onRename)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(nsColor: palette.muted))
                    .frame(width: 26, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sketch options")
            .accessibilityLabel("Options for " + title)
        }
        .padding(.horizontal, compact ? 12 : 14)
    }

    @ViewBuilder
    private var previewImage: some View {
        if let preview, let image = NSImage(data: preview), image.size.width > 0, image.size.height > 0 {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Label("Preview unavailable · Open sketch", systemImage: "scribble")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: SketchCardStyle.color(0x63705F)))
        }
    }
}
