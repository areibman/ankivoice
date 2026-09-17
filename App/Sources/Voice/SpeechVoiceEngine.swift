import Foundation
import Speech
import AVFAudio
import os

private let speechLog = Logger(subsystem: "local.ankivoice", category: "speech-engine")

/// Speech recognition engine built on SFSpeechRecognizer.
///
/// One AVAudioEngine feeds a buffer recognition request for both the answer
/// phase (free-form transcription + control commands) and the rating/paused
/// phases (constrained command vocabulary). Text-to-speech is half-duplex:
/// the microphone is closed while the app is speaking.
///
/// Main-actor isolated: recognizer callbacks are hopped back onto the main
/// queue (FIFO) so state never races with the session controller.
@MainActor
public final class SpeechVoiceEngine: VoiceSessionEngine {

    public let events: AsyncStream<VoiceEvent>
    private let continuation: AsyncStream<VoiceEvent>.Continuation

    // Configuration for the current listening window.
    private var commandLocale = "en-US"
    private var phase: CommandRecognizer.ListeningPhase = .awaitingAnswer
    private var recognizer = CommandRecognizer()
    private var endpointMs = 700

    // Audio + recognition.
    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Bumped on every start/stop; callbacks from an older generation are ignored.
    private var generation = 0
    private var listening = false
    private var restartCount = 0

    // Transcript tracking for the current listening window.
    private var lastNormalizedTranscript = ""
    private var lastTranscript = ""
    private var lastSpeechAt: Date?
    private var speechStartedReported = false
    /// Words before this index already produced a command; later matches only.
    private var nextCommandWordIndex = 0
    private var silenceTask: Task<Void, Never>?

    // Output.
    private var tts: TextToSpeech?
    private var audioSessionController: AudioSessionController?

    public init() {
        var localContinuation: AsyncStream<VoiceEvent>.Continuation!
        let stream = AsyncStream<VoiceEvent> { localContinuation = $0 }
        self.continuation = localContinuation
        self.events = stream
    }

    // MARK: - VoiceSessionEngine

    public func prepare(voice: VoiceConfig, commandLocale: String) async throws {
        self.commandLocale = Self.supportedCommandLocale(commandLocale)
        speechLog.info("[VOICE] prepare() locale=\(self.commandLocale, privacy: .public)")

        let speaker = ensureSpeaker()
        speaker.warmUp()

        let controller = AudioSessionController.shared
        audioSessionController = controller
        try controller.activate()
        controller.onInterruptionBegan = { [weak self] in
            self?.continuation.yield(.interruptionBegan)
        }
        controller.onInterruptionEnded = { [weak self] in
            self?.continuation.yield(.interruptionEnded)
        }
        controller.onRouteChanged = { [weak self] old, new in
            self?.continuation.yield(.routeChanged(oldDescription: old, newDescription: new))
        }
        controller.onMediaServicesLost = { [weak self] in
            self?.continuation.yield(.failure("Audio services restarted. Say resume or tap Resume to continue."))
        }

        guard await Self.ensureSpeechAuthorization() == .authorized else {
            throw VoiceEngineError.speechDenied
        }
        guard await Self.ensureMicrophonePermission() else {
            throw VoiceEngineError.microphoneDenied
        }
        guard let sfRecognizer = SFSpeechRecognizer(locale: Locale(identifier: self.commandLocale)) else {
            throw VoiceEngineError.localeUnsupported(self.commandLocale)
        }
        sfRecognizer.defaultTaskHint = .dictation
        speechRecognizer = sfRecognizer
        speechLog.info("[VOICE] prepare() complete onDevice=\(sfRecognizer.supportsOnDeviceRecognition)")
    }

    public func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async {
        stopRecognition()
        await ensureSpeaker().speak(segments, config: voice)
    }

    public func playConfirmationTone() async {
        await TonePlayer.shared.play()
    }

    public func startListening(
        phase: CommandRecognizer.ListeningPhase,
        endpointMs: Int,
        recognizer: CommandRecognizer
    ) async throws {
        stopRecognition()
        self.phase = phase
        self.recognizer = recognizer
        self.endpointMs = endpointMs
        restartCount = 0
        try await beginRecognition()
    }

    public func stopListening() {
        stopRecognition()
    }

    public func stopSpeaking() {
        tts?.stopSpeaking()
    }

    public func shutdown() {
        stopRecognition()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        tts?.stopSpeaking()
        continuation.finish()
        audioSessionController?.deactivate()
    }

    // MARK: - Recognition lifecycle

