import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

struct SpeechToken: Sendable {
    var text: String
    var whitespace: String
    var start: Double?
    var end: Double?
}

struct SynthesizedSpeech: Sendable {
    var samples: [Float]
    var sampleRate: Double
    var tokens: [SpeechToken]
}

/// Kokoro/MLX must run on one persistent OS thread. A GCD serial queue can hop
/// workers between jobs, which hangs Metal ("no GPU stream in current thread").
final class KokoroEngine: @unchecked Sendable {
    private let executor = SerialThreadExecutor(name: "com.olly.folio.kokoro")
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    func prepare(modelURL: URL, voicesURL: URL) async throws {
        try await onThread {
            #if !arch(arm64)
            throw KokoroModelError.requiresAppleSilicon
            #else
            if self.tts != nil, !self.voices.isEmpty { return }
            self.tts = KokoroTTS(modelPath: modelURL, g2p: .misaki)
            self.voices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
            guard !self.voices.isEmpty else {
                self.tts = nil
                throw KokoroModelError.engineUnavailable
            }
            #endif
        }
    }

    func synthesize(text: String, voiceID: String) async throws -> SynthesizedSpeech {
        try await onThread {
            guard let tts = self.tts else { throw KokoroModelError.engineUnavailable }
            let voice = try self.voiceArray(for: voiceID)
            let language: Language = ReadAloudVoice.isAmerican(voiceID) ? .enUS : .enGB
            let (samples, tokens) = try tts.generateAudio(
                voice: voice,
                language: language,
                text: text
            )
            return SynthesizedSpeech(
                samples: samples,
                sampleRate: Double(KokoroTTS.Constants.samplingRate),
                tokens: (tokens ?? []).map { token in
                    SpeechToken(
                        text: token.text,
                        whitespace: token.whitespace,
                        start: token.start_ts,
                        end: token.end_ts
                    )
                }
            )
        }
    }

    private func voiceArray(for id: String) throws -> MLXArray {
        let keys = [id, id + ".npy", id + ".npz"]
        for key in keys {
            if let voice = voices[key] { return voice }
        }
        if let match = voices.first(where: { $0.key.hasPrefix(id) }) {
            return match.value
        }
        throw KokoroModelError.missingVoice(id)
    }

    private func onThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            executor.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// One pthread for the lifetime of the engine. MLX binds GPU streams to the
/// OS thread that created them.
private final class SerialThreadExecutor: @unchecked Sendable {
    private let state: State
    private let thread: Thread

    private final class State: @unchecked Sendable {
        let lock = NSCondition()
        var items: [() -> Void] = []
        var stopped = false

        func runLoop() {
            while true {
                lock.lock()
                while items.isEmpty && !stopped {
                    lock.wait()
                }
                if stopped {
                    lock.unlock()
                    return
                }
                let item = items.removeFirst()
                lock.unlock()
                item()
            }
        }

        func async(_ work: @escaping () -> Void) {
            lock.lock()
            items.append(work)
            lock.signal()
            lock.unlock()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.broadcast()
            lock.unlock()
        }
    }

    init(name: String) {
        let state = State()
        self.state = state
        let thread = Thread {
            state.runLoop()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.threadPriority = 0.75
        self.thread = thread
        thread.start()
    }

    deinit {
        state.stop()
    }

    func async(_ work: @escaping () -> Void) {
        state.async(work)
    }
}
