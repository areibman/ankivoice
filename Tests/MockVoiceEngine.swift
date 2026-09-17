import Foundation
@testable import AnkiVoice

/// Deterministic voice engine for tests. Records directives and lets tests
/// inject events; speech "completes" immediately unless stalled.
@MainActor
final class MockVoiceEngine: VoiceSessionEngine {

    let continuation: AsyncStream<VoiceEvent>.Continuation
    let events: AsyncStream<VoiceEvent>

    /// Ordered record of engine interactions.
    private(set) var log: [String] = []
    private let stateQueue = DispatchQueue(label: "mock-engine")

    /// When true, `speak` suspends until `finishSpeaking()` is called.
    var stallSpeaking = false
    private var speakWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var lastEndpointMs: Int?
    private(set) var lastPhase: CommandRecognizer.ListeningPhase?

    init() {
        var localContinuation: AsyncStream<VoiceEvent>.Continuation!
        let stream = AsyncStream<VoiceEvent> { localContinuation = $0 }
        self.continuation = localContinuation
        self.events = stream
    }

    func record(_ entry: String) {
        stateQueue.sync { log.append(entry) }
    }

    func entries() -> [String] {
        stateQueue.sync { log }
    }

    // MARK: VoiceSessionEngine

    func prepare(voice: VoiceConfig, commandLocale: String) async throws {
        record("prepare(\(commandLocale))")
    }

    func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async {
        let summary = segments.map {
            switch $0 {
            case .speech(let text, _): return text
            case .pause: return "·"
            case .media(let f): return "[\(f)]"
            }
        }.joined(separator: " ")
        record("speak(\"\(summary)\")")
        if stallSpeaking {
            await withCheckedContinuation { cont in
                stateQueue.sync { speakWaiters.append(cont) }
            }
        }
    }

    func finishSpeaking() {
        stateQueue.sync {
            let waiters = speakWaiters
            speakWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    func playConfirmationTone() async {
        record("tone")
    }

    func startListening(phase: CommandRecognizer.ListeningPhase, endpointMs: Int, recognizer: CommandRecognizer) async throws {
        record("listen(\(phase == .awaitingAnswer ? "answer" : phase == .awaitingRating ? "rating" : "paused"),\(endpointMs))")
        stateQueue.sync {
            lastEndpointMs = endpointMs
            lastPhase = phase
        }
    }

    func stopListening() { record("stopListening") }
    func stopSpeaking() { record("stopSpeaking") }
    func shutdown() { record("shutdown") }

    // MARK: Event injection

    func emit(_ event: VoiceEvent) {
        continuation.yield(event)
    }

    func emitSpeechStarted() { emit(.speechStarted) }
    func emitAnswerEnded() { emit(.answerEnded) }
    func emitCommand(_ command: CommandRecognizer.Command) { emit(.command(command)) }
    /// Command-phase speech that contained no command (the real engine stops
    /// listening before reporting this, so record that too).
    func emitUnrecognized(_ transcript: String) {
        record("stopListening")
        emit(.commandNotRecognized(transcript: transcript))
    }

    /// Number of listening windows opened in `phase` so far.
    func listenCount(_ phase: String) -> Int {
        entries().filter { $0.hasPrefix("listen(\(phase),") }.count
    }
}