    private func beginRecognition() async throws {
        guard let sfRecognizer = speechRecognizer
                ?? SFSpeechRecognizer(locale: Locale(identifier: commandLocale)) else {
            throw VoiceEngineError.localeUnsupported(commandLocale)
        }
        speechRecognizer = sfRecognizer
        guard sfRecognizer.isAvailable else {
            throw VoiceEngineError.speechUnavailable
        }

        generation += 1
        let gen = generation
        lastTranscript = ""
        lastNormalizedTranscript = ""
        lastSpeechAt = nil
        speechStartedReported = false
        nextCommandWordIndex = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = phase == .awaitingAnswer ? .dictation : .search
        request.contextualStrings = Self.contextualStrings(for: phase)
        // Cloud fallback keeps recognition working when on-device assets are
        // missing; on-device is used automatically when available.
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = false
        self.request = request

        // The session may have been deactivated by an interruption (call,
        // Siri); re-asserting it is idempotent.
        try? AVAudioSession.sharedInstance().setActive(true)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceEngineError.notPrepared
        }
        // The tap runs on the audio thread; the request is only ever appended
        // to there and ended on the main actor, which SFSpeech permits.
        nonisolated(unsafe) let tapRequest = request
        // AVAudioEngine raises Objective-C exceptions for a tap whose format
        // no longer matches the hardware (AirPods switching profiles mid-
        // session is the classic case). Catch them so the session degrades
        // to an error message instead of crashing.
        do {
            var startError: Error?
            try ObjCException.catching {
                inputNode.removeTap(onBus: 0)
                // `@Sendable`: the tap block runs on the audio render thread,
                // so it must not inherit main-actor isolation (see
                // ensureSpeechAuthorization for the crash that causes).
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                    tapRequest.append(buffer)
                }
                audioEngine.prepare()
                do { try audioEngine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            speechLog.error("[VOICE] audio engine start failed: \(error.localizedDescription, privacy: .public)")
            try? ObjCException.catching { inputNode.removeTap(onBus: 0) }
            audioEngine.reset()
            throw error
        }
        observeConfigurationChanges()

        listening = true
        task = sfRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Recognizer callbacks arrive on a private queue (hence
            // `@Sendable`, so no main-actor isolation is inferred). Pull the
            // two values we need out of the non-Sendable result here, then hop
            // to main in FIFO order so partials are processed in sequence.
            let update = result.map { Recognition(text: $0.bestTranscription.formattedString, isFinal: $0.isFinal) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleRecognition(generation: gen, result: update, error: error)
                }
            }
        }

