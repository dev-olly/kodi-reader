import AppKit
import EpubKit
import ReaderUI
import SwiftUI

/// Cover-first library presentation, with the same document actions in either layout.
struct LibraryBookCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let record: BookRecord
    var isList = false
    var onDelete: (BookRecord) -> Void
    @State private var isHovering = false

    private var palette: LibraryPalette { LibraryPalette(isDark: model.settings.theme.isDark) }
    private var progress: Double { min(1, max(0, record.progress.isFinite ? record.progress : 0)) }
    private var percent: Int { Int(progress * 100) }
    private var isDownloading: Bool { model.sync.status.downloads[record.id] != nil }

    var body: some View {
        Group {
            if isList { listCard } else { gridCard }
        }
        .foregroundStyle(palette.ink)
        .contextMenu { documentActions }
    }

    private var gridCard: some View {
        ZStack(alignment: .topTrailing) {
            Button { model.reopen(record) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    cover(width: 172, height: 246)
                        .offset(y: isHovering && !reduceMotion ? -3 : 0)
                        .padding(.bottom, 13)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(record.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .padding(.trailing, 23)
                            .padding(.bottom, 6)
                        Text(record.author.isEmpty ? "Unknown author" : record.author)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .padding(.bottom, 12)
                        readingProgress
                        availability
                    }
                    .padding(.horizontal, 3)
                }
                .frame(width: 172, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
            .accessibilityLabel("Read \(record.title), \(record.author)")
            .accessibilityValue("\(percent) percent read")
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.18), value: isHovering)

            actionsMenu
                .padding(.top, 255)
        }
        .frame(width: 172, alignment: .topLeading)
    }

    private var listCard: some View {
        HStack(spacing: 16) {
            Button { model.reopen(record) } label: {
                HStack(spacing: 20) {
                    cover(width: 51, height: 73)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(record.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(record.author.isEmpty ? "Unknown author" : record.author)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                        readingProgress.frame(maxWidth: 280)
                        availability
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
            .accessibilityLabel("Read \(record.title), \(record.author)")
            .accessibilityValue("\(percent) percent read")
            actionsMenu
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private func cover(width: CGFloat, height: CGFloat) -> some View {
        LibraryBookCover(record: record, url: model.importedURL(for: record),
                         width: width, height: height, palette: palette)
    }

    private var readingProgress: some View {
        HStack(spacing: 10) {
            GeometryReader { geometry in
                Capsule().fill(palette.line)
                    .overlay(alignment: .leading) {
                        Capsule().fill(palette.progress)
                            .frame(width: geometry.size.width * progress)
                    }
            }
            .frame(height: 3)
            Text(progress > 0.001 ? "\(percent)%" : "Unread")
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(palette.muted)
                .fixedSize()
                .frame(minWidth: 26, alignment: .leading)
        }
    }

    @ViewBuilder
    private var availability: some View {
        if let downloading = model.sync.status.downloads[record.id] {
            ProgressView("Downloading…", value: downloading)
                .font(.system(size: 9))
                .padding(.top, 9)
        } else if model.importedURL(for: record) == nil {
            Label(record.cloudFile != nil && model.sync.preferences.mode == .booksAndNotes
                  ? "In \(model.sync.provider.title)" : "Locate file to read",
                  systemImage: model.sync.provider == .iCloud ? "icloud" : "externaldrive")
                .font(.system(size: 9))
                .foregroundStyle(palette.muted)
                .padding(.top, 9)
        } else if model.sync.isLocalRecovery(record.id) {
            Text("Recovered locally")
                .font(.system(size: 9))
                .foregroundStyle(palette.muted)
                .padding(.top, 9)
        } else if record.cloudIdentity == nil {
            Text("Locate file to enable sync")
                .font(.system(size: 9))
                .foregroundStyle(palette.muted)
                .padding(.top, 9)
        }
    }

    private var actionsMenu: some View {
        Menu { documentActions } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(record.title)")
        .help("Actions for \(record.title)")
    }

    @ViewBuilder
    private var documentActions: some View {
        Button("Open Document") { model.reopen(record) }.disabled(isDownloading)
        Button("Rename…") { model.documentToRename = record }
        if record.sourceURL != nil {
            Button("Open Original in Browser") { model.openOriginalInBrowser(record) }
        }
        if record.cloudFile != nil {
            if model.importedURL(for: record) == nil {
                Button("Download for Offline Reading") { model.downloadForOffline(record) }
                    .disabled(model.sync.preferences.mode != .booksAndNotes || isDownloading)
            } else {
                Button("Remove Download") { model.removeDownload(record) }
            }
        }
        Divider()
        Button("Remove from Recent") { model.removeFromRecents(record) }
        Button(record.cloudIdentity == nil ? "Delete Book and Notes…" : "Delete Book and Notes Everywhere…",
               role: .destructive) { onDelete(record) }
    }
}

private struct LibraryBookCover: View {
    let record: BookRecord
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    let palette: LibraryPalette
    @State private var image: NSImage?

    private var isSmall: Bool { width < 100 }
    private var format: String { record.isWebDocument ? "WEB" : record.documentKind.rawValue.uppercased() }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    fallback
                }
            }
            .frame(width: width, height: height)
            .clipped()
            Text(format)
                .font(.system(size: isSmall ? 5 : 7, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(red: 0.32, green: 0.38, blue: 0.30))
                .padding(.horizontal, isSmall ? 3 : 5)
                .padding(.vertical, isSmall ? 2 : 3)
                .background(Color(red: 0.98, green: 0.98, blue: 0.94).opacity(0.9),
                            in: .rect(cornerRadius: 3))
                .padding(isSmall ? 3 : 7)
        }
        .frame(width: width, height: height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4,
                                         bottomTrailingRadius: 8, topTrailingRadius: 8))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 4)
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let data = await Task.detached(priority: .utility) {
                (try? ReaderDocument(fileURL: url))?.coverImageData
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }

    private var fallback: some View {
        ZStack {
            palette.accentSoft
            VStack(spacing: isSmall ? 5 : 17) {
                Rectangle().fill(palette.accent.opacity(0.4))
                    .frame(width: isSmall ? 15 : 34, height: 1)
                Text(record.title)
                    .font(.system(size: isSmall ? 8 : 21, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(isSmall ? 4 : 5)
                if !isSmall {
                    Text(record.author.isEmpty ? "Kodi Reader" : record.author)
                        .font(.system(size: 7))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Image(systemName: "book.closed")
                        .font(.system(size: 25, weight: .light))
                        .opacity(0.6)
                }
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, isSmall ? 5 : 16)
        }
    }
}
