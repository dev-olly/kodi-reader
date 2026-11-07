import Foundation
import Speech

/// The default suite exercises the real controller with a suspended backend.
/// It never requests Speech permission, opens input, or plays audio.
@main struct AudioTranscriptionTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KodiTranscriptionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.m4a")
        try Data([1, 2, 3]).write(to: fixture)

        let backend = SuspendedBackend()
        let controller = AudioTranscriptionController(backend: backend.transcribe)
        assert(!controller.isBusy && controller.phase == .idle)
        let firstID = UUID()
        let first = Task { @MainActor in try await controller.transcribe(id: firstID, url: fixture, locale: Locale(identifier: "en_US")) }
        await waitUntil { backend.calls.count == 1 }
        assert(controller.activeID == firstID && controller.phase == .preparing)
        assert(backend.calls[0].locale.identifier == "en_US")
        backend.calls[0].phase(.transcribing)
        assert(controller.phase == .transcribing)
        do {
            _ = try await controller.transcribe(id: UUID(), url: fixture)
            assertionFailure("A second active job should fail")
        } catch AudioTranscriptionController.Failure.busy {}
        assert(controller.activeID == firstID && controller.errorID == nil)
        backend.succeed(0, text: "  Thoughts about this book.\n")
        let firstText = try await first.value
        assert(firstText == "Thoughts about this book.")
        assert(!controller.isBusy && controller.phase == .idle && controller.errorMessage == nil)

        let failedID = UUID()
        let failed = Task { @MainActor in try await controller.transcribe(id: failedID, url: fixture) }
        await waitUntil { backend.calls.count == 2 }
        backend.fail(1, error: AudioTranscriptionController.Failure.permissionDenied)
        do { _ = try await failed.value; assertionFailure("Backend failure should be reported") }
        catch AudioTranscriptionController.Failure.permissionDenied {}
        assert(controller.errorID == failedID && controller.errorMessage?.contains("Speech Recognition") == true)
        assert(!controller.isBusy && controller.phase == .idle)
        let retry = Task { @MainActor in try await controller.transcribe(id: failedID, url: fixture) }
        await waitUntil { backend.calls.count == 3 }
        assert(controller.errorMessage == nil && controller.errorID == nil)
        backend.succeed(2, text: "Retry succeeded.")
        let retryText = try await retry.value
        assert(retryText == "Retry succeeded." && controller.errorID == nil)

        let noSpeechID = UUID()
        let empty = Task { @MainActor in try await controller.transcribe(id: noSpeechID, url: fixture) }
        await waitUntil { backend.calls.count == 4 }
        backend.succeed(3, text: " \n\t")
        do { _ = try await empty.value; assertionFailure("Empty recognition should not be saved") }
        catch AudioTranscriptionController.Failure.noSpeech {}
        assert(controller.errorID == noSpeechID && controller.errorMessage?.contains("No speech") == true)

        let cancelled = Task { @MainActor in try await controller.transcribe(id: UUID(), url: fixture) }
        await waitUntil { backend.calls.count == 5 }
        controller.cancel()
        assert(!controller.isBusy && controller.errorID == nil && controller.phase == .idle)
        let replacementID = UUID()
        let replacement = Task { @MainActor in try await controller.transcribe(id: replacementID, url: fixture) }
        await waitUntil { backend.calls.count == 6 }
        backend.calls[4].phase(.transcribing)
        assert(controller.phase == .preparing)
        backend.succeed(4, text: "Stale result must not escape.")
        do { _ = try await cancelled.value; assertionFailure("Cancelled work should be ignored") }
        catch is CancellationError {}
        assert(controller.activeID == replacementID && controller.errorID == nil)
        backend.succeed(5, text: "Current result.")
        let replacementText = try await replacement.value
        assert(replacementText == "Current result." && !controller.isBusy)

        let externallyCancelled = Task { @MainActor in try await controller.transcribe(id: UUID(), url: fixture) }
        await waitUntil { backend.calls.count == 7 }
        externallyCancelled.cancel()
        backend.fail(6, error: AudioTranscriptionController.Failure.speechUnavailable)
        do { _ = try await externallyCancelled.value; assertionFailure("Caller cancellation should win") }
        catch is CancellationError {}
        assert(!controller.isBusy && controller.errorID == nil)

        for unavailableURL in [directory.appendingPathComponent("missing.m4a"), directory, URL(string: "https://example.invalid/audio.m4a")!] {
            let missingID = UUID()
            do {
                _ = try await controller.transcribe(id: missingID, url: unavailableURL)
                assertionFailure("Unavailable files should fail before the backend")
            } catch AudioTranscriptionController.Failure.missingRecording {}
            assert(controller.errorID == missingID && !controller.isBusy)
        }
        let emptyFile = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: emptyFile)
        do { _ = try await controller.transcribe(id: UUID(), url: emptyFile); assertionFailure("Zero-byte file should fail") }
        catch AudioTranscriptionController.Failure.missingRecording {}
        assert(backend.calls.count == 7)
        controller.cancel()
        assert(controller.errorID == nil && controller.errorMessage == nil)
        try await testCopiedRecordingScopes(fixture)
        print("Audio transcription: success, phases, busy guard, permission failure/retry, no speech, cancellation, stale callbacks, and unavailable files passed; no microphone, speakers, permission prompt, or network used")

        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--native" {
            try await testNativeFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }

    @MainActor private static func testCopiedRecordingScopes(_ fixture: URL) async throws {
        let backend = SuspendedBackend()
        let controller = AudioTranscriptionController(backend: backend.transcribe)
        let sharedID = UUID(), annotationID = UUID()
        let original = AudioTranscriptionScope(bookID: "first-book", annotationID: annotationID)
        let anotherNote = AudioTranscriptionScope(bookID: original.bookID, annotationID: UUID())
        let anotherBook = AudioTranscriptionScope(bookID: "second-book", annotationID: annotationID)
        let work = Task { @MainActor in try await controller.transcribe(id: sharedID, url: fixture, scope: original) }
        await waitUntil { backend.calls.count == 1 }
        assert(controller.isTranscribing(id: sharedID, scope: original))
        for copy in [anotherNote, anotherBook] {
            assert(!controller.isTranscribing(id: sharedID, scope: copy), "Copied IDs must not inherit another note's progress or Cancel action")
            controller.cancel(id: sharedID, scope: copy)
            assert(controller.isBusy && controller.activeScope == original,
                   "Deleting a copy must leave the original note's transcription running")
            do {
                _ = try await controller.transcribe(id: sharedID, url: fixture, scope: copy)
                assertionFailure("The busy guard remains global across notes and books")
            } catch AudioTranscriptionController.Failure.busy {}
        }
        backend.fail(0, error: AudioTranscriptionController.Failure.noSpeech)
        do { _ = try await work.value; assertionFailure("The original note receives its backend failure") }
        catch AudioTranscriptionController.Failure.noSpeech {}
        assert(controller.activeScope == nil && !controller.isBusy)
        assert(controller.error(for: sharedID, scope: original) != nil)
        for copy in [anotherNote, anotherBook] {
            assert(controller.error(for: sharedID, scope: copy) == nil, "Copied IDs must not inherit another note's error")
            controller.cancel(id: sharedID, scope: copy)
            assert(controller.error(for: sharedID, scope: original) != nil)
        }
        controller.cancel(id: sharedID, scope: original)
        assert(controller.errorID == nil && controller.errorScope == nil)

        let replacement = Task { @MainActor in try await controller.transcribe(id: sharedID, url: fixture, scope: anotherNote) }
        await waitUntil { backend.calls.count == 2 }
        controller.cancel(id: sharedID, scope: original)
        assert(controller.isTranscribing(id: sharedID, scope: anotherNote))
        controller.cancel(id: sharedID, scope: anotherNote)
        assert(!controller.isBusy && controller.activeScope == nil)
        backend.succeed(1, text: "A deleted note's late result must be ignored.")
        do { _ = try await replacement.value; assertionFailure("Deleting the owning recording cancels its result") }
        catch is CancellationError {}
        print("Copied audio UUIDs: scoped progress/errors/deletion cancellation across notes and books, with global busy gating passed")
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { await Task.yield() }
        precondition(predicate(), "Async fixture did not reach expected state")
    }

    @MainActor private static func testNativeFile(_ url: URL) async throws {
        // A command-line test must never enter the older authorization flow:
        // only exercise an already installed, on-device SpeechAnalyzer model.
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            print("Native synthetic-file verification skipped: on-device English model is not installed or supported")
            return
        }
        let controller = AudioTranscriptionController()
        let text = try await controller.transcribe(id: UUID(), url: url, locale: locale)
        precondition(!text.isEmpty, "Synthetic speech should produce text")
        print("Native on-device synthetic-file verification passed: \(text)")
    }
}

@MainActor private final class SuspendedBackend {
    struct Call {
        let locale: Locale
        let phase: AudioTranscriptionController.PhaseUpdate
        let continuation: CheckedContinuation<String, Error>
    }
    var calls: [Call] = []

    func transcribe(url: URL, locale: Locale, phase: @escaping AudioTranscriptionController.PhaseUpdate) async throws -> String {
        try await withCheckedThrowingContinuation { calls.append(Call(locale: locale, phase: phase, continuation: $0)) }
    }
    func succeed(_ index: Int, text: String) { calls[index].continuation.resume(returning: text) }
    func fail(_ index: Int, error: Error) { calls[index].continuation.resume(throwing: error) }
}
