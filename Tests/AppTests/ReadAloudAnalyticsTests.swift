import AppKit
import AVFoundation
import Foundation

/// Exercises real controller transitions with fake model/output boundaries.
/// No narration model is downloaded, and no microphone or speaker is opened.
@main struct ReadAloudAnalyticsTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var preparation: CheckedContinuation<Void, Never>?
        var players: [SilentPlaybackDevice] = []
        let narration = ReadAloudController(prepare: {
            await withCheckedContinuation { preparation = $0 }
        }, synthesize: { _, _ in [0, 0.2, -0.2] }, playerFactory: { _ in
            let player = SilentPlaybackDevice()
            players.append(player)
            return player
        }, sampleRate: { 24_000 })
        let spy = ListeningAnalyticsSpy(narration)
        narration.start { "First paragraph.\nSecond paragraph." }
        await waitUntil { preparation != nil }
        assert(narration.phase == .preparing && spy.events.isEmpty && spy.activity.isEmpty)
        preparation!.resume(); preparation = nil
        await waitUntil { narration.phase == .playing }
        assert(spy.events == [.ttsListeningStarted] && spy.activity == [true])
        narration.pause()
        narration.pause()
        assert(narration.phase == .paused)
        assert(spy.events == [.ttsListeningStarted, .ttsListeningPaused] && spy.activity == [true, false])
        narration.resume()
        narration.resume()
        assert(spy.events == [.ttsListeningStarted, .ttsListeningPaused, .ttsListeningResumed])
        assert(spy.activity == [true, false, true])

        let firstPlayer = players[0]
        narration.playbackFinished(identity: ObjectIdentifier(firstPlayer), successfully: true)
        await waitUntil { preparation != nil }
        assert(narration.phase == .preparing && spy.activity.last == false)
        assert(spy.events.filter { $0 == .ttsListeningStarted }.count == 1)
        preparation!.resume(); preparation = nil
        await waitUntil { players.count == 2 && narration.phase == .playing }
        assert(spy.events.filter { $0 == .ttsListeningStarted }.count == 1)
        assert(spy.events.filter { $0 == .ttsListeningResumed }.count == 1, "A paragraph boundary is not a user resume")
        narration.playbackFinished(identity: ObjectIdentifier(firstPlayer), successfully: false)
        assert(narration.phase == .playing, "A stale output callback must not end a newer passage")
        narration.playbackFinished(identity: ObjectIdentifier(players[1]), successfully: true)
        assert(narration.phase == .idle)
        assert(spy.events.last == .ttsListeningCompleted && !spy.events.contains(.ttsListeningStopped))
        assert(spy.activity == [true, false, true, false, true, false], "Preparation and inter-passage gaps must not count as listening")
        narration.stop()
        assert(spy.events.last == .ttsListeningCompleted)

        // Stopping during the first preparation produces no fabricated start.
        narration.start { "Cancelled before sound." }
        await waitUntil { preparation != nil }
        let beforeCancellation = spy.events
        narration.stop()
        preparation!.resume(); preparation = nil
        await Task.yield()
        assert(narration.phase == .idle && spy.events == beforeCancellation)

        // A sleep notification ends actual listening before the machine sleeps.
        var sleepPlayer: SilentPlaybackDevice?
        let sleeping = ReadAloudController(prepare: {}, synthesize: { _, _ in [0] }, playerFactory: { _ in
            let player = SilentPlaybackDevice(); sleepPlayer = player; return player
        }, sampleRate: { 24_000 })
        let sleepSpy = ListeningAnalyticsSpy(sleeping)
        sleeping.start { "Sleep test." }
        await waitUntil { sleeping.phase == .playing }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await waitUntil { sleeping.phase == .idle }
        assert(sleepSpy.events == [.ttsListeningStarted, .ttsListeningStopped] && sleepSpy.activity == [true, false])
        sleeping.playbackFinished(identity: ObjectIdentifier(sleepPlayer!), successfully: true)
        assert(sleepSpy.events == [.ttsListeningStarted, .ttsListeningStopped])

        // A requested synthesis failure counts as failure even before output.
        let unavailable = ReadAloudController(prepare: { throw TestFailure.unavailable }, synthesize: { _, _ in
            assertionFailure("Synthesis must not run when model preparation fails"); return []
        }, playerFactory: { _ in
            assertionFailure("No output should be prepared after a model failure"); return SilentPlaybackDevice()
        }, sampleRate: { 24_000 })
        let unavailableSpy = ListeningAnalyticsSpy(unavailable)
        unavailable.start { "Unavailable model." }
        await waitUntil { if case .failed = unavailable.phase { return true }; return false }
        assert(unavailableSpy.events == [.ttsListeningFailed] && unavailableSpy.activity.isEmpty)

        // Playback failure ends time without adding an explicit-stop outcome.
        var failedPlayer: SilentPlaybackDevice?
        let failing = ReadAloudController(prepare: {}, synthesize: { _, _ in [0] }, playerFactory: { _ in
            let player = SilentPlaybackDevice(); failedPlayer = player; return player
        }, sampleRate: { 24_000 })
        let failedSpy = ListeningAnalyticsSpy(failing)
        failing.start { "Runtime interruption." }
        await waitUntil { failing.phase == .playing }
        failing.playbackFinished(identity: ObjectIdentifier(failedPlayer!), successfully: false)
        assert(failedSpy.events == [.ttsListeningStarted, .ttsListeningFailed] && failedSpy.activity == [true, false])

        // Failed output resume remains inactive and reports failure once.
        var resumePlayer: SilentPlaybackDevice?
        let resuming = ReadAloudController(prepare: {}, synthesize: { _, _ in [0] }, playerFactory: { _ in
            let player = SilentPlaybackDevice(); resumePlayer = player; return player
        }, sampleRate: { 24_000 })
        let resumeSpy = ListeningAnalyticsSpy(resuming)
        resuming.start { "Resume failure." }
        await waitUntil { resuming.phase == .playing }
        resuming.pause()
        resumePlayer!.canPlay = false
        resuming.resume()
        assert(resumeSpy.events == [.ttsListeningStarted, .ttsListeningPaused, .ttsListeningFailed] && resumeSpy.activity == [true, false])
        resuming.start { "Explicit stop." }
        await waitUntil { resuming.phase == .playing }
        resuming.stop()
        assert(resumeSpy.events.suffix(2) == [.ttsListeningStarted, .ttsListeningStopped] && resumeSpy.activity == [true, false, true, false])
        print("Read aloud analytics: actual output start, pause/resume, preparation/gap exclusion, passage completion, stale callbacks, cancellation, sleep, failure and explicit stop passed; no model or speakers were opened")
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { await Task.yield() }
        assert(condition(), "Timed out waiting for a controller transition")
    }

    enum TestFailure: Error { case unavailable }
}

private final class SilentPlaybackDevice: AudioPlaybackDevice {
    var delegate: AVAudioPlayerDelegate?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 1
    var isPlaying = false
    var enableRate = false
    var rate: Float = 1
    var canPlay = true
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { isPlaying = canPlay; return canPlay }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor private final class ListeningAnalyticsSpy {
    var events: [AnalyticsEventName] = []
    var activity: [Bool] = []

    init(_ controller: ReadAloudController) {
        controller.onAnalyticsEvent = { [weak self] in self?.events.append($0) }
        controller.onAnalyticsActivityChanged = { [weak self] feature, active in
            assert(feature == .ttsListening)
            self?.activity.append(active)
        }
    }
}
