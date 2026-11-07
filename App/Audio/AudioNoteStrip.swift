import AppKit
import EpubKit
import SwiftUI

/// Native attachments and SwiftUI previews reserve the same deterministic size.
enum AudioNoteCardLayout {
    static let baseHeight: CGFloat = 88
    static let transcriptExtraHeight: CGFloat = 156
    static let statusExtraHeight: CGFloat = 30

    static func height(audio: NoteAudio, expanded: Bool, hasStatus: Bool = false) -> CGFloat {
        let hasTranscript = !(audio.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return baseHeight + (expanded && hasTranscript ? transcriptExtraHeight : 0) + (hasStatus ? statusExtraHeight : 0)
    }
}

/// Quiet recording metadata and playback, with transcription available in place.
struct AudioNoteStrip: View {
    let audio: NoteAudio
    let url: URL?
    let controller: AudioNoteController
    let isDark: Bool
    let onRename: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    var transcription: AudioTranscriptionController? = nil
    var transcriptionScope: AudioTranscriptionScope? = nil
    var expanded: Bool = false
    var onTranscribe: (() -> Void)? = nil
    var onToggleTranscript: (() -> Void)? = nil
    var transcriptionError: String? = nil
    @State private var playbackError: String?
    @State private var copiedTranscript = false
    @FocusState private var seekingFocused: Bool

    private var active: Bool { controller.playbackID == audio.id }
    private var playing: Bool { active && controller.isPlaying }
    private var palette: AudioStripPalette { AudioStripPalette(dark: isDark) }
    private var transcript: String { audio.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var hasTranscript: Bool { !transcript.isEmpty }
    private var transcribing: Bool { transcription?.isTranscribing(id: audio.id, scope: transcriptionScope) == true }
    private var error: String? {
        transcriptionError ?? transcription?.error(for: audio.id, scope: transcriptionScope)
    }
    private var showsStatus: Bool { transcribing || error != nil }
    private var transcriptAction: String { hasTranscript ? (expanded ? "Hide transcript" : "Show transcript") : "Transcribe" }
    private var recordedLabel: String {
        if audio.createdAt == .distantPast { return "Recording unavailable" }
        let time = audio.createdAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(audio.createdAt) { return "Recorded today at " + time }
        if Calendar.current.isDateInYesterday(audio.createdAt) { return "Recorded yesterday at " + time }
        return "Recorded " + audio.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                header(compact: geometry.size.width < 240)
                    .frame(width: geometry.size.width, height: 44)
            }
            .frame(height: 44)
            player
            if showsStatus { status }
            if expanded && hasTranscript { transcriptBody }
        }
        .frame(height: AudioNoteCardLayout.height(audio: audio, expanded: expanded, hasStatus: showsStatus))
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio note: " + audio.title)
        .transaction { $0.animation = nil }
        .alert("Couldn’t play recording", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("OK", role: .cancel) { playbackError = nil }
        } message: { Text(playbackError ?? "") }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            if !compact {
                Image(systemName: "mic")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 28, height: 24)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(audio.title.isEmpty ? "Audio note" : audio.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(audio.title)
                Text(recordedLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(audio.createdAt.formatted(date: .complete, time: .shortened))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if hasTranscript { onToggleTranscript?() }
                else { onTranscribe?() }
            } label: {
                HStack(spacing: 4) {
                    if !compact && !hasTranscript { Image(systemName: "text.quote").font(.system(size: 10)) }
                    Text(transcriptAction)
                }
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 28)
                .foregroundStyle(palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(hasTranscript ? onToggleTranscript == nil : (onTranscribe == nil || url == nil || transcription?.isBusy == true || controller.recordingID != nil))
            .accessibilityLabel(transcriptAction + " for " + audio.title)
            .help(transcriptAction)

            Menu {
                if hasTranscript {
                    Button("Transcribe again…", systemImage: "text.quote") { onTranscribe?() }
                        .disabled(onTranscribe == nil || url == nil || transcription?.isBusy == true || controller.recordingID != nil)
                }
                Button("Rename…", systemImage: "pencil", action: onRename)
                Button("Export audio…", systemImage: "square.and.arrow.up", action: onExport)
                    .disabled(url == nil)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .frame(width: 22, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for " + audio.title)
            .help("Recording options")
        }
        .padding(.horizontal, compact ? 10 : 12)
    }

    private var player: some View {
        HStack(spacing: 8) {
            Button {
                guard let url else { return }
                do { try controller.play(id: audio.id, url: url) }
                catch { playbackError = error.localizedDescription }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(playing ? palette.accent : palette.ink)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(url == nil || controller.recordingID != nil)
            .accessibilityLabel((playing ? "Pause " : "Play ") + audio.title)
            .help(url == nil ? "Recording unavailable. Wait for it to download or try syncing again." : playing ? "Pause recording" : "Play recording")

            AudioWaveform(
                samples: audio.waveform,
                progress: active ? controller.progress : 0,
                ink: palette.waveform,
                accent: palette.accent
            )
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .overlay {
                Slider(value: Binding(
                    get: { active ? controller.progress : 0 },
                    set: { fraction in
                        do {
                            if !active, let url {
                                try controller.preparePlayback(id: audio.id, url: url)
                            }
                            controller.seek(to: fraction)
                        } catch { playbackError = error.localizedDescription }
                    }
                ), in: 0...1)
                .labelsHidden()
                .opacity(0.02)
                .focused($seekingFocused)
                .disabled(url == nil || controller.recordingID != nil)
                .accessibilityLabel("Playback position for " + audio.title)
                .accessibilityValue(AudioStripTime.string(active ? controller.playbackTime : 0) + " of " + AudioStripTime.string(audio.duration))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(seekingFocused ? palette.accent : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .help("Seek in recording")

            Text(AudioStripTime.string(active ? max(0, audio.duration - controller.playbackTime) : audio.duration))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.muted)
                .frame(width: 38, alignment: .trailing)
                .accessibilityLabel(active ? "Time remaining" : "Duration")

        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if transcribing {
                ProgressView().controlSize(.mini)
                    .frame(width: 12, height: 12)
                Text(transcription?.phase == .preparing ? "Preparing…" : "Transcribing…")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { transcription?.cancel(id: audio.id, scope: transcriptionScope) }
                    .foregroundStyle(palette.muted)
            } else if let error {
                Text(error).lineLimit(1).help(error)
                Spacer(minLength: 0)
                Button("Retry") { onTranscribe?() }
                    .foregroundStyle(palette.accent)
                    .disabled(onTranscribe == nil || transcription?.isBusy == true || url == nil || controller.recordingID != nil)
            }
        }
        .font(.system(size: 10))
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 12)
        .frame(height: AudioNoteCardLayout.statusExtraHeight)
        .accessibilityElement(children: .contain)
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                    copiedTranscript = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedTranscript = false
                    }
                } label: {
                    Label(copiedTranscript ? "Copied" : "Copy", systemImage: copiedTranscript ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy transcript")
                .help("Copy transcript")
            }
            .frame(height: 20)

            ScrollView {
                Text(transcript)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            .frame(height: 112)
            .accessibilityLabel("Transcript of " + audio.title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: AudioNoteCardLayout.transcriptExtraHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 1)
                .allowsHitTesting(false)
        }
    }
}

struct AudioRecordingStrip: View {
    let controller: AudioNoteController
    let isDark: Bool
    let onDone: () -> Void
    let onDiscard: () -> Void
    @State private var resumeError: String?

    private var palette: AudioStripPalette { AudioStripPalette(dark: isDark) }
    private var preparing: Bool { controller.recordingID == nil || controller.phase == .requestingPermission }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.width < 300)
                .frame(width: geometry.size.width, height: 44)
        }
        .frame(height: 44)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preparing ? "Preparing microphone" : controller.isPaused ? "Audio recording paused" : "Audio recording")
        .alert("Couldn’t resume recording", isPresented: Binding(get: { resumeError != nil }, set: { if !$0 { resumeError = nil } })) {
            Button("OK", role: .cancel) { resumeError = nil }
        } message: { Text(resumeError ?? "") }
    }

    private func content(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(preparing ? palette.muted : palette.accent)
                .frame(width: 6, height: 6)
                .padding(.leading, 2)
                .accessibilityHidden(true)

            if !compact {
                Text(preparing ? "Microphone…" : controller.isPaused ? "Paused" : controller.isRecording ? "Recording" : "Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(AudioStripTime.string(controller.elapsed))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.muted)
                .accessibilityLabel("Recorded time")

            if !compact {
                GeometryReader { geometry in
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<12, id: \.self) { index in
                            Capsule()
                                .fill(controller.inputLevel > Float(index) / 12 ? palette.accent : palette.waveform.opacity(0.45))
                                .frame(width: max(1, (geometry.size.width - 22) / 12), height: CGFloat(5 + (index % 4) * 3))
                        }
                    }
                    .frame(height: geometry.size.height)
                }
                .frame(minWidth: 36, maxWidth: .infinity)
                .frame(height: 20)
                .accessibilityLabel("Microphone input level")
                .accessibilityValue("\(Int(controller.inputLevel * 100)) percent")
            } else {
                Spacer(minLength: 0)
            }

            if controller.isRecording || controller.isPaused {
                Button {
                    do {
                        if controller.isPaused { try controller.resumeRecording() }
                        else { controller.pauseRecording() }
                    } catch { resumeError = error.localizedDescription }
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isPaused ? "Resume recording" : "Pause recording")
                .help(controller.isPaused ? "Resume recording" : "Pause recording")
            }

            Button("Done", action: onDone)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
                .buttonStyle(.plain)
                .disabled(preparing || !controller.canFinish)
                .help("Save recording")

            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard recording")
            .help("Discard recording")
        }
        .padding(.horizontal, 8)
    }
}

