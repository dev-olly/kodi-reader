import AppKit
import FluidAudio
import ReaderUI
import SwiftUI

/// A persistent listening surface that shares the reader's palette and type scale.
struct ReadAloudPlayerBar: View {
    @Bindable var narration: ReadAloudController
    let title: String
    let subtitle: String
    let cover: NSImage?
    let theme: ReaderTheme
    @Binding var followText: Bool
    let onPlay: () -> Void
    let onClose: () -> Void

    @State private var showingVoices = false
    @State private var showingSpeed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(time(narration.elapsed / Double(narration.rate)))
                    .frame(minWidth: 34, alignment: .leading)
                ReadAloudScrubber(progress: narration.progress, enabled: narration.hasSession,
                                  color: theme.accent, track: theme.border) {
                    narration.seek(to: $0 * narration.duration)
                }
                Text((narration.hasEstimatedDuration ? "~" : "−") + time(narration.remaining))
                    .frame(minWidth: 38, alignment: .trailing)
                    .help(narration.hasEstimatedDuration ? "Estimated time remaining in this chapter" : "Time remaining in this chapter")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 26)
            .padding(.top, 11)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    bookIdentity.frame(maxWidth: .infinity, alignment: .leading)
                    transport
                    preferences.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(minWidth: 780)

                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        bookIdentity
                        Spacer(minLength: 8)
                        closeButton
                    }
                    HStack(spacing: 12) {
                        speedButton.frame(maxWidth: .infinity, alignment: .leading)
                        transport
                        HStack(spacing: 14) {
                            followButton
                            voiceButton(compact: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 4)
            .padding(.bottom, 15)
        }
        .foregroundStyle(theme.uiForeground)
        .background(theme.uiBackground)
        .overlay(alignment: .top) { theme.border.opacity(0.8).frame(height: 1) }
        .tint(theme.accent)
        .accessibilityIdentifier("read-aloud-player")
    }

    private var bookIdentity: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(theme.surface)
                if let cover {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(theme.accent.opacity(0.8))
                }
            }
            .frame(width: 35, height: 46)
            .clipShape(.rect(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border.opacity(0.7), lineWidth: 0.5) }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if narration.phase == .playing {
                        Circle().fill(theme.accent).frame(width: 4, height: 4)
                    }
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .help(status)
                }
            }
        }
        .frame(minWidth: 140, alignment: .leading)
    }

    private var status: String {
        switch narration.phase {
        case .preparing: return "Preparing your audio…"
        case .failed(let message): return message
        case .idle: return narration.isFinished ? "Listening complete" : subtitle
        case .playing, .paused: return subtitle
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            iconButton("gobackward.15", label: "Back 15 seconds") { narration.skip(by: -15) }
                .disabled(!narration.hasSession)

            Button(action: onPlay) {
                ZStack {
                    Circle().fill(theme.accent)
                    if narration.phase == .preparing {
                        ProgressView().controlSize(.small).tint(theme.uiBackground)
                    } else {
                        Image(systemName: narration.phase == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .offset(x: narration.phase == .playing ? 0 : 1)
                            .foregroundStyle(theme.uiBackground)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(narration.phase == .preparing)
            .help(narration.phase == .playing ? "Pause · Space" : "Play · Space")
            .accessibilityLabel(narration.phase == .playing ? "Pause narration" : "Play narration")

            iconButton("goforward.15", label: "Forward 15 seconds") { narration.skip(by: 15) }
                .disabled(!narration.hasSession)
        }
    }

    private var speedButton: some View {
        Button { showingSpeed.toggle() } label: {
            Text(narration.rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 38, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .popover(isPresented: $showingSpeed, arrowEdge: .top) { speedPicker }
    }

    private var followButton: some View {
        Button { followText.toggle() } label: {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(followText ? theme.accent : theme.muted)
                .frame(width: 30, height: 30)
                .background(followText ? theme.accent.opacity(0.09) : .clear, in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(followText ? "Following the spoken text" : "Return to audio and follow text")
        .accessibilityLabel("Follow spoken text")
        .accessibilityAddTraits(followText ? .isSelected : [])
    }

    private var preferences: some View {
        HStack(spacing: 20) {
            speedButton
            followButton
            Rectangle().fill(theme.border).frame(width: 1, height: 20)
            voiceButton(compact: false)
            closeButton
        }
    }

    private func voiceButton(compact: Bool) -> some View {
        Button { showingVoices.toggle() } label: {
            HStack(spacing: 8) {
                voiceAvatar(narration.voice, size: 28)
                if !compact {
                    Text(voiceName(narration.voice)).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.muted)
                }
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Choose narrator")
        .accessibilityLabel("Narrator, " + voiceName(narration.voice))
        .popover(isPresented: $showingVoices, arrowEdge: .top) { voicePicker }
    }

    private var closeButton: some View {
        iconButton("xmark", label: "Close audio player", size: 12, action: onClose)
            .foregroundStyle(theme.muted)
    }

    private func iconButton(_ symbol: String, label: String, size: CGFloat = 19, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 30, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var speedPicker: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Playback speed").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(narration.rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(theme.accent)
            }
            Slider(value: $narration.rate, in: 0.5...2, step: 0.05)
                .tint(theme.accent)
                .accessibilityLabel("Playback speed")
            HStack(spacing: 6) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button {
                        narration.rate = rate
                    } label: {
                        Text(rate.formatted() + "×")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(narration.rate == rate ? theme.accent.opacity(0.12) : theme.surface,
                                        in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(width: 258)
        .foregroundStyle(theme.uiForeground)
        .background(theme.uiBackground)
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose your narrator").font(.system(size: 13, weight: .semibold)).padding(.bottom, 9)
            ForEach([ParadeeVoice.afHeart, .amPuck, .bfIsabella, .bmFable], id: \.self) { voice in
                Button {
                    narration.voice = voice
                    showingVoices = false
                } label: {
                    HStack(spacing: 12) {
                        voiceAvatar(voice, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(voiceName(voice)).font(.system(size: 12, weight: .medium))
                            Text(voiceDescription(voice)).font(.system(size: 10)).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        if narration.voice == voice {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                        }
                    }
                    .padding(9)
                    .background(narration.voice == voice ? theme.surface : .clear, in: .rect(cornerRadius: 9))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .frame(width: 250)
        .foregroundStyle(theme.uiForeground)
        .background(theme.uiBackground)
    }

    private func voiceAvatar(_ voice: ParadeeVoice, size: CGFloat) -> some View {
        Text(String(voiceName(voice).prefix(1)))
            .font(.system(size: size * 0.4, weight: .medium, design: .serif))
            .foregroundStyle(theme.accent)
            .frame(width: size, height: size)
            .background(theme.accent.opacity(0.10), in: .circle)
            .overlay { Circle().strokeBorder(theme.accent.opacity(0.12), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }

    private func voiceName(_ voice: ParadeeVoice) -> String {
        switch voice {
        case .afHeart: return "Heart"
        case .amPuck: return "Puck"
        case .bfIsabella: return "Isabella"
        case .bmFable: return "Fable"
        }
    }

    private func voiceDescription(_ voice: ParadeeVoice) -> String {
        switch voice {
        case .afHeart: return "Warm & clear · American"
        case .amPuck: return "Bright & easygoing · American"
        case .bfIsabella: return "Soft & measured · British"
        case .bmFable: return "Rich & expressive · British"
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct ReadAloudScrubber: View {
    let progress: Double
    let enabled: Bool
    let color: Color
    let track: Color
    let onSeek: (Double) -> Void
    @State private var scrubbed: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = scrubbed ?? progress
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: 3)
                Capsule().fill(color).frame(width: max(0, geometry.size.width * fraction), height: 3)
                Circle().fill(color).frame(width: 9, height: 9)
                    .offset(x: max(0, geometry.size.width * fraction - 4.5))
                    .opacity(enabled && (hovering || scrubbed != nil) ? 1 : 0)
            }
            .frame(height: geometry.size.height)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled else { return }
                    scrubbed = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                }
                .onEnded { _ in
                    if let scrubbed { onSeek(scrubbed) }
                    scrubbed = nil
                })
            .onHover { hovering = $0 }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Listening progress")
        .accessibilityValue("\(Int(progress * 100)) percent of chapter")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            onSeek(min(1, max(0, progress + (direction == .increment ? 0.02 : -0.02))))
        }
        .help("Seek in this chapter")
    }
}
