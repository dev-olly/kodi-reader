import Foundation
import MediaPlayer
import Observation
import EpubKit
import ReaderUI

enum ReadAloudStatus: Equatable {
    case idle
    case preparing
    case playing
    case paused
}

@MainActor
@Observable
final class ReadAloudController {
    private(set) var status: ReadAloudStatus = .idle
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var downloadProgress: Double?
    private(set) var bookTitle = ""
    private(set) var bookAuthor = ""
    /// Drives the dock progress bar; updated on the highlight timer.
    private(set) var progressTick: TimeInterval = 0

    var isActive: Bool { status != .idle }
    var isPlaying: Bool { status == .playing }

    var chapterProgress: Double {
        guard !utterances.isEmpty else { return 0 }
        let local = localFraction
        return min(1, (Double(index) + local) / Double(utterances.count))
    }

    var chapterElapsed: TimeInterval {
        elapsedBeforeIndex + currentAudioTime()
    }

    var chapterRemaining: TimeInterval? {
        guard let speech = currentSpeech else { return nil }
        let currentDur = duration(of: speech)
        var remaining = max(0, currentDur - currentAudioTime())
        for i in (index + 1)..<utterances.count {
            guard let next = prepared[i] else { return nil }
            remaining += duration(of: next)
        }
        return remaining
    }

    var chapterLabel: String {
        let title = reader?.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return bookTitle
    }

    @ObservationIgnored private let engine = KokoroEngine()
    @ObservationIgnored private let player = ReadAloudPlayer()
    @ObservationIgnored private weak var reader: ReaderController?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTimer: Timer?
    @ObservationIgnored private var utterances: [ReaderUtterance] = []
    @ObservationIgnored private var prepared: [Int: SynthesizedSpeech] = [:]
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var skipDelta = 0
    @ObservationIgnored private var voiceID = ReadAloudVoice.defaultID
    @ObservationIgnored private var currentSpeech: SynthesizedSpeech?
    @ObservationIgnored private var utteranceStartedAt = Date()
    @ObservationIgnored private var elapsedAtPause: TimeInterval = 0
    @ObservationIgnored private var isPausedClock = false
    @ObservationIgnored private var remoteCommandsInstalled = false
    @ObservationIgnored private var enginePrepared = false
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var leftoverSeek: TimeInterval = 0
    @ObservationIgnored private var elapsedBeforeIndex: TimeInterval = 0
    private static let lookaheadCount = 4
    static let skipSeconds: TimeInterval = 15

