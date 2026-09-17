import Foundation

// MARK: - Events from the voice engine to the session controller

/// Events produced by the voice engine (mic, VAD, recognition, TTS lifecycle, audio session).
public enum VoiceEvent: Sendable {
    /// The user has begun speaking (answer phase).
    case speechStarted
    /// Sustained silence detected after speech — the answer turn is complete.
    case answerEnded
    /// A deterministic command was recognized (rating or control command).
    case command(CommandRecognizer.Command)
    /// The user finished saying something during a command phase (rating or
    /// paused) that contained no command. The engine has stopped listening;
    /// the controller says what it was expecting and re-arms the microphone.
    case commandNotRecognized(transcript: String)
    /// Partial transcript update for on-screen display.
    case transcript(String)
    /// Audio session interruption began (call, Siri, alarm…).
    case interruptionBegan
    /// Interruption ended / audio route became usable again.
    case interruptionEnded
    /// Output route changed (headphones connected/disconnected).
    case routeChanged(oldDescription: String, newDescription: String)
    /// Engine-level failure with a user-presentable message.
    case failure(String)
}

// MARK: - Engine protocol

/// Abstraction over the audio/speech stack so the session state machine is
/// fully testable with a deterministic mock.
///
/// Main-actor isolated: the session controller drives it from the main actor
/// and engines funnel their background callbacks back onto it, so engine
/// state never races.
@MainActor
public protocol VoiceSessionEngine: AnyObject, Sendable {
    /// Stream of engine events. The controller is the single consumer.
    var events: AsyncStream<VoiceEvent> { get }

    /// Configures voices/locales and prepares audio hardware. Call once per session.
    func prepare(voice: VoiceConfig, commandLocale: String) async throws

    /// Speaks segments to completion. Half-duplex: no recognition while speaking.
    func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async

    /// Plays the short rating-confirmation tone.
    func playConfirmationTone() async

    /// Starts listening in the given phase. `endpointMs` is the silence after
    /// speech that ends a turn: the answer in the answer phase, or — in the
    /// rating and paused phases — an utterance that produced no command,
    /// which is reported as `commandNotRecognized`.
    func startListening(phase: CommandRecognizer.ListeningPhase, endpointMs: Int, recognizer: CommandRecognizer) async throws

    /// Stops any active listening/recognition immediately.
    func stopListening()

    /// Stops any in-flight speech immediately.
    func stopSpeaking()

    /// Tears everything down (audio engine, analyzer, session observation).
    func shutdown()
}
