import AppKit
import AVFoundation
import Foundation
import Observation

struct AudioRecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let waveform: [Float]
}

/// The small recorder interface also permits permission/error tests without
/// opening the microphone or asking macOS for access.
protocol AudioRecordingDevice: AnyObject {
    var delegate: AVAudioRecorderDelegate? { get set }
    var url: URL { get }
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var isMeteringEnabled: Bool { get set }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func pause()
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: AudioRecordingDevice {}

/// Playback output is replaceable in lifecycle tests, which never open speakers.
protocol AudioPlaybackDevice: AnyObject {
    var delegate: AVAudioPlayerDelegate? { get set }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioPlaybackDevice {}

/// One microphone/playback owner for the application. Finished takes remain on
/// disk until the caller has durably saved both the file and its note reference.
@MainActor
@Observable
final class AudioNoteController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle, requestingPermission, recording, paused, readyToSave
        case failed(String)
    }

    enum Failure: LocalizedError {
        case microphoneDenied, busy, startFailed, noRecording, emptyRecording, playbackUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access is off. Allow Kodi Reader in System Settings → Privacy & Security → Microphone, then try again."
            case .busy: return "Finish or discard the current recording first."
            case .startFailed: return "Couldn’t start recording. Check that a microphone is connected and try again."
            case .noRecording: return "There’s no recording to save."
            case .emptyRecording: return "The recording is empty. Record a thought before saving."
            case .playbackUnavailable: return "This recording is unavailable. Wait for it to download or try syncing again."
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var recordingID: UUID?
    private(set) var recordingAnnotationID: UUID?
    private(set) var elapsed: TimeInterval = 0
    private(set) var inputLevel: Float = 0
    private(set) var waveform: [Float] = []
    private(set) var errorMessage: String?
    private(set) var playbackID: UUID?
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }
    var canFinish: Bool { recordingID != nil && elapsed > 0 && phase != .requestingPermission }
    var progress: Double { duration > 0 ? min(1, max(0, playbackTime / duration)) : 0 }

    @ObservationIgnored var beforeAudioActivity: (() -> Void)?
    @ObservationIgnored var onRecordingStopped: (() -> Void)?
    @ObservationIgnored var onAnalyticsEvent: ((AnalyticsEventName) -> Void)?
    @ObservationIgnored var onAnalyticsActivityChanged: ((AnalyticsFeatureActivity, Bool) -> Void)?
    @ObservationIgnored private let requestPermission: () async -> Bool
    @ObservationIgnored private let makeRecorder: (URL, [String: Any]) throws -> AudioRecordingDevice
    @ObservationIgnored private let draftDirectory: URL
    @ObservationIgnored private var recorder: AudioRecordingDevice?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var draftURL: URL?
    @ObservationIgnored private var finalized: AudioRecordingResult?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var analyticsRecordingBegan = false
    @ObservationIgnored private var analyticsRecordingActive = false

