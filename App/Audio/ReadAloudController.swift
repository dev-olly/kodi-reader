import AppKit
import AVFoundation
import FluidAudio
import Foundation
import NaturalLanguage
import Observation

/// Owns one listening session and retains only the currently playing audio.
@MainActor
@Observable
final class ReadAloudController: NSObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle, preparing, playing, paused
        case failed(String)
    }

    private static let model = ParadeeManager(
        version: .v12,
        variant: .int8,
        directory: URL.cachesDirectory.appendingPathComponent("KodiReader/Paradee", isDirectory: true)
    )
    private static var modelPreparation: Task<Void, Error>?

    private(set) var phase: Phase = .idle
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    var voice: ParadeeVoice = .afHeart
    /// Reader-wide audio coordination also covers resumes from the popover.
    var beforePlayback: (() -> Bool)?
    @ObservationIgnored var onAnalyticsEvent: ((AnalyticsEventName) -> Void)?
    @ObservationIgnored var onAnalyticsActivityChanged: ((AnalyticsFeatureActivity, Bool) -> Void)?

    var isActive: Bool {
        phase == .preparing || phase == .playing || phase == .paused
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AudioPlaybackDevice?
    @ObservationIgnored private var passages: ArraySlice<String> = []
    @ObservationIgnored private let prepare: @MainActor () async throws -> Void
    @ObservationIgnored private let synthesize: @MainActor (String, ParadeeVoice) async throws -> [Float]
    @ObservationIgnored private let makePlayer: @MainActor (Data) throws -> AudioPlaybackDevice
    @ObservationIgnored private let sampleRate: @MainActor () -> Int
    @ObservationIgnored private var analyticsSessionStarted = false
    @ObservationIgnored private var analyticsListeningActive = false
    @ObservationIgnored private var analyticsResumePending = false
    @ObservationIgnored private var sleepObserver: (NotificationCenter, NSObjectProtocol)?

    init(
        prepare: @escaping @MainActor () async throws -> Void = { try await ReadAloudController.prepareModel() },
        synthesize: @escaping @MainActor (String, ParadeeVoice) async throws -> [Float] = { try await ReadAloudController.model.synthesize(text: $0, voice: $1) },
        playerFactory: @escaping @MainActor (Data) throws -> AudioPlaybackDevice = { try AVAudioPlayer(data: $0) },
        sampleRate: @escaping @MainActor () -> Int = { ReadAloudController.model.sampleRate }
    ) {
        self.prepare = prepare
        self.synthesize = synthesize
        self.makePlayer = playerFactory
        self.sampleRate = sampleRate
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        sleepObserver = (center, observer)
    }

    deinit {
        if let (center, observer) = sleepObserver { center.removeObserver(observer) }
    }

    func start(text: @escaping @MainActor () async -> String?) {
        guard beforePlayback?() != false else { return }
        stop()
        phase = .preparing
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let text = await text()
            guard let self, !Task.isCancelled else { return }
            let passages = Self.passages(in: text ?? "")
            guard !passages.isEmpty else {
                fail("There’s no readable text here.")
                return
            }
            self.passages = passages[...]
            playNext()
        }
    }

    func pause() {
        guard phase == .playing else { return }
        player?.pause()
        setListeningAnalyticsActive(false)
        onAnalyticsEvent?(.ttsListeningPaused)
        phase = .paused
    }

    func resume() {
        guard beforePlayback?() != false else { return }
        guard phase == .paused else { return }
        if let player {
            if player.play() {
                phase = .playing
                onAnalyticsEvent?(.ttsListeningResumed)
                setListeningAnalyticsActive(true)
            } else {
                fail("Couldn’t resume the narration.")
            }
        } else {
            analyticsResumePending = true
            playNext()
        }
    }

    func stop() {
        if analyticsSessionStarted { onAnalyticsEvent?(.ttsListeningStopped) }
        resetPlayback()
    }

    private func resetPlayback() {
        setListeningAnalyticsActive(false)
        analyticsSessionStarted = false
        analyticsResumePending = false
        task?.cancel()
        task = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        passages = []
        phase = .idle
    }

    private func playNext() {
        guard let passage = passages.popFirst() else {
            if analyticsSessionStarted { onAnalyticsEvent?(.ttsListeningCompleted) }
            resetPlayback()
            return
        }

        setListeningAnalyticsActive(false)
        phase = .preparing
        let voice = voice
        let prepare = prepare
        let synthesize = synthesize
        task = Task { [weak self] in
            do {
                try await prepare()
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled {
                    self?.fail("Couldn’t load Paradee. Check your connection and try again.")
                }
                return
            }

            do {
                let samples = try await synthesize(passage, voice)
                try Task.checkCancellation()
                try self?.play(samples)
            } catch {
                if !Task.isCancelled { self?.fail("Couldn’t play the narration. Try again.") }
            }
        }
    }

    private static func prepareModel() async throws {
        // Share the first download across sessions, even if the reader closes mid-download.
        if modelPreparation == nil {
            modelPreparation = Task {
                do {
                    try await model.initialize()
                } catch {
                    modelPreparation = nil
                    throw error
                }
            }
        }
        try await modelPreparation?.value
    }

    private func play(_ samples: [Float]) throws {
        guard beforePlayback?() != false else { stop(); return }
        let audio = Self.wav(samples, sampleRate: sampleRate())
        let player = try makePlayer(audio)
        player.enableRate = true
        player.rate = rate
        player.delegate = self
        self.player = player
        if player.play() {
            phase = .playing
            if !analyticsSessionStarted {
                analyticsSessionStarted = true
                onAnalyticsEvent?(.ttsListeningStarted)
            } else if analyticsResumePending {
                onAnalyticsEvent?(.ttsListeningResumed)
            }
            analyticsResumePending = false
            setListeningAnalyticsActive(true)
        } else {
            fail("Couldn’t start audio playback.")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.playbackFinished(identity: finished, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playbackFinished(identity: identity, successfully: false) }
    }

    /// Identity checking also makes delayed native callbacks harmless after stop.
    func playbackFinished(identity: ObjectIdentifier, successfully: Bool) {
        guard let player, ObjectIdentifier(player) == identity else { return }
        setListeningAnalyticsActive(false)
        self.player = nil
        if !successfully {
            fail("Audio playback was interrupted.")
        } else if phase == .playing || passages.isEmpty {
            playNext()
        }
    }

    private func fail(_ message: String) {
        onAnalyticsEvent?(.ttsListeningFailed)
        resetPlayback()
        phase = .failed(message)
    }

    private func setListeningAnalyticsActive(_ active: Bool) {
        guard analyticsListeningActive != active else { return }
        analyticsListeningActive = active
        onAnalyticsActivityChanged?(.ttsListening, active)
    }

    /// Keep inference and playback bounded even for chapters with long paragraphs.
    static func passages(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english)
        let limit = 400
        var passages: [String] = []
        for paragraph in text.replacingOccurrences(of: "\u{00ad}", with: "").split(whereSeparator: \.isNewline) {
            let text = String(paragraph)
            let paragraphStart = passages.count
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                var remaining = text[range]
                while let bound = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex),
                      bound < remaining.endIndex {
                    let split = remaining[..<bound].lastIndex(where: \.isWhitespace) ?? bound
                    let end = split == remaining.startIndex ? bound : split
                    append(remaining[..<end], paragraphStart: paragraphStart)
                    remaining = remaining[end...]
                }
                append(remaining, paragraphStart: paragraphStart)
                return true
            }
        }
        return passages

        func append(_ slice: Substring, paragraphStart: Int) {
            let text = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            if passages.count > paragraphStart, let previous = passages.last,
               previous.count + 1 + text.count <= limit {
                passages[passages.count - 1] += " " + text
            } else {
                passages.append(text)
            }
        }
    }

    /// Wrap Paradee's mono float samples for AVAudioPlayer's in-memory input.
    private static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        let byteCount = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(byteCount))
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(36 + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2)) // Block alignment
        append(UInt16(16)) // Bits per sample
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        let pcm = samples.map { sample -> Int16 in
            guard sample.isFinite else { return 0 }
            return Int16(min(1, max(-1, sample)) * Float(Int16.max)).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
