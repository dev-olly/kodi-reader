import FluidAudio
import SwiftUI

struct ReadAloudPopover: View {
    @Bindable var narration: ReadAloudController
    let canStart: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listen")
                .font(.headline)
            Text("Paradee reads English on this Mac. The first use downloads speech files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Voice", selection: $narration.voice) {
                Text("Heart · US").tag(ParadeeVoice.afHeart)
                Text("Puck · US").tag(ParadeeVoice.amPuck)
                Text("Isabella · UK").tag(ParadeeVoice.bfIsabella)
                Text("Fable · UK").tag(ParadeeVoice.bmFable)
            }
            .disabled(narration.isActive)

            Picker("Speed", selection: $narration.rate) {
                Text("0.75×").tag(Float(0.75))
                Text("1×").tag(Float(1))
                Text("1.25×").tag(Float(1.25))
                Text("1.5×").tag(Float(1.5))
                Text("2×").tag(Float(2))
            }

            HStack(spacing: 8) {
                switch narration.phase {
                case .idle, .failed:
                    Button("Listen from Here", systemImage: "play.fill", action: onStart)
                        .disabled(!canStart)
                case .preparing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing audio…")
                        .foregroundStyle(.secondary)
                case .playing:
                    Button("Pause", systemImage: "pause.fill", action: narration.pause)
                case .paused:
                    Button("Resume", systemImage: "play.fill", action: narration.resume)
                }
                if narration.isActive {
                    Spacer()
                    Button("Stop", systemImage: "stop.fill", action: narration.stop)
                }
            }

            if case .failed(let message) = narration.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 270)
    }
}
