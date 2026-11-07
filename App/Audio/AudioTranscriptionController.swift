import AVFoundation
import Foundation
import Observation
import Speech

/// A copied recording keeps its audio ID while each note owns its transcript.
struct AudioTranscriptionScope: Hashable {
    let bookID: String
    let annotationID: UUID
}

/// A single file-transcription job. Audio is processed on this Mac: the older
/// recognizer is explicitly prohibited from falling back to server recognition.
@MainActor
@Observable
final class AudioTranscriptionController {
    enum Phase: Equatable { case idle, preparing, transcribing }

    enum Failure: LocalizedError {
        case busy, missingRecording, permissionDenied, unsupportedLanguage
        case modelUnavailable, speechUnavailable, noSpeech

        var errorDescription: String? {
            switch self {
            case .busy: return "Another recording is being transcribed. Finish or cancel it first."
            case .missingRecording: return "This recording is unavailable. Wait for it to download or try Sync Now."
            case .permissionDenied: return "Allow Kodi Reader in System Settings → Privacy & Security → Speech Recognition, then try again."
            case .unsupportedLanguage: return "On-device transcription isn’t available for this language on this Mac."
            case .modelUnavailable: return "The on-device speech model couldn’t be prepared. Connect to the internet to download it, then try again."
            case .speechUnavailable: return "On-device speech recognition is unavailable right now. Try again shortly."
            case .noSpeech: return "No speech was recognized in this recording."
            }
        }
    }

    typealias PhaseUpdate = @MainActor (Phase) -> Void
    typealias Backend = @MainActor (URL, Locale, @escaping PhaseUpdate) async throws -> String

    private(set) var activeID: UUID?
    private(set) var activeScope: AudioTranscriptionScope?
    private(set) var phase: Phase = .idle
    private(set) var errorID: UUID?
    private(set) var errorScope: AudioTranscriptionScope?
    private(set) var errorMessage: String?
    var isBusy: Bool { activeID != nil }

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private var job: UUID?
    @ObservationIgnored private var task: Task<String, Error>?

    init(backend: Backend? = nil) {
        self.backend = backend ?? Self.transcribeOnDevice
    }

    func transcribe(id: UUID, url: URL, locale: Locale = .current, scope: AudioTranscriptionScope? = nil) async throws -> String {
        try Task.checkCancellation()
        guard activeID == nil else { throw Failure.busy }
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            errorID = id
            errorScope = scope
            errorMessage = Failure.missingRecording.localizedDescription
            throw Failure.missingRecording
        }