        startSilenceWatchdog(generation: gen)
        speechLog.info("[VOICE] listening phase=\(String(describing: self.phase), privacy: .public) gen=\(gen)")
    }

    private func stopRecognition() {
        generation += 1
        listening = false
        silenceTask?.cancel()
        silenceTask = nil
        if audioEngine.isRunning {
            try? ObjCException.catching {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.stop()
            }
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    // MARK: - Audio configuration changes

    private var configurationObserver: NSObjectProtocol?

    /// The engine stops itself when the hardware format changes underneath it
    /// (headphones plugged in, AirPods switching between A2DP and HFP). Re-
    /// install the tap for the new format instead of leaving a dead session.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, which is the main actor's executor.
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard listening else { return }
        speechLog.info("[VOICE] audio configuration changed; reinstalling tap")
        restartRecognition(reason: "configuration change")
    }

    /// Restarts recognition in the same phase after the recognizer closed the
    /// request on its own (silence timeout, ~1 minute cloud limit, transient
    /// error). Preserves the phase so a rating window can wait indefinitely.
    private func restartRecognition(reason: String) {
        guard listening else { return }
        speechLog.info("[VOICE] restarting recognition (\(reason, privacy: .public))")
        stopRecognition()
        listening = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginRecognition()
            } catch {
                self.listening = false
                self.continuation.yield(.failure(VoiceEngineError.describe(error, locale: self.commandLocale)))
            }
        }
    }

    // MARK: - Recognition results

    /// The Sendable subset of `SFSpeechRecognitionResult` the engine acts on.
    private struct Recognition: Sendable {
        let text: String
        let isFinal: Bool
    }

    private func handleRecognition(generation gen: Int, result: Recognition?, error: Error?) {
        guard gen == generation, listening else { return }

        if let error {
            handleRecognitionError(error as NSError)
            return
        }
        guard let result else { return }

        let text = result.text
        let normalized = CommandRecognizer.normalize(text)
        if !normalized.isEmpty, normalized != lastNormalizedTranscript {
            lastNormalizedTranscript = normalized
            lastTranscript = text
            lastSpeechAt = Date()
            if !speechStartedReported {
                speechStartedReported = true
                if phase == .awaitingAnswer {
                    continuation.yield(.speechStarted)
                }
            }
            continuation.yield(.transcript(text))
            deliverCommandIfPresent(normalized: normalized)
        }

        if result.isFinal {
            // The recognizer closed the utterance itself (its own endpoint,
            // the one-minute cloud limit, or the request ending).
            endUtterance(reason: "final result")
        }
    }

    /// The current stretch of speech is over (silence, the recognizer's own
    /// endpoint, or its no-speech timeout). In the answer phase that ends
    /// the answer; in a command phase it either hands an utterance with no
    /// command to the controller — so it can say what it expected instead of
    /// silently ignoring the user — or simply opens a fresh window.
    private func endUtterance(reason: String) {
        guard listening else { return }
        if phase == .awaitingAnswer {
            if lastTranscript.isEmpty {
                restartRecognition(reason: reason)
            } else {
                finishAnswer()
            }
            return
        }
        if nextCommandWordIndex == 0, !lastTranscript.isEmpty {
            let heard = lastTranscript
            speechLog.info("[VOICE] no command heard (\(reason, privacy: .public)): \(heard, privacy: .private)")
            stopRecognition()
            continuation.yield(.commandNotRecognized(transcript: heard))
        } else {
            restartRecognition(reason: reason)
        }
    }

    /// Yields at most one command per new stretch of words, so partial
    /// results repeating the same "good" don't fire the command twice while
    /// a later "undo" in the same utterance still gets through.
    private func deliverCommandIfPresent(normalized: String) {
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count > nextCommandWordIndex else { return }
        let suffixWords = Array(words[nextCommandWordIndex...])
        let suffix = suffixWords.joined(separator: " ")
        guard let match = recognizer.recognize(transcript: suffix, phase: phase) else { return }

        let consumed = suffix[..<match.range.upperBound].split(separator: " ").count
        nextCommandWordIndex += max(consumed, 1)
        speechLog.info("[VOICE] command=\(match.command.rawValue, privacy: .public)")
        continuation.yield(.command(match.command))
    }

    private func finishAnswer() {
        guard listening, phase == .awaitingAnswer else { return }
        speechLog.info("[VOICE] answer ended")
        stopRecognition()
        continuation.yield(.answerEnded)
    }

    private func handleRecognitionError(_ error: NSError) {
        if Self.isCancellation(error) { return }

        if Self.isSilenceTimeout(error) {
            // The recognizer's own silence window elapsed — either after
            // speech (end of the utterance) or with nothing said at all.
            endUtterance(reason: "no speech detected")
            return
        }

        if Self.isTransient(error), restartCount < 3 {
            restartCount += 1
            restartRecognition(reason: "transient error \(error.domain) \(error.code)")
            return
        }

        speechLog.error("[VOICE] recognition error \(error.domain, privacy: .public) \(error.code)")
        listening = false
        stopRecognition()
        continuation.yield(.failure(RecognitionErrorClassifier.message(for: error, locale: commandLocale)))
    }

    // MARK: - Silence watchdog

    /// Ends the current utterance after `endpointMs` without new transcript
    /// text: the answer turn in the answer phase, or — in a command phase —
    /// the point at which speech that produced no command gets a spoken hint.
    /// Recognition partials trail speech by a few hundred milliseconds, so the
    /// effective pause the user experiences is roughly endpoint + that lag.
    private func startSilenceWatchdog(generation gen: Int) {
        silenceTask?.cancel()
        let endpoint = Double(endpointMs) / 1000.0
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, self.generation == gen, self.listening else { return }
                guard let last = self.lastSpeechAt else { continue }
                if Date().timeIntervalSince(last) >= endpoint {
                    self.endUtterance(reason: "silence")
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private func ensureSpeaker() -> TextToSpeech {
        if let tts { return tts }
        let speaker = TextToSpeech()
        if let media = try? AppServices.mediaDirectory() {
            speaker.setMediaDirectory(media)
        }
        tts = speaker
        return speaker
    }

    /// Command words boosted in the recognizer's language model.
    static func contextualStrings(for phase: CommandRecognizer.ListeningPhase) -> [String] {
        switch phase {
        case .awaitingAnswer:
            return ["repeat", "repeat question", "reveal", "show answer", "skip", "pause", "stop", "undo"]
        case .awaitingRating:
            return ["again", "hard", "good", "easy", "repeat", "repeat answer", "repeat question", "undo", "pause", "stop"]
        case .paused:
            return ["resume", "stop", "repeat"]
        }
    }

    /// Falls back to a supported recognition locale (same language, then
    /// the device locale, then US English) when the exact tag isn't offered.
    static func supportedCommandLocale(_ requested: String) -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        let normalizedRequested = requested.replacingOccurrences(of: "_", with: "-")
        if supported.contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").caseInsensitiveCompare(normalizedRequested) == .orderedSame }) {
            return normalizedRequested
        }
        let language = SettingsStore.languageKey(for: normalizedRequested)
        if let sameLanguage = supported.first(where: { SettingsStore.languageKey(for: $0.identifier) == language }) {
            return sameLanguage.identifier.replacingOccurrences(of: "_", with: "-")
        }
        let device = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        if supported.contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == device }) {
            return device
        }
        return "en-US"
    }

    static func isCancellation(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        // kLSRErrorDomain 301 "Recognition request was canceled",
        // kAFAssistantErrorDomain 216 "session ended", 209 "cancelled".
        if error.domain == "kLSRErrorDomain" && error.code == 301 { return true }
        if error.domain == "kAFAssistantErrorDomain" && (error.code == 216 || error.code == 209) { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("cancel")
    }

    static func isSilenceTimeout(_ error: NSError) -> Bool {
        // kAFAssistantErrorDomain 1110 "No speech detected".
        error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    static func isTransient(_ error: NSError) -> Bool {
        // 203 "Retry", 1107 timeout, 1101/1700 connection problems.
        if error.domain == "kAFAssistantErrorDomain" {
            return [203, 1107, 1101, 1700].contains(error.code)
        }
        if error.domain == NSURLErrorDomain { return true }
        return false
    }

    // MARK: - Authorization

    private static func ensureSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            // `@Sendable` matters: the handler runs on a TCC background
            // queue. Without it the closure inherits this class's main-actor
            // isolation and Swift 6's runtime isolation check traps
            // (EXC_BREAKPOINT in dispatch_assert_queue) the first time the
            // user taps Allow.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                cont.resume(returning: status)
            }
        }
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }
}