private struct AudioWaveform: View {
    let samples: [Float]
    let progress: Double
    let ink: Color
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, min(48, Int(geometry.size.width / 4)))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    let sample = samples.isEmpty ? Float(0) : samples[min(samples.count - 1, index * samples.count / count)]
                    Capsule()
                        .fill(Double(index) / Double(count) < progress ? accent : ink)
                        .frame(width: max(1, (geometry.size.width - CGFloat(count - 1) * 2) / CGFloat(count)), height: max(2, CGFloat(min(1, max(0, sample))) * 20))
                }
            }
            .frame(height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}

private struct AudioStripPalette {
    let surface: Color
    let border: Color
    let ink: Color
    let muted: Color
    let waveform: Color
    let accent: Color

    init(dark: Bool) {
        surface = Self.color(dark ? 0x282E2A : 0xF0F5F1)
        border = Self.color(dark ? 0x46544B : 0xD9E2DC)
        ink = Self.color(dark ? 0xE9EEE9 : 0x192A24)
        muted = Self.color(dark ? 0xAFBEB4 : 0x59675F)
        waveform = Self.color(dark ? 0x7E9585 : 0x9CAFA1)
        accent = Self.color(dark ? 0xFFD645 : 0x796000)
    }

    private static func color(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

enum AudioStripTime {
    static func string(_ time: TimeInterval) -> String {
        let bounded = time.isFinite ? min(Double(Int.max / 2), max(0, time)) : 0
        let seconds = Int(bounded)
        if seconds >= 3600 { return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