        let token = UUID()
        job = token
        activeID = id
        activeScope = scope
        errorID = nil
        errorScope = nil
        errorMessage = nil
        phase = .preparing
        let backend = backend
        let operation = Task { @MainActor [weak self] in
            try await backend(url, locale) { [weak self] phase in
                guard self?.job == token else { return }
                self?.phase = phase
            }
        }
        task = operation
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            try Task.checkCancellation()
            guard job == token else { throw CancellationError() }
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.noSpeech }
            finishJob()
            return text
        } catch {
            guard job == token else { throw CancellationError() }
            let cancelled = operation.isCancelled || error is CancellationError || Task.isCancelled
            finishJob()
            if !cancelled {
                errorID = id
                errorScope = scope
                errorMessage = error.localizedDescription
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    func cancel() {
        job = nil
        task?.cancel()
        task = nil
        activeID = nil
        activeScope = nil
        phase = .idle
        errorID = nil
        errorScope = nil
        errorMessage = nil
    }

    func cancel(id: UUID, scope: AudioTranscriptionScope?) {
        if activeID == id, activeScope == scope { cancel() }
        else if errorID == id, errorScope == scope {
            errorID = nil
            errorScope = nil
            errorMessage = nil
        }
    }

    func isTranscribing(id: UUID, scope: AudioTranscriptionScope?) -> Bool {
        activeID == id && activeScope == scope
    }

    func error(for id: UUID, scope: AudioTranscriptionScope?) -> String? {
        errorID == id && errorScope == scope ? errorMessage : nil
    }

    private func finishJob() {
        task = nil
        job = nil
        activeID = nil
        activeScope = nil
        phase = .idle
    }

    private static func transcribeOnDevice(url: URL, locale: Locale, phase: @escaping PhaseUpdate) async throws -> String {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
           let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return try await ModernSpeechSession.run(url: url, locale: equivalent, phase: phase)
        }

        // The legacy API may require authorization even when recognition is
        // forced on-device. Check support before showing its permission prompt.
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure.unsupportedLanguage
        }
        guard await authorizeLegacySpeech() else { throw Failure.permissionDenied }
        try Task.checkCancellation()
        guard recognizer.isAvailable else { throw Failure.speechUnavailable }
        phase(.transcribing)
        let session = LegacySpeechSession(recognizer: recognizer)
        return try await withTaskCancellationHandler {
            try await session.transcribe(url: url)
        } onCancel: {
            Task { @MainActor in session.cancel() }
        }
    }

    private static func authorizeLegacySpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ModernSpeechSession {
    private static var cleanup: Task<Void, Never>?
    private let locale: Locale
    private let phase: AudioTranscriptionController.PhaseUpdate
    private var analyzer: SpeechAnalyzer?
    private var installation: AssetInstallationRequest?
    private var cancelled = false

    init(locale: Locale, phase: @escaping AudioTranscriptionController.PhaseUpdate) {
        self.locale = locale
        self.phase = phase
    }

    static func run(url: URL, locale: Locale, phase: @escaping AudioTranscriptionController.PhaseUpdate) async throws -> String {
        let previous = cleanup
        let session = ModernSpeechSession(locale: locale, phase: phase)
        let operation = Task { @MainActor in
            // A cancelled card becomes available immediately. Wait for the old
            // analyzer to release its model reservation before starting another.
            await previous?.value
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await session.transcribe(url: url)
            } onCancel: {
                Task { @MainActor in await session.cancel() }
            }
        }
        cleanup = Task { _ = await operation.result }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    func cancel() async {
        cancelled = true
        installation?.progress.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    func transcribe(url: URL) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let alreadyReserved = await AssetInventory.reservedLocales.contains { $0.identifier == locale.identifier }
        var reservedHere = false
        do {
            try checkCancellation()
            if !alreadyReserved {
                reservedHere = try await AssetInventory.reserve(locale: locale)
                guard reservedHere else { throw AudioTranscriptionController.Failure.modelUnavailable }
            }
            try checkCancellation()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                installation = request
                do { try await request.downloadAndInstall() }
                catch {
                    try checkCancellation()
                    throw AudioTranscriptionController.Failure.modelUnavailable
                }
                installation = nil
            }
            try checkCancellation()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            let results = Task { @MainActor in
                var chunks: [String] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    if result.isFinal {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { chunks.append(text) }
                    }
                }
                return chunks.joined(separator: " ")
            }
            do {
                phase(.transcribing)
                let file = try AVAudioFile(forReading: url)
                let end = try await analyzer.analyzeSequence(from: file)
                try checkCancellation()
                // Reading a file does not finish the result stream by itself.
                if let end { try await analyzer.finalizeAndFinish(through: end) }
                else { await analyzer.cancelAndFinishNow() }
                let text = try await results.value
                try checkCancellation()
                self.analyzer = nil
                if reservedHere { await AssetInventory.release(reservedLocale: locale) }
                return text
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } catch {
            installation = nil
            analyzer = nil
            if reservedHere { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }
}

@MainActor
private final class LegacySpeechSession {
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false

    init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    func transcribe(url: URL) async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(CancellationError())); return }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            request.taskHint = .dictation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                Task { @MainActor in
                    if let text { self?.finish(.success(text)) }
                    else if let error { self?.finish(.failure(error)) }
                }
            }
            if Task.isCancelled { cancel() }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        continuation.resume(with: result)
    }
}