    init(
        permission: @escaping () async -> Bool = AudioNoteController.microphonePermission,
        recorderFactory: @escaping (URL, [String: Any]) throws -> AudioRecordingDevice = { try AVAudioRecorder(url: $0, settings: $1) },
        draftDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("KodiAudioDrafts", isDirectory: true)
    ) {
        self.requestPermission = permission
        self.makeRecorder = recorderFactory
        self.draftDirectory = draftDirectory
        super.init()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleep = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.stopPlayback()
                self?.interruptRecording("Recording stopped before sleep. Your take is ready to save.")
            }
        }
        observers.append((workspaceCenter, sleep))
        let devices = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.object as? AVCaptureDevice)?.hasMediaType(.audio) == true else { return }
            Task { @MainActor in self?.interruptRecording("The microphone disconnected. Your take is ready to save.") }
        }
        observers.append((.default, devices))
    }

    deinit {
        timer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }

    nonisolated private static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    func startRecording(id: UUID, annotationID: UUID) async throws {
        try Task.checkCancellation()
        guard recordingID == nil else { throw Failure.busy }
        stopPlayback()
        errorMessage = nil
        recordingID = id
        recordingAnnotationID = annotationID
        elapsed = 0
        inputLevel = 0
        waveform = []
        phase = .requestingPermission
        let token = UUID()
        session = token
        let granted = await requestPermission()
        guard session == token, recordingID == id else { throw CancellationError() }
        if Task.isCancelled { discardRecording(); throw CancellationError() }
        guard granted else {
            resetRecording()
            errorMessage = Failure.microphoneDenied.localizedDescription
            onAnalyticsEvent?(.audioRecordingFailed)
            throw Failure.microphoneDenied
        }
        do {
            beforeAudioActivity?()
            let directory = draftDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("recording.m4a")
            draftURL = url
            let device = try makeRecorder(url, [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            device.delegate = self
            device.isMeteringEnabled = true
            recorder = device
            guard device.prepareToRecord(), device.record() else { throw Failure.startFailed }
            phase = .recording
            analyticsRecordingBegan = true
            onAnalyticsEvent?(.audioRecordingStarted)
            setRecordingAnalyticsActive(true)
            startTimer()
        } catch {
            discardRecording()
            errorMessage = error.localizedDescription
            onAnalyticsEvent?(.audioRecordingFailed)
            throw error
        }
    }

    func pauseRecording() {
        guard phase == .recording, let recorder else { return }
        updateRecording()
        recorder.pause()
        setRecordingAnalyticsActive(false)
        onAnalyticsEvent?(.audioRecordingPaused)
        inputLevel = 0
        phase = .paused
        stopTimer()
    }

    func resumeRecording() throws {
        guard phase == .paused, let recorder else { return }
        beforeAudioActivity?()
        guard recorder.record() else {
            let error = Failure.startFailed
            errorMessage = error.localizedDescription
            onAnalyticsEvent?(.audioRecordingFailed)
            throw error
        }
        errorMessage = nil
        phase = .recording
        onAnalyticsEvent?(.audioRecordingResumed)
        setRecordingAnalyticsActive(true)
        startTimer()
    }

    func finishRecording() async throws -> AudioRecordingResult {
        if let finalized { return finalized }
        guard let id = recordingID, let url = draftURL else { throw Failure.noRecording }
        guard phase != .requestingPermission else { throw Failure.busy }
        let token = session
        updateRecording()
        setRecordingAnalyticsActive(false)
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        stopTimer()
        inputLevel = 0
        phase = .readyToSave
        do {
            let file = try AVAudioFile(forReading: url)
            let length = Double(file.length) / file.processingFormat.sampleRate
            guard length.isFinite, length > 0 else { throw Failure.emptyRecording }
            let fallback = waveform
            let samples = await Task.detached(priority: .utility) { Self.waveformSamples(at: url) }.value
            guard session == token, recordingID == id else { throw CancellationError() }
            let result = AudioRecordingResult(url: url, duration: length, waveform: samples.isEmpty ? fallback : samples)
            finalized = result
            elapsed = length
            waveform = result.waveform
            errorMessage = nil
            phase = .readyToSave
            return result
        } catch {
            if session == token, recordingID == id {
                phase = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
                onAnalyticsEvent?(.audioRecordingFailed)
            }
            throw error
        }
    }

    func markRecordingSaved() {
        if analyticsRecordingBegan, finalized != nil {
            onAnalyticsEvent?(.audioRecordingSaved)
            analyticsRecordingBegan = false
        }
        discardRecording()
    }

    func discardRecording() {
        setRecordingAnalyticsActive(false)
        if analyticsRecordingBegan {
            onAnalyticsEvent?(.audioRecordingDiscarded)
            analyticsRecordingBegan = false
        }
        session = UUID()
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        stopTimer()
        if let url = draftURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        resetRecording()
        errorMessage = nil
    }

    private func resetRecording() {
        phase = .idle
        recordingID = nil
        recordingAnnotationID = nil
        elapsed = 0
        inputLevel = 0
        waveform = []
        finalized = nil
        draftURL = nil
    }

    private func setRecordingAnalyticsActive(_ active: Bool) {
        guard analyticsRecordingActive != active else { return }
        analyticsRecordingActive = active
        onAnalyticsActivityChanged?(.audioRecording, active)
    }

    func play(id: UUID, url: URL) throws {
        guard recordingID == nil else { throw Failure.busy }
        errorMessage = nil
        if playbackID == id, let player {
            if isPlaying { pausePlayback(); return }
            beforeAudioActivity?()
            if player.currentTime >= player.duration { player.currentTime = 0 }
            playbackTime = player.currentTime
            guard player.play() else { throw Failure.playbackUnavailable }
            isPlaying = true
            startTimer()
            return
        }
        try preparePlayback(id: id, url: url)
        guard let player else { throw Failure.playbackUnavailable }
        beforeAudioActivity?()
        guard player.play() else { stopPlayback(); throw Failure.playbackUnavailable }
        isPlaying = true
        startTimer()
    }

    /// Loading a clip for seeking must not briefly start its audio output.
    func preparePlayback(id: UUID, url: URL) throws {
        guard recordingID == nil else { throw Failure.busy }
        if playbackID == id, player != nil { return }
        stopPlayback()
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.playbackUnavailable }
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.prepareToPlay() else { throw Failure.playbackUnavailable }
        self.player = player
        playbackID = id
        duration = player.duration
        playbackTime = 0
        isPlaying = false
    }

    func pausePlayback() {
        player?.pause()
        playbackTime = player?.currentTime ?? playbackTime
        isPlaying = false
        stopTimer()
    }

    func seek(to fraction: Double) {
        guard fraction.isFinite, let player else { return }
        let position = min(1, max(0, fraction)) * player.duration
        player.currentTime = position
        playbackTime = position
    }

    func stopPlayback() {
        player?.delegate = nil
        player?.stop()
        player = nil
        playbackID = nil
        playbackTime = 0
        duration = 0
        isPlaying = false
        if recordingID == nil { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .recording { self.updateRecording() }
                if self.isPlaying { self.playbackTime = self.player?.currentTime ?? self.playbackTime }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func updateRecording() {
        guard let recorder, phase == .recording || phase == .paused else { return }
        elapsed = max(elapsed, recorder.currentTime)
        recorder.updateMeters()
        inputLevel = Self.normalizedLevel(recorder.averagePower(forChannel: 0))
        if phase == .recording {
            waveform.append(inputLevel)
            if waveform.count > 128 {
                waveform = stride(from: 0, to: waveform.count - 1, by: 2).map { max(waveform[$0], waveform[$0 + 1]) }
            }
        }
    }

    private func interruptRecording(_ message: String, failed: Bool = true) {
        guard recordingID != nil, phase != .readyToSave, phase != .requestingPermission else { return }
        updateRecording()
        setRecordingAnalyticsActive(false)
        if failed { onAnalyticsEvent?(.audioRecordingFailed) }
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        stopTimer()
        inputLevel = 0
        errorMessage = message
        phase = .readyToSave
        onRecordingStopped?()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.recorderStopped(identity: identity,
                message: flag ? "Recording finished. Your take is ready to save." : "Recording was interrupted. Your take is ready to save.", failed: !flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identity = ObjectIdentifier(recorder)
        let message = error?.localizedDescription ?? "Recording was interrupted. Your take is ready to save."
        Task { @MainActor [weak self] in
            self?.recorderStopped(identity: identity, message: message)
        }
    }

    /// Both native delegate callbacks enter here after hopping onto the main
    /// actor. Comparing the device identity rejects callbacks from an old take.
    func recorderStopped(identity: ObjectIdentifier, message: String, failed: Bool = true) {
        guard let current = recorder, ObjectIdentifier(current) == identity else { return }
        interruptRecording(message, failed: failed)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.playbackTime = flag ? self.duration : current.currentTime
            self.isPlaying = false
            self.stopTimer()
            if !flag { self.errorMessage = "Audio playback was interrupted." }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        let message = error?.localizedDescription ?? "This recording could not be played."
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.playbackTime = current.currentTime
            self.isPlaying = false
            self.errorMessage = message
            self.stopTimer()
        }
    }

    nonisolated static func normalizedLevel(_ decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return min(1, max(0, pow(10, decibels / 40)))
    }

    nonisolated private static func waveformSamples(at url: URL) -> [Float] {
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return [] }
            let count = 64
            var sums = [Double](repeating: 0, count: count)
            var samples = [Int](repeating: 0, count: count)
            let total = file.length
            while file.framePosition < total {
                let start = file.framePosition
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData?.pointee else { break }
                for index in 0..<Int(buffer.frameLength) {
                    let bucket = min(count - 1, Int(Double(start + Int64(index)) / Double(total) * Double(count)))
                    let value = Double(channel[index])
                    sums[bucket] += value * value
                    samples[bucket] += 1
                }
            }
            return zip(sums, samples).map { sum, n in
                guard n > 0, sum > 0 else { return 0 }
                return normalizedLevel(Float(20 * log10(sqrt(sum / Double(n)))))
            }
        } catch { return [] }
    }
}
