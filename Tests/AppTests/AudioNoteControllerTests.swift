import AppKit
import AVFoundation
import Foundation

/// A hardware-free executable harness. It generates its own short AAC fixture;
/// no test opens a microphone, asks for permission, or starts audio playback.
@main struct AudioNoteControllerTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KodiAudioTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var factoryCalls = 0
        let denied = AudioNoteController(permission: { false }, recorderFactory: { url, _ in
            factoryCalls += 1
            return StubRecorder(url: url)
        }, draftDirectory: root)
        let deniedAnalytics = RecordingAnalyticsSpy(denied)
        do {
            try await denied.startRecording(id: UUID(), annotationID: UUID())
            assertionFailure("Denied permission should fail")
        } catch AudioNoteController.Failure.microphoneDenied {}
        assert(factoryCalls == 0 && denied.recordingID == nil && denied.errorMessage != nil)
        assert(deniedAnalytics.events == [.audioRecordingFailed] && deniedAnalytics.activity.isEmpty)

        let broken = AudioNoteController(permission: { true }, recorderFactory: { _, _ in throw TestFailure.unavailable }, draftDirectory: root)
        let brokenAnalytics = RecordingAnalyticsSpy(broken)
        do {
            try await broken.startRecording(id: UUID(), annotationID: UUID())
            assertionFailure("Missing device should fail")
        } catch TestFailure.unavailable {}
        assert(broken.recordingID == nil && broken.errorMessage != nil)
        assert(brokenAnalytics.events == [.audioRecordingFailed] && brokenAnalytics.activity.isEmpty)

        var device: StubRecorder?
        var suspendedNarration = 0
        let controller = AudioNoteController(permission: { true }, recorderFactory: { url, _ in
            let recorder = StubRecorder(url: url)
            device = recorder
            return recorder
        }, draftDirectory: root)
        let recordingAnalytics = RecordingAnalyticsSpy(controller)
        controller.beforeAudioActivity = { suspendedNarration += 1 }
        let id = UUID(), noteID = UUID()
        try await controller.startRecording(id: id, annotationID: noteID)
        assert(controller.isRecording && controller.recordingID == id && controller.recordingAnnotationID == noteID)
        assert(suspendedNarration == 1)
        controller.pauseRecording()
        assert(controller.isPaused && !controller.isRecording)
        try controller.resumeRecording()
        assert(controller.isRecording && suspendedNarration == 2 && device?.starts == 2)
        let result = try await controller.finishRecording()
        assert(result.duration > 0 && result.waveform.count == 64)
        assert(result.waveform.allSatisfy { $0.isFinite && (0...1).contains($0) })
        assert(result.waveform.contains { $0 > 0.1 })
        assert(controller.phase == .readyToSave && controller.recordingID == id)
        assert(FileManager.default.fileExists(atPath: result.url.path))
        let retry = try await controller.finishRecording()
        assert(retry.url == result.url && retry.duration == result.duration)
        assert(recordingAnalytics.events == [.audioRecordingStarted, .audioRecordingPaused, .audioRecordingResumed])
        assert(recordingAnalytics.activity == [true, false, true, false])
        do {
            try await controller.startRecording(id: UUID(), annotationID: noteID)
            assertionFailure("Unsaved take must be retained")
        } catch AudioNoteController.Failure.busy {}
        controller.markRecordingSaved()
        assert(controller.recordingID == nil && controller.phase == .idle)
        assert(!FileManager.default.fileExists(atPath: result.url.path))
        assert(recordingAnalytics.events == [.audioRecordingStarted, .audioRecordingPaused, .audioRecordingResumed, .audioRecordingSaved])
        controller.markRecordingSaved()
        assert(recordingAnalytics.events.filter { $0 == .audioRecordingSaved }.count == 1)

        try await controller.startRecording(id: UUID(), annotationID: noteID)
        let discardURL = device!.url
        controller.discardRecording()
        assert(controller.phase == .idle && !FileManager.default.fileExists(atPath: discardURL.path))
        assert(recordingAnalytics.events.suffix(2) == [.audioRecordingStarted, .audioRecordingDiscarded])
        assert(recordingAnalytics.activity.suffix(2) == [true, false])

        // Exercise the identity-checked handler used by both native recorder
        // delegates, without constructing an AVAudioRecorder or opening input.
        var recoveryDevice: StubRecorder?
        var stopped = 0
        let recovery = AudioNoteController(permission: { true }, recorderFactory: { url, _ in
            let device = StubRecorder(url: url)
            recoveryDevice = device
            return device
        }, draftDirectory: root)
        let recoveryAnalytics = RecordingAnalyticsSpy(recovery)
        recovery.onRecordingStopped = { stopped += 1 }
        let interruptedID = UUID()
        try await recovery.startRecording(id: interruptedID, annotationID: noteID)
        let oldDevice = recoveryDevice!
        let interruptedBytes = try Data(contentsOf: oldDevice.url)
        recovery.recorderStopped(identity: ObjectIdentifier(oldDevice), message: "Recording was interrupted. Your take is ready to save.")
        assert(stopped == 1 && recovery.phase == .readyToSave)
        assert(recoveryAnalytics.events == [.audioRecordingStarted, .audioRecordingFailed])
        assert(recoveryAnalytics.activity == [true, false])
        assert(!recovery.isRecording && recovery.recordingID == interruptedID && recovery.recordingAnnotationID == noteID)
        assert(recovery.errorMessage != nil && recovery.canFinish)
        let interruptedBytesAfterStop = try Data(contentsOf: oldDevice.url)
        assert(interruptedBytesAfterStop == interruptedBytes)
        let rescued = try await recovery.finishRecording()
        // A failed external note checkpoint leaves this result and its bytes
        // intact. A second Done uses the same finalized result for retry.
        let rescueRetry = try await recovery.finishRecording()
        assert(rescued.url == rescueRetry.url && rescued.duration == rescueRetry.duration)
        let retryBytes = try Data(contentsOf: rescued.url)
        assert(retryBytes == interruptedBytes)
        recovery.markRecordingSaved()
        assert(!FileManager.default.fileExists(atPath: rescued.url.path))

        let encoderID = UUID()
        try await recovery.startRecording(id: encoderID, annotationID: noteID)
        // A delayed callback from the preceding recorder must not end this take.
        recovery.recorderStopped(identity: ObjectIdentifier(oldDevice), message: "Stale failure")
        assert(stopped == 1 && recovery.isRecording && recovery.recordingID == encoderID)
        assert(recoveryAnalytics.events.filter { $0 == .audioRecordingFailed }.count == 1)
        let failingDevice = recoveryDevice!
        let encoderFailure = NSError(domain: "AudioFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Fixture encoder interruption"])
        recovery.recorderStopped(identity: ObjectIdentifier(failingDevice), message: encoderFailure.localizedDescription)
        assert(stopped == 2 && recovery.phase == .readyToSave && recovery.recordingID == encoderID)
        assert(recovery.errorMessage == encoderFailure.localizedDescription)
        let encoderRescue = try await recovery.finishRecording()
        assert(encoderRescue.duration > 0 && FileManager.default.fileExists(atPath: encoderRescue.url.path))
        recovery.discardRecording()

        let sleepingID = UUID()
        try await recovery.startRecording(id: sleepingID, annotationID: noteID)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let sleepDeadline = Date().addingTimeInterval(2)
        while stopped < 3 && Date() < sleepDeadline { await Task.yield() }
        assert(stopped == 3 && recovery.phase == .readyToSave && recovery.recordingID == sleepingID)
        assert(recoveryAnalytics.activity.last == false)
        let sleepRescue = try await recovery.finishRecording()
        assert(sleepRescue.duration > 0 && FileManager.default.fileExists(atPath: sleepRescue.url.path))
        recovery.discardRecording()

        // Waveform extraction awaits background file decoding. Discard while a
        // finish is queued or in flight must never resurrect the take afterward.
        var cancellationDevice: StubRecorder?
        let cancellingFinish = AudioNoteController(permission: { true }, recorderFactory: { url, _ in
            let device = StubRecorder(url: url, fixtureFrames: 441_000)
            cancellationDevice = device
            return device
        }, draftDirectory: root)
        try await cancellingFinish.startRecording(id: UUID(), annotationID: noteID)
        let cancelledURL = cancellationDevice!.url
        let finish = Task { @MainActor in try await cancellingFinish.finishRecording() }
        let finishDeadline = Date().addingTimeInterval(2)
        while cancellingFinish.phase == .recording && Date() < finishDeadline { await Task.yield() }
        assert(cancellingFinish.phase == .readyToSave)
        cancellingFinish.discardRecording()
        do { _ = try await finish.value } catch is CancellationError {}
        assert(cancellingFinish.phase == .idle && cancellingFinish.recordingID == nil)
        assert(!FileManager.default.fileExists(atPath: cancelledURL.path))

        let empty = AudioNoteController(permission: { true }, recorderFactory: { url, _ in
            StubRecorder(url: url, writeFixture: false)
        }, draftDirectory: root)
        try await empty.startRecording(id: UUID(), annotationID: noteID)
        do {
            _ = try await empty.finishRecording()
            assertionFailure("A missing/empty encoded take must not be published")
        } catch {}
        assert(empty.recordingID != nil && empty.errorMessage != nil)
        empty.discardRecording()

        var permissionReply: CheckedContinuation<Bool, Never>?
        var staleFactoryCalls = 0
        let pending = AudioNoteController(permission: {
            await withCheckedContinuation { permissionReply = $0 }
        }, recorderFactory: { url, _ in
            staleFactoryCalls += 1
            return StubRecorder(url: url)
        }, draftDirectory: root)
        let pendingAnalytics = RecordingAnalyticsSpy(pending)
        let start = Task { @MainActor in try await pending.startRecording(id: UUID(), annotationID: noteID) }
        while permissionReply == nil { await Task.yield() }
        pending.discardRecording()
        permissionReply!.resume(returning: true)
        do { try await start.value; assertionFailure("Cancelled permission request must stay cancelled") }
        catch is CancellationError {}
        assert(pending.recordingID == nil && staleFactoryCalls == 0)
        assert(pendingAnalytics.events.isEmpty && pendingAnalytics.activity.isEmpty)

        var retryDevice: StubRecorder?
        let retrying = AudioNoteController(permission: { true }, recorderFactory: { url, _ in
            let device = StubRecorder(url: url)
            retryDevice = device
            return device
        }, draftDirectory: root)
        let retryAnalytics = RecordingAnalyticsSpy(retrying)
        try await retrying.startRecording(id: UUID(), annotationID: noteID)
        retrying.pauseRecording()
        retryDevice!.canRecord = false
        do { try retrying.resumeRecording(); assertionFailure("Failed resume must remain paused") }
        catch AudioNoteController.Failure.startFailed {}
        assert(retrying.isPaused)
        assert(retryAnalytics.events == [.audioRecordingStarted, .audioRecordingPaused, .audioRecordingFailed])
        assert(retryAnalytics.activity == [true, false])
        retrying.discardRecording()

        do {
            try controller.play(id: UUID(), url: root.appendingPathComponent("missing.m4a"))
            assertionFailure("Missing audio must not play")
        } catch AudioNoteController.Failure.playbackUnavailable {}
        assert(!controller.isPlaying && controller.playbackID == nil)
        assert(AudioNoteController.normalizedLevel(.nan) == 0)
        assert(AudioNoteController.normalizedLevel(-160) == 0)
        assert(AudioNoteController.normalizedLevel(10) == 1)
        print("Audio notes: permission denial/cancellation, missing device, record/pause/resume, delegate stop/error recovery, stale callbacks, sleep recovery, save retry, discard during finish, empty take, waveform, and missing playback passed; microphone and speakers were not opened")
    }

    enum TestFailure: Error { case unavailable }
}