    func start(
        reader: ReaderController,
        bookTitle: String,
        author: String,
        voiceID: String,
        rate: Double,
        selection: ReaderSelection?,
        position: TextPosition?
    ) {
        stop()
        self.reader = reader
        self.bookTitle = bookTitle
        self.bookAuthor = author
        self.voiceID = voiceID
        player.rate = rate
        errorMessage = nil
        status = .preparing
        statusMessage = "Preparing voice…"
        installRemoteCommandsIfNeeded()

        let startPosition = selection?.locator.start ?? position
        if selection != nil {
            reader.clearSelection()
        }

        runTask = Task { [weak self] in
            await self?.run(from: startPosition)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        highlightTimer?.invalidate()
        highlightTimer = nil
        player.stop()
        reader?.setReadingRange(nil)
        utterances = []
        prepared = [:]
        index = 0
        skipDelta = 0
        leftoverSeek = 0
        elapsedBeforeIndex = 0
        progressTick = 0
        currentSpeech = nil
        downloadProgress = nil
        statusMessage = nil
        status = .idle
        clearNowPlaying()
    }

    func togglePause() {
        switch status {
        case .playing:
            pause()
        case .paused:
            resume()
        case .preparing:
            stop()
        case .idle:
            break
        }
    }

    func pause() {
        guard status == .playing else { return }
        elapsedAtPause = currentAudioTime()
        isPausedClock = true
        player.pause()
        status = .paused
        updateNowPlaying(playing: false)
    }

    func resume() {
        guard status == .paused else { return }
        utteranceStartedAt = Date()
        isPausedClock = false
        player.resume()
        status = .playing
        updateNowPlaying(playing: true)
    }

    func skipForward() {
        skip(by: Self.skipSeconds)
    }

    func skipBack() {
        skip(by: -Self.skipSeconds)
    }

    func skip(by delta: TimeInterval) {
        guard isActive, status == .playing || status == .paused else { return }
        guard let speech = currentSpeech else { return }
        let clipDuration = duration(of: speech)
        let target = currentAudioTime() + delta

        if target >= clipDuration {
            leftoverSeek = target - clipDuration
            skipDelta = 0
            player.skipCurrent()
            return
        }
        if target < 0 {
            let previous = index - 1
            if previous >= 0, let prevSpeech = prepared[previous] {
                let prevDur = duration(of: prevSpeech)
                leftoverSeek = max(0, prevDur + target)
                skipDelta = -2
                player.skipCurrent()
            } else {
                seekWithinCurrent(to: 0)
            }
            return
        }
        seekWithinCurrent(to: target)
    }

    private func seekWithinCurrent(to time: TimeInterval) {
        player.seek(to: time)
        elapsedAtPause = time
        utteranceStartedAt = Date()
        isPausedClock = status == .paused
        progressTick = time
        updateWordHighlight()
    }

    func setRate(_ rate: Double) {
        player.rate = rate
        if status == .playing {
            updateNowPlaying(playing: true)
        }
    }

    func setVoice(_ id: String) {
        guard id != voiceID else { return }
        voiceID = id
        prepared = [:]
        prefetchTask?.cancel()
        prefetchTask = nil
        if status == .playing || status == .paused {
            skipDelta = -1
            player.skipCurrent()
        }
    }

    // MARK: - Run loop

    private func run(from startPosition: TextPosition?) async {
        do {
            await Task.yield()
            try await ensureModel()
            try Task.checkCancellation()
            statusMessage = "Starting…"
            var position = startPosition
            var emptyStreak = 0

            while !Task.isCancelled {
                let chapter = await loadUtterances(from: position)
                position = nil
                if chapter.isEmpty {
                    emptyStreak += 1
                    if emptyStreak > 20 { break }
                    let advanced = await advanceChapter()
                    if !advanced { break }
                    continue
                }
                emptyStreak = 0
                utterances = chapter
                prepared = [:]
                prefetchTask?.cancel()
                prefetchTask = nil
                index = 0
                leftoverSeek = 0
                elapsedBeforeIndex = 0
                startPrefetch()

                while index < utterances.count, !Task.isCancelled {
                    try await speakCurrent()
                    if Task.isCancelled { break }
                    if skipDelta < 0 {
                        if let prev = prepared[max(0, index - 1)] {
                            elapsedBeforeIndex = max(0, elapsedBeforeIndex - duration(of: prev))
                        }
                    } else {
                        elapsedBeforeIndex += currentAudioTime()
                    }
                    index += 1 + skipDelta
                    skipDelta = 0
                    if index < 0 { index = 0 }
                    dropStalePrepared()
                }

                if Task.isCancelled { break }
                if !(await advanceChapter()) { break }
            }
        } catch is CancellationError {
            // Stopped by the user.
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            downloadProgress = nil
            player.stop()
            highlightTimer?.invalidate()
            highlightTimer = nil
            status = .paused
            return
        }
        if !Task.isCancelled {
            stop()
        }
    }

    private func ensureModel() async throws {
        if enginePrepared { return }

        if !KokoroModelStore.isReady {
            statusMessage = "Downloading voice model…"
            downloadProgress = nil
            await Task.yield()
            try await KokoroModelStore.ensureAvailable { [weak self] message, fraction in
                Task { @MainActor in
                    self?.statusMessage = message
                    self?.downloadProgress = fraction
                }
            }
        }

        try Task.checkCancellation()
        downloadProgress = nil
        statusMessage = "Loading voice…"
        await Task.yield()

        let engine = self.engine
        let modelURL = KokoroModelStore.modelPath
        let voicesURL = KokoroModelStore.voicesPath
        try await withTimeout(seconds: 120, error: KokoroModelError.loadTimedOut) {
            try await engine.prepare(modelURL: modelURL, voicesURL: voicesURL)
        }
        enginePrepared = true
    }

    /// Resumes when `work` finishes or `seconds` elapses, whichever is first.
    /// Does not wait for a hung MLX call — that would leave the bar on “Preparing…”.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        error: KokoroModelError,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = TimeoutGate<T>(continuation)
            Task {
                do {
                    gate.settle(.success(try await work()))
                } catch {
                    gate.settle(.failure(error))
                }
            }
            Task {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.settle(.failure(error))
            }
        }
    }

    private func loadUtterances(from position: TextPosition?) async -> [ReaderUtterance] {
        guard let reader else { return [] }
        await waitUntilReady()
        return await withCheckedContinuation { continuation in
            reader.extractUtterances(from: position) { continuation.resume(returning: $0) }
        }
    }

    private func waitUntilReady() async {
        guard let reader else { return }
        let deadline = Date().addingTimeInterval(20)
        while reader.isLoading, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func advanceChapter() async -> Bool {
        guard let reader else { return false }
        let before = reader.spineIndex
        reader.goToNextChapter()
        if reader.spineIndex == before { return false }
        await waitUntilReady()
        return true
    }

    private func startPrefetch() {
        guard prefetchTask == nil else { return }
        prefetchTask = Task { [weak self] in
            await self?.runPrefetch()
            self?.prefetchTask = nil
        }
    }

    /// Keeps `index … index+lookaheadCount` synthesized for the whole chapter.
    /// Sleeps when the window is full instead of exiting, so the next gap is
    /// filled during playback rather than after it.
    private func runPrefetch() async {
        while !Task.isCancelled {
            let current = index
            var next: Int?
            for offset in 0...Self.lookaheadCount {
                let target = current + offset
                guard target >= 0, target < utterances.count else { break }
                if prepared[target] == nil {
                    next = target
                    break
                }
            }
            guard let target = next else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let text = utterances[target].text
            let voice = voiceID
            do {
                let speech = try await engine.synthesize(text: text, voiceID: voice)
                guard !Task.isCancelled, voiceID == voice else { return }
                prepared[target] = speech
                dropStalePrepared()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private func dropStalePrepared() {
        for key in prepared.keys where key < index - 2 {
            prepared.removeValue(forKey: key)
        }
    }

    private func speech(at index: Int) async throws -> SynthesizedSpeech {
        if let ready = prepared[index] { return ready }
        statusMessage = "Loading next sentence…"
        startPrefetch()
        while prepared[index] == nil, !Task.isCancelled {
            if errorMessage != nil {
                throw KokoroModelError.engineUnavailable
            }
            if prefetchTask == nil {
                startPrefetch()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        if let ready = prepared[index] {
            return ready
        }
        throw CancellationError()
    }

    private func speakCurrent() async throws {
        let utterance = utterances[index]
        let synthesized: SynthesizedSpeech
        do {
            synthesized = try await speech(at: index)
        } catch {
            return
        }
        try Task.checkCancellation()

        currentSpeech = synthesized
        let startAt = leftoverSeek
        leftoverSeek = 0
        let clipDuration = duration(of: synthesized)
        if startAt >= clipDuration - 0.02 {
            leftoverSeek = startAt - clipDuration
            currentSpeech = nil
            return
        }
        elapsedAtPause = startAt
        isPausedClock = false
        utteranceStartedAt = Date()
        progressTick = startAt
        highlight(utterance, charStart: nil, charEnd: nil)
        reader?.revealForReading(utterance.start)
        updateNowPlaying(playing: true)
        status = .playing
        statusMessage = nil
        startHighlightTimer()

        await player.play(synthesized, from: startAt)

        highlightTimer?.invalidate()
        highlightTimer = nil
        currentSpeech = nil
    }

    private func duration(of speech: SynthesizedSpeech) -> TimeInterval {
        Double(speech.samples.count) / max(speech.sampleRate, 1)
    }

    private var localFraction: Double {
        guard let speech = currentSpeech else { return 0 }
        let clipDuration = duration(of: speech)
        guard clipDuration > 0 else { return 0 }
        return min(1, max(0, currentAudioTime() / clipDuration))
    }

    // MARK: - Follow-along

    private func startHighlightTimer() {
        highlightTimer?.invalidate()
        highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateWordHighlight() }
        }
    }

    private func currentAudioTime() -> TimeInterval {
        if isPausedClock { return elapsedAtPause }
        let wall = Date().timeIntervalSince(utteranceStartedAt)
        return elapsedAtPause + wall * player.rate
    }

    private func updateWordHighlight() {
        progressTick = currentAudioTime()
        guard index < utterances.count, let speech = currentSpeech else { return }
        let utterance = utterances[index]
        let time = currentAudioTime()
        if let range = Self.characterRange(at: time, tokens: speech.tokens, text: utterance.text) {
            highlight(utterance, charStart: range.lowerBound, charEnd: range.upperBound)
        }
    }

    private func highlight(_ utterance: ReaderUtterance, charStart: Int?, charEnd: Int?) {
        var locator = utterance.locator
        locator.spineIndex = reader?.spineIndex ?? 0
        reader?.setReadingRange(locator, charStart: charStart, charEnd: charEnd)
    }

    /// Maps audio time onto character offsets in the original utterance text.
    static func characterRange(
        at time: TimeInterval,
        tokens: [SpeechToken],
        text: String
    ) -> Range<Int>? {
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        let ns = text as NSString
        for token in tokens {
            let piece = token.text
            let found: Range<Int>
            if piece.isEmpty {
                found = cursor ..< cursor
            } else {
                let search = NSRange(location: cursor, length: max(0, ns.length - cursor))
                let match = ns.range(of: piece, options: [], range: search)
                if match.location == NSNotFound {
                    found = cursor ..< min(ns.length, cursor + piece.count)
                } else {
                    found = match.location ..< (match.location + match.length)
                    cursor = found.upperBound
                }
            }
            if let start = token.start, let end = token.end, time >= start, time < end {
                return found.lowerBound < found.upperBound ? found : nil
            }
            if !token.whitespace.isEmpty {
                cursor = min(ns.length, cursor + token.whitespace.count)
            }
        }
        return nil
    }

    // MARK: - Now Playing

    private func installRemoteCommandsIfNeeded() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBack() }
            return .success
        }
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    private func updateNowPlaying(playing: Bool) {
        let chapter = reader?.chapterTitle ?? bookTitle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapter,
            MPMediaItemPropertyArtist: bookAuthor,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? player.rate : 0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

/// First `settle` wins so a hung MLX prepare cannot block the timeout path.
private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func settle(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(with: result)
        continuation = nil
    }
}
