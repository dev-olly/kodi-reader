import AppKit
import EpubKit
import SwiftUI

/// Native attachments and SwiftUI previews reserve the same deterministic size.
enum AudioNoteCardLayout {
    static let baseHeight: CGFloat = 180
    static let recordingHeight: CGFloat = 180
    static let transcriptExtraHeight: CGFloat = 128
    static let transcriptActionHeight: CGFloat = 36
    static let statusExtraHeight: CGFloat = 34
    static let draftErrorExtraHeight: CGFloat = 44

    static func height(audio: NoteAudio, expanded: Bool, hasStatus: Bool = false, canAddTranscript: Bool = false) -> CGFloat {
        let hasTranscript = !(audio.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return baseHeight + (expanded && hasTranscript ? transcriptExtraHeight + (canAddTranscript ? transcriptActionHeight : 0) : 0)
            + (hasStatus ? statusExtraHeight : 0)
    }
}

/// The website's audio card, with real playback, seeking, and saved transcripts.
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
    var onAddTranscriptToNote: (() -> Void)? = nil
    var transcriptionError: String? = nil
    @State private var playbackError: String?
    @State private var copiedTranscript = false
    @State private var addedTranscript = false
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
    private var canTranscribe: Bool {
        onTranscribe != nil && url != nil && transcription?.isBusy != true && controller.recordingID == nil
    }
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
            header
            player.padding(.top, 16)
            if showsStatus { status }
            if expanded && hasTranscript { transcriptBody }
            footer.padding(.top, 12)
        }
        .padding(16)
        .frame(height: AudioNoteCardLayout.height(audio: audio, expanded: expanded, hasStatus: showsStatus,
                                                canAddTranscript: onAddTranscriptToNote != nil))
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

    private var header: some View {
        HStack(spacing: 8) {
            AudioNoteHeading(title: audio.title.isEmpty ? "Audio note" : audio.title,
                             subtitle: audio.createdAt == .distantPast ? "Recording unavailable" : "Audio note · " + AudioStripTime.duration(audio.duration),
                             palette: palette)
                .help(recordedLabel)

            Menu {
                if hasTranscript {
                    Button("Add transcript to note", systemImage: "text.badge.plus", action: addTranscriptToNote)
                        .disabled(onAddTranscriptToNote == nil || addedTranscript)
                    Button("Transcribe again…", systemImage: "text.quote") { onTranscribe?() }
                        .disabled(!canTranscribe)
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
        .frame(height: 40)
    }

    private var player: some View {
        HStack(spacing: 12) {
            Button {
                guard let url else { return }
                do { try controller.play(id: audio.id, url: url) }
                catch { playbackError = error.localizedDescription }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .offset(x: playing ? 0 : 1)
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)
                    .background(palette.iconSurface, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(url == nil || controller.recordingID != nil)
            .accessibilityLabel((playing ? "Pause " : "Play ") + audio.title)
            .help(url == nil ? "Recording unavailable. Wait for it to download or try syncing again." : playing ? "Pause recording" : "Play recording")

            AudioWaveform(samples: audio.waveform, progress: active ? controller.progress : 0,
                          ink: palette.waveform, accent: palette.accent)
                .frame(maxWidth: 420)
                .overlay {
                    Slider(value: Binding(
                        get: { active ? controller.progress : 0 },
                        set: { fraction in
                            do {
                                if !active, let url { try controller.preparePlayback(id: audio.id, url: url) }
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
                .frame(maxWidth: .infinity)
                .help("Seek in recording")
        }
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(AudioStripTime.string(active ? controller.playbackTime : 0) + " / " + AudioStripTime.string(audio.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .accessibilityLabel("Elapsed " + AudioStripTime.string(active ? controller.playbackTime : 0) + " of " + AudioStripTime.string(audio.duration))
            Spacer(minLength: 4)
            Button {
                if hasTranscript { onToggleTranscript?() }
                else { onTranscribe?() }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Text(transcriptAction).fixedSize()
                    Image(systemName: "text.quote")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(height: 28)
            }
            .buttonStyle(.plain)
            .disabled(hasTranscript ? onToggleTranscript == nil : !canTranscribe)
            .accessibilityLabel(transcriptAction + " for " + audio.title)
            .help(transcriptAction)
        }
        .frame(height: 28)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if transcribing {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                Text(transcription?.phase == .preparing ? "Preparing…" : "Transcribing…").lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { transcription?.cancel(id: audio.id, scope: transcriptionScope) }
            } else if let error {
                Text(error).lineLimit(1).help(error)
                Spacer(minLength: 0)
                Button("Retry") { onTranscribe?() }.disabled(!canTranscribe)
            }
        }
        .font(.system(size: 10))
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .tint(palette.accent)
        .frame(height: AudioNoteCardLayout.statusExtraHeight)
        .accessibilityElement(children: .contain)
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SAVED TRANSCRIPT")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.8)
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
                    Image(systemName: copiedTranscript ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedTranscript ? "Transcript copied" : "Copy transcript")
                .help(copiedTranscript ? "Copied" : "Copy transcript")
            }
            .frame(height: 14)

            ScrollView {
                Text(transcript)
                    .font(.custom("Georgia", size: 14))
                    .foregroundStyle(palette.transcriptInk)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            .frame(height: 62)
            .accessibilityLabel("Transcript of " + audio.title)

            if onAddTranscriptToNote != nil {
                Button(action: addTranscriptToNote) {
                    Label(addedTranscript ? "Added to note" : "Add transcript to note",
                          systemImage: addedTranscript ? "checkmark" : "text.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(addedTranscript)
                .accessibilityLabel(addedTranscript ? "Transcript added to note" : "Add transcript to note")
                .help("Insert editable text below this recording")
            }
        }
        .padding(12)
        .background(palette.transcriptSurface, in: .rect(cornerRadius: 7))
        .padding(.top, 20)
        .frame(height: AudioNoteCardLayout.transcriptExtraHeight
               + (onAddTranscriptToNote == nil ? 0 : AudioNoteCardLayout.transcriptActionHeight))
    }

    private func addTranscriptToNote() {
        guard hasTranscript, !addedTranscript, let onAddTranscriptToNote else { return }
        onAddTranscriptToNote()
        addedTranscript = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            addedTranscript = false
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
    private var recordingStatus: String {
        if preparing { return "Preparing microphone…" }
        let state = controller.isPaused ? "Paused" : controller.isRecording ? "Recording" : "Ready to save"
        return state + " · " + AudioStripTime.string(controller.elapsed)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AudioNoteHeading(title: "New audio note", subtitle: recordingStatus, palette: palette)
                Button(action: onDiscard) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .frame(width: 22, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard recording")
                .help("Discard recording")
            }
            .frame(height: 40)

            AudioWaveform(samples: controller.waveform, progress: 0, ink: palette.waveform, accent: palette.accent)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.top, 16)
                .accessibilityElement()
                .accessibilityLabel("Microphone input level")
                .accessibilityValue("\(Int(controller.inputLevel * 100)) percent")

            HStack(spacing: 8) {
                if controller.isRecording || controller.isPaused {
                    Button {
                        do {
                            if controller.isPaused { try controller.resumeRecording() }
                            else { controller.pauseRecording() }
                        } catch { resumeError = error.localizedDescription }
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label(controller.isPaused ? "Resume" : "Pause", systemImage: controller.isPaused ? "play.fill" : "pause.fill")
                                .fixedSize()
                            Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.isPaused ? "Resume recording" : "Pause recording")
                    .help(controller.isPaused ? "Resume recording" : "Pause recording")
                } else {
                    Text(preparing ? "Getting ready…" : "Keep this thought")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                }
                Spacer(minLength: 4)
                Button(action: onDone) {
                    Text("Save audio")
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                        .foregroundStyle(palette.actionInk)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(palette.accent, in: .rect(cornerRadius: 7))
                        .contentShape(.rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(preparing || !controller.canFinish)
                .accessibilityLabel("Save recording")
                .help("Save recording")
            }
            .frame(height: 28)
            .padding(.top, 12)
        }
        .padding(16)
        .frame(height: AudioNoteCardLayout.recordingHeight)
        .background(palette.surface, in: .rect(cornerRadius: 12))
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
}

private struct AudioNoteHeading: View {
    let title: String
    let subtitle: String
    let palette: AudioStripPalette

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(palette.accent)
                .frame(width: 35, height: 39)
                .background(palette.iconSurface, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                Text(subtitle)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AudioWaveform: View {
    let samples: [Float]
    let progress: Double
    let ink: Color
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let count = max(1, min(48, Int(size.width / 8)))
            let stride = size.width / CGFloat(count)
            for index in 0..<count {
                let sample = samples.isEmpty ? Float(0) : samples[min(samples.count - 1, index * samples.count / count)]
                let amplitude = sample.isFinite ? min(1, max(0, sample)) : 0
                let height = max(3, CGFloat(amplitude) * (size.height - 4))
                let x = (CGFloat(index) + 0.5) * stride
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                bar.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                context.stroke(bar, with: .color(Double(index) / Double(count) < progress ? accent : ink),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
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
    let actionInk: Color
    let iconSurface: Color
    let transcriptSurface: Color
    let transcriptInk: Color

    init(dark: Bool) {
        surface = Self.color(dark ? 0x252E27 : 0xFFFFFF)
        border = Self.color(dark ? 0x465448 : 0xDCE5DA)
        ink = Self.color(dark ? 0xE5ECE2 : 0x263B2E)
        muted = Self.color(dark ? 0xA4B49F : 0x758175)
        waveform = Self.color(dark ? 0x93B88A : 0x779E73)
        accent = Self.color(dark ? 0xAACD9E : 0x416C4D)
        actionInk = Self.color(dark ? 0x243621 : 0xFFFFFF)
        iconSurface = Self.color(dark ? 0x323F32 : 0xEFF4EB)
        transcriptSurface = Self.color(dark ? 0x2E392D : 0xF3F6EF)
        transcriptInk = Self.color(dark ? 0xC2D0BC : 0x566951)
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

    static func duration(_ time: TimeInterval) -> String {
        let bounded = time.isFinite ? min(Double(Int.max / 2), max(0, time)) : 0
        let seconds = Int(bounded)
        if seconds < 60 { return "\(seconds) " + (seconds == 1 ? "second" : "seconds") }
        return string(time)
    }
}