private final class StubRecorder: AudioRecordingDevice {
    var delegate: AVAudioRecorderDelegate?
    let url: URL
    let writeFixture: Bool
    let fixtureFrames: AVAudioFrameCount
    var isRecording = false
    var isMeteringEnabled = false
    var currentTime: TimeInterval { Double(fixtureFrames) / 44_100 }
    var starts = 0
    var canRecord = true

    init(url: URL, writeFixture: Bool = true, fixtureFrames: AVAudioFrameCount = 11_025) {
        self.url = url; self.writeFixture = writeFixture; self.fixtureFrames = fixtureFrames
    }
    func prepareToRecord() -> Bool {
        guard writeFixture else { return true }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: fixtureFrames)!
            buffer.frameLength = fixtureFrames
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData!.pointee[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.25)
            }
            try file.write(from: buffer)
            return true
        } catch { return false }
    }
    func record() -> Bool { starts += 1; isRecording = canRecord; return canRecord }
    func pause() { isRecording = false }
    func stop() { isRecording = false }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -12 }
}

@MainActor private final class RecordingAnalyticsSpy {
    var events: [AnalyticsEventName] = []
    var activity: [Bool] = []

    init(_ controller: AudioNoteController) {
        controller.onAnalyticsEvent = { [weak self] in self?.events.append($0) }
        controller.onAnalyticsActivityChanged = { [weak self] feature, active in
            assert(feature == .audioRecording)
            self?.activity.append(active)
        }
    }
}