// MARK: - Errors

enum VoiceEngineError: LocalizedError {
    case notPrepared
    case speechUnavailable
    case speechDenied
    case microphoneDenied
    case localeUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "The microphone isn't ready. Check that no other app is using it."
        case .speechUnavailable:
            return "Speech recognition isn't available right now. Enable Dictation in Settings → General → Keyboard, or connect to the internet."
        case .speechDenied:
            return "Speech recognition is turned off for AnkiVoice. Allow it in Settings → Privacy & Security → Speech Recognition."
        case .microphoneDenied:
            return "Microphone access is turned off for AnkiVoice. Allow it in Settings → Privacy & Security → Microphone."
        case .localeUnsupported(let locale):
            return "Speech recognition for \(locale) is not supported on this device."
        }
    }

    static func describe(_ error: Error, locale: String) -> String {
        if let engineError = error as? VoiceEngineError {
            return engineError.errorDescription ?? "Voice recognition failed."
        }
        return RecognitionErrorClassifier.message(for: error as NSError, locale: locale)
    }
}

// MARK: - Recognition error classifier

enum RecognitionErrorClassifier {
    static func message(for error: NSError, locale: String) -> String {
        switch error.code {
        case 11_103, -1_9241:
            return "Voice recognition is not ready (\(locale)). Enable Dictation in Settings → General → Keyboard → Dictation, or connect to Wi-Fi and try again."
        case 11_100:
            return "Voice recognition is not available on this device."
        case 11_101, 1101:
            return "Voice recognition is busy. Close other microphone apps and try again."
        case 11_104:
            return "Voice recognition was cancelled."
        case 1110:
            return "Voice recognition didn't hear anything. Tap Reveal or speak again."
        case 203, 1107, 1700:
            return "Voice recognition lost its connection. Check your internet connection or enable on-device dictation for \(locale)."
        default:
            return "Voice recognition failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Confirmation tone

actor TonePlayer {
    static let shared = TonePlayer()
    private var player: AVAudioPlayer?
    private init() {}

    func play() async {
        if player == nil {
            player = try? AVAudioPlayer(data: Self.toneData())
            player?.prepareToPlay()
        }
        player?.currentTime = 0
        player?.play()
        try? await Task.sleep(for: .milliseconds(90))
    }

    static func toneData() -> Data {
        let sampleRate = 44_100.0
        let duration = 0.09
        let fade = 0.01
        let count = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var amplitude = 0.28
            if t < fade { amplitude *= t / fade }
            if t > duration - fade { amplitude *= (duration - t) / fade }
            let value = sin(2 * .pi * 880 * t) * amplitude
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }
        var data = Data()
        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        appendU32(UInt32(36 + samples.count * 2))
        append("WAVE")
        append("fmt ")
        appendU32(16); appendU16(1); appendU16(1)
        appendU32(44_100); appendU32(44_100 * 2)
        appendU16(2); appendU16(16)
        append("data"); appendU32(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
