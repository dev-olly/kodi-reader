import AVFoundation
import Foundation

/// Plays 24 kHz mono float buffers through a time-pitch node so rate can change live.
@MainActor
final class ReadAloudPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var finishPlay: (() -> Void)?
    private var playID = 0
    private var scheduleID = 0
    private var watchdogGeneration = 0
    private var installedFormat: AVAudioFormat?
    private var isPaused = false
    private var samples: [Float] = []
    private var sampleRate: Double = 24_000

    var rate: Double = 1 {
        didSet {
            let clamped = min(2, max(0.5, rate))
            timePitch.rate = Float(clamped)
        }
    }

    var isPlaying: Bool { player.isPlaying }

    var duration: TimeInterval {
        Double(samples.count) / max(sampleRate, 1)
    }

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.overlap = 8
        timePitch.pitch = 0
        rate = 1
    }

    func play(_ speech: SynthesizedSpeech, from start: TimeInterval = 0) async {
        guard !speech.samples.isEmpty else { return }
        samples = speech.samples
        sampleRate = speech.sampleRate
        connectIfNeeded(format: AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) ?? AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        playID += 1
        let id = playID
        isPaused = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishPlay = { [weak self] in
                guard let self, id == self.playID else { return }
                self.finishPlay = nil
                continuation.resume()
            }
            do {
                if !engine.isRunning {
                    try engine.start()
                }
            } catch {
                finishPlay?()
                return
            }
            schedule(from: start, playImmediately: true)
        }
    }

    /// Jump within the current buffer without ending `play()`.
    func seek(to time: TimeInterval) {
        guard !samples.isEmpty else { return }
        let clamped = min(max(0, time), duration)
        if clamped >= duration - 0.02 {
            skipCurrent()
            return
        }
        schedule(from: clamped, playImmediately: !isPaused)
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        if !engine.isRunning {
            try? engine.start()
        }
        player.play()
    }

    func skipCurrent() {
        isPaused = false
        scheduleID += 1
        watchdogGeneration += 1
        player.stop()
        finishPlay?()
    }

    func stop() {
        playID += 1
        scheduleID += 1
        watchdogGeneration += 1
        isPaused = false
        finishPlay?()
        player.stop()
        samples = []
        if engine.isRunning {
            engine.stop()
            engine.reset()
        }
    }

    private func schedule(from start: TimeInterval, playImmediately: Bool) {
        scheduleID += 1
        let sid = scheduleID
        let startFrame = min(samples.count, max(0, Int((start * sampleRate).rounded())))
        let remaining = Array(samples[startFrame...])
        guard let buffer = Self.buffer(samples: remaining, sampleRate: sampleRate, padSeconds: 0.15) else {
            finishPlay?()
            return
        }

        player.stop()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, sid == self.scheduleID else { return }
                self.finishPlay?()
            }
        }
        if playImmediately {
            player.play()
        }

        let remainingSeconds = Double(remaining.count) / max(sampleRate, 1)
        startWatchdog(seconds: remainingSeconds / max(rate, 0.5) + 0.4)
    }

    /// Fires if `.dataPlayedBack` never arrives. Does not tick down while paused.
    private func startWatchdog(seconds: TimeInterval) {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        let id = playID
        Task { @MainActor [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, id == self.playID, generation == self.watchdogGeneration else { return }
                if !self.isPaused {
                    remaining -= 0.05
                }
            }
            guard let self, id == self.playID, generation == self.watchdogGeneration else { return }
            self.finishPlay?()
        }
    }

    private func connectIfNeeded(format: AVAudioFormat) {
        if let installedFormat, installedFormat == format, engine.isRunning || player.engine != nil {
            return
        }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        installedFormat = format
    }

    private static func buffer(samples: [Float], sampleRate: Double, padSeconds: Double) -> AVAudioPCMBuffer? {
        let pad = max(0, Int((sampleRate * padSeconds).rounded()))
        let count = samples.count + pad
        guard count > 0 else { return nil }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
              )
        else { return nil }

        buffer.frameLength = buffer.frameCapacity
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            dst.update(from: base, count: source.count)
        }
        if pad > 0 {
            dst.advanced(by: samples.count).update(repeating: 0, count: pad)
        }
        return buffer
    }
}
