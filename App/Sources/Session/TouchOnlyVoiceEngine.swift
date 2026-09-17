import Foundation

/// A voice engine that does nothing — used as a graceful fallback when the
/// speech stack is unavailable (e.g. missing assets). The session continues
/// in touch-only mode: on-screen reveal and rating controls still work, so a
/// voice failure never traps the user (PRD §32).
@MainActor
final class TouchOnlyVoiceEngine: VoiceSessionEngine {

    let events: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation

    init() {
        var local: AsyncStream<VoiceEvent>.Continuation!
        let stream = AsyncStream<VoiceEvent> { local = $0 }
        self.continuation = local
        self.events = stream
    }

    func prepare(voice: VoiceConfig, commandLocale: String) async throws {}

    func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async {
        // No audio; pacing stays instant so the touch flow is snappy.
    }

    func playConfirmationTone() async {}

    func startListening(
        phase: CommandRecognizer.ListeningPhase,
        endpointMs: Int,
        recognizer: CommandRecognizer
    ) async throws {}

    func stopListening() {}
    func stopSpeaking() {}
    func shutdown() {
        continuation.finish()
    }
}
