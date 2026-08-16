import AppKit
import ReaderUI
import SwiftUI

/// Full-width dock shown while read-aloud is preparing or playing.
struct ReadAloudBar: View {
    @Environment(AppModel.self) private var model

    private static let rates: [Double] = [0.8, 1.0, 1.2, 1.5, 1.75]

    var body: some View {
        @Bindable var model = model
        let readAloud = model.readAloud
        let _ = readAloud.progressTick

        VStack(spacing: 10) {
            progressRow(readAloud)

            HStack(spacing: 16) {
                metadata(readAloud)
                    .frame(maxWidth: .infinity, alignment: .leading)

                transport(readAloud)
                    .disabled(readAloud.status == .preparing)

                trailing(readAloud, model: model)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private func progressRow(_ readAloud: ReadAloudController) -> some View {
        if let error = readAloud.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if readAloud.status == .preparing || readAloud.statusMessage != nil {
            HStack(spacing: 8) {
                if let progress = readAloud.downloadProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(readAloud.statusMessage ?? "Preparing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 10) {
                Text(Self.formatTime(readAloud.chapterElapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                ProgressView(value: readAloud.chapterProgress)
                    .progressViewStyle(.linear)
                    .tint(.primary)

                if let remaining = readAloud.chapterRemaining {
                    Text("−" + Self.formatTime(remaining))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                } else {
                    Text(readAloud.chapterLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
    }

    private func metadata(_ readAloud: ReadAloudController) -> some View {
        HStack(spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(readAloud.bookTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !readAloud.bookAuthor.isEmpty {
                    Text(readAloud.bookAuthor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        let image = model.book.flatMap { book -> NSImage? in
            book.coverImageData.flatMap { NSImage(data: $0) }
        }
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func transport(_ readAloud: ReadAloudController) -> some View {
        HStack(spacing: 18) {
            Button(action: model.toggleBookmark) {
                Image(systemName: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14))
            }
            .quickHelp(model.isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page")

            Button(action: readAloud.skipBack) {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 16, weight: .medium))
            }
            .quickHelp("Skip back 15 seconds")

            Button(action: readAloud.togglePause) {
                Image(systemName: readAloud.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.background)
                    .frame(width: 36, height: 36)
                    .background(.primary, in: Circle())
            }
            .quickHelp(readAloud.isPlaying ? "Pause" : "Play")

            Button(action: readAloud.skipForward) {
                Image(systemName: "goforward.15")
                    .font(.system(size: 16, weight: .medium))
            }
            .quickHelp("Skip forward 15 seconds")

            Menu {
                ForEach(Self.rates, id: \.self) { rate in
                    Button(Self.formatRate(rate)) {
                        model.settings.readAloudRate = rate
                        readAloud.setRate(rate)
                    }
                }
            } label: {
                Text(Self.formatRate(model.settings.readAloudRate))
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 36)
            }
            .menuStyle(.borderlessButton)
            .quickHelp("Reading speed")
        }
        .buttonStyle(.borderless)
    }

    private func trailing(_ readAloud: ReadAloudController, model: AppModel) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ReadAloudVoice.catalog) { voice in
                    Button(voice.displayName) {
                        model.settings.readAloudVoiceID = voice.id
                        readAloud.setVoice(voice.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(String(currentVoiceName(model).prefix(1)))
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                    HStack(spacing: 0) {
                        Text("Read by ")
                            .foregroundStyle(.secondary)
                        Text(currentVoiceName(model))
                            .fontWeight(.semibold)
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .quickHelp("Voice")

            Button(action: readAloud.stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .quickHelp("Stop reading")
        }
    }

    private func currentVoiceName(_ model: AppModel) -> String {
        ReadAloudVoice.catalog.first { $0.id == model.settings.readAloudVoiceID }?.displayName
            ?? "Voice"
    }

    private static func formatRate(_ rate: Double) -> String {
        String(format: "%g×", rate)
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
