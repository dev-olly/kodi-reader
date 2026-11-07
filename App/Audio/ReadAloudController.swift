import AppKit
import AVFoundation
import FluidAudio
import Foundation
import NaturalLanguage
import Observation

/// Owns one listening session, a bounded replay cache, and one passage of lookahead.
@MainActor
@Observable
final class ReadAloudController: NSObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle, preparing, playing, paused
        case failed(String)
    }

    struct Chapter {
        let passages: [String]
        var onLoad: @MainActor () -> Void = {}
    }

    private static let model = ParadeeManager(
        version: .v12,
        variant: .int8,
        directory: URL.cachesDirectory.appendingPathComponent("KodiReader/Paradee", isDirectory: true)
    )
    private static var modelPreparation: Task<Void, Error>?

    private(set) var phase: Phase = .idle
    private(set) var passageIndex = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var durations: [TimeInterval] = []
    private(set) var isFinished = false
    private(set) var hasEstimatedDuration = true
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    var voice: ParadeeVoice = .afHeart {
        didSet {
            guard voice != oldValue, !texts.isEmpty else { return }
            let offset = player?.currentTime ?? 0
            let paused = phase != .playing && phase != .preparing
            cache = [:]
            knownDurations = []
            durations = texts.map(Self.estimatedDuration)
            hasEstimatedDuration = true
            playPassage(at: passageIndex, offset: offset, paused: paused)
        }
    }
    var beforePlayback: (() -> Bool)?
    @ObservationIgnored var onAnalyticsEvent: ((AnalyticsEventName) -> Void)?
    @ObservationIgnored var onAnalyticsActivityChanged: ((AnalyticsFeatureActivity, Bool) -> Void)?
    @ObservationIgnored var onPassageChanged: ((Int?) -> Void)?
    @ObservationIgnored var loadNextChapter: (@MainActor () async throws -> Chapter?)?

    var isActive: Bool { phase == .preparing || phase == .playing || phase == .paused }
    var hasSession: Bool { !durations.isEmpty }
    var duration: TimeInterval { durations.reduce(0, +) }
    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }
    var remaining: TimeInterval { max(0, duration - elapsed) / Double(rate) }

    private struct AudioSegment {
        let data: Data
        let duration: TimeInterval
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<AudioSegment, Error>?
    @ObservationIgnored private var prefetchIndex: Int?
    @ObservationIgnored private var cache: [Int: AudioSegment] = [:]
    @ObservationIgnored private var knownDurations: Set<Int> = []
    @ObservationIgnored private var texts: [String] = []
    @ObservationIgnored private var awaitingChapter = false
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var player: AudioPlaybackDevice?
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
        start(passages: { Self.passages(in: await text() ?? "") })
    }

    func start(passages: @escaping @MainActor () async -> [String]?) {
        guard beforePlayback?() != false else { return }
        stop()
        phase = .preparing
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let passages = await passages()
            guard let self, !Task.isCancelled else { return }
            guard let passages, !passages.isEmpty else {
                fail("There’s no readable text here.")
                return
            }
            install(passages)
            task = nil
            playPassage(at: 0)
        }
    }

    func pause() {
        guard phase == .playing || phase == .preparing else { return }
        pauseRequested = true
        player?.pause()
        if player != nil { updateElapsed() }
        progressTask?.cancel()
        setListeningAnalyticsActive(false)
        if analyticsSessionStarted { onAnalyticsEvent?(.ttsListeningPaused) }
        phase = .paused
    }

    func resume() {
        guard phase == .paused, beforePlayback?() != false else { return }
        pauseRequested = false
        analyticsResumePending = analyticsSessionStarted
        if player != nil {
            beginPlayback()
            if phase == .playing { onPassageChanged?(passageIndex) }
        } else if task != nil {
            phase = .preparing
        } else {
            playNext()
        }
    }

    func retry() {
        guard !texts.isEmpty else { return }
        if awaitingChapter { playNext() }
        else { playPassage(at: passageIndex) }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: elapsed + seconds * Double(rate))
    }

    func seek(to time: TimeInterval) {
        guard hasSession, beforePlayback?() != false else { return }
        let target = min(max(0, time), max(0, duration - 0.01))
        var index = 0
        var start: TimeInterval = 0
        while index < durations.count - 1, start + durations[index] <= target {
            start += durations[index]
            index += 1
        }
        if index == passageIndex, let player {
            player.currentTime = min(target - start, max(0, player.duration - 0.01))
            updateElapsed()
        } else {
            let paused = phase == .paused
            playPassage(at: index, offset: target - start, paused: paused)
        }
    }

    func stop() {
        if analyticsSessionStarted { onAnalyticsEvent?(.ttsListeningStopped) }
        resetPlayback()
    }

    private func install(_ passages: [String]) {
        texts = passages
        passageIndex = 0
        elapsed = 0
        durations = passages.map(Self.estimatedDuration)
        hasEstimatedDuration = true
        knownDurations = []
        cache = [:]
        isFinished = false
    }

    private func resetPlayback(clearSession: Bool = true) {
        setListeningAnalyticsActive(false)
        analyticsSessionStarted = false
        analyticsResumePending = false
        pauseRequested = false
        task?.cancel()
        task = nil
        progressTask?.cancel()
        progressTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchIndex = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        cache = [:]
        if clearSession {
            awaitingChapter = false
            texts = []
            durations = []
            knownDurations = []
            elapsed = 0
            passageIndex = 0
            isFinished = false
        }
        onPassageChanged?(nil)
        phase = .idle
    }

    private func playNext() {
        if passageIndex + 1 < texts.count {
            playPassage(at: passageIndex + 1)
            return
        }
        setListeningAnalyticsActive(false)
        guard loadNextChapter != nil else { finishSession(); return }
        awaitingChapter = true
        phase = .preparing
        task = Task { [weak self] in
            do {
                let chapter = try await self?.loadNextChapter?()
                guard let self, !Task.isCancelled else { return }
                if let chapter, !chapter.passages.isEmpty {
                    chapter.onLoad()
                    install(chapter.passages)
                    task = nil
                    playPassage(at: 0)
                } else {
                    finishSession()
                }
            } catch {
                if !Task.isCancelled { self?.fail("Couldn’t open the next chapter. Try again.") }
            }
        }
    }

    private func finishSession() {
        awaitingChapter = false
        if analyticsSessionStarted { onAnalyticsEvent?(.ttsListeningCompleted) }
        resetPlayback(clearSession: false)
        elapsed = duration
        isFinished = true
    }

    private func playPassage(at index: Int, offset: TimeInterval = 0, paused: Bool? = nil) {
        guard texts.indices.contains(index) else { return }
        if let paused { pauseRequested = paused }
        awaitingChapter = false
        task?.cancel()
        progressTask?.cancel()
        player?.delegate = nil
        player?.stop()
        player = nil
        setListeningAnalyticsActive(false)
        passageIndex = index
        elapsed = durations.prefix(index).reduce(0, +) + offset
        isFinished = false
        phase = pauseRequested ? .paused : .preparing
        let upcoming = prefetchIndex == index ? prefetchTask : nil
        if upcoming == nil { prefetchTask?.cancel() }
        prefetchTask = nil
        prefetchIndex = nil
        let cached = cache[index]
        let text = texts[index]
        let voice = voice
        let prepare = prepare
        let synthesize = synthesize
        let sampleRate = sampleRate()
        task = Task { [weak self] in
            do {
                try await prepare()
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled { self?.fail("Couldn’t prepare your voice. Check your connection and try again.") }
                return
            }
            do {
                let audio: AudioSegment
                if let cached {
                    audio = cached
                } else if let upcoming {
                    audio = try await upcoming.value
                } else {
                    let samples = try await synthesize(text, voice)
                    audio = AudioSegment(data: Self.wav(samples, sampleRate: sampleRate),
                                         duration: Double(samples.count) / Double(sampleRate))
                }
                try Task.checkCancellation()
                try self?.play(audio, at: index, offset: offset)
            } catch {
                if !Task.isCancelled { self?.fail("Couldn’t play this passage. Try again.") }
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

    private func play(_ audio: AudioSegment, at index: Int, offset: TimeInterval) throws {
        guard beforePlayback?() != false else { stop(); return }
        task = nil
        let player = try makePlayer(audio.data)
        player.enableRate = true
        player.rate = rate
        player.currentTime = min(max(0, offset), max(0, player.duration - 0.01))
        player.delegate = self
        self.player = player
        durations[index] = player.duration
        knownDurations.insert(index)
        hasEstimatedDuration = knownDurations.count < texts.count
        cache[index] = audio
        cache = cache.filter { abs($0.key - index) <= 2 }
        updateElapsed()
        if pauseRequested {
            phase = .paused
        } else {
            beginPlayback()
        }
        onPassageChanged?(index)
        prefetch(after: index)
    }

    private func beginPlayback() {
        guard player?.play() == true else { fail("Couldn’t start audio playback."); return }
        phase = .playing
        if !analyticsSessionStarted {
            analyticsSessionStarted = true
            onAnalyticsEvent?(.ttsListeningStarted)
        } else if analyticsResumePending {
            onAnalyticsEvent?(.ttsListeningResumed)
        }
        analyticsResumePending = false
        setListeningAnalyticsActive(true)
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.updateElapsed()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    private func prefetch(after index: Int) {
        let next = index + 1
        guard texts.indices.contains(next), cache[next] == nil else { return }
        let text = texts[next]
        let voice = voice
        let synthesize = synthesize
        let sampleRate = sampleRate()
        prefetchIndex = next
        prefetchTask = Task { [weak self] in
            let samples = try await synthesize(text, voice)
            try Task.checkCancellation()
            let audio = AudioSegment(data: Self.wav(samples, sampleRate: sampleRate),
                                     duration: Double(samples.count) / Double(sampleRate))
            if let self, durations.indices.contains(next) {
                cache[next] = audio
                durations[next] = audio.duration
                knownDurations.insert(next)
                hasEstimatedDuration = knownDurations.count < texts.count
            }
            return audio
        }
    }

    private func updateElapsed() {
        elapsed = durations.prefix(passageIndex).reduce(0, +) + (player?.currentTime ?? 0)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playbackFinished(identity: finished, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playbackFinished(identity: identity, successfully: false) }
    }

    func playbackFinished(identity: ObjectIdentifier, successfully: Bool) {
        guard let player, ObjectIdentifier(player) == identity else { return }
        setListeningAnalyticsActive(false)
        progressTask?.cancel()
        self.player = nil
        if !successfully {
            fail("Audio playback was interrupted.")
        } else if phase == .playing {
            playNext()
        }
    }

    private func fail(_ message: String) {
        onAnalyticsEvent?(.ttsListeningFailed)
        resetPlayback(clearSession: false)
        phase = .failed(message)
    }

    private func setListeningAnalyticsActive(_ active: Bool) {
        guard analyticsListeningActive != active else { return }
        analyticsListeningActive = active
        onAnalyticsActivityChanged?(.ttsListening, active)
    }

    private static func estimatedDuration(_ text: String) -> TimeInterval {
        max(1, Double(text.split(whereSeparator: \.isWhitespace).count) / 2.6)
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
