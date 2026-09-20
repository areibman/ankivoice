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
    /// Feeds captured audio to the current request. Capture runs for the whole
    /// session; this is what gets detached to go half-duplex while speaking.
    private let sink = AudioTapSink()
    private var tapInstalled = false

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
    /// Hears speech the recognizer has not transcribed yet. On-device
    /// recognition often emits nothing at all for a one-word utterance, so
    /// the transcript-based watchdog never starts and the audio is discarded.
    private let energyMeter = UtteranceEnergyMonitor()
    /// True after the request was closed to force a hypothesis for short speech.
    private var finalizingUtterance = false
    private var finalizeTimeout: Task<Void, Never>?

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
        // Audio never leaves the device: recognition runs on the dictation
        // model iOS installs for the locale, or not at all.
        guard sfRecognizer.supportsOnDeviceRecognition else {
            throw VoiceEngineError.onDeviceUnavailable(self.commandLocale)
        }
        sfRecognizer.defaultTaskHint = .search
        speechRecognizer = sfRecognizer

        // Open the microphone now, while the app is certain to be in the
        // foreground, and leave it open for the session. A first cold start
        // from the background — the user locks the screen during the opening
        // question — is the one the system is most likely to refuse.
        try? await startAudioCapture()
        speechLog.info("[VOICE] prepare() complete, on-device recognition ready")
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
        stopAudioCapture()
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
        clearShortUtteranceWait()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Dictation waits for sentence-shaped speech and withholds a hypothesis
        // for "easy" or a one-word answer. Search/confirmation commit sooner.
        request.taskHint = Self.recognitionTaskHint(for: phase)
        request.contextualStrings = Self.contextualStrings(for: phase)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false

        do {
            try await startAudioCapture()
        } catch {
            request.endAudio()
            throw error
        }
        // Stop or a newer window won while capture was starting.
        guard generation == gen else {
            request.endAudio()
            return
        }

        self.request = request
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

        // Buffers only start reaching the recognizer once the task exists, so
        // nothing captured while the app was speaking leaks into this window.
        // Reset the meter here too: a buffer can land between the earlier
        // clear and this attach.
        energyMeter.reset()
        sink.attach(request)
        startSilenceWatchdog(generation: gen)
        speechLog.info("[VOICE] listening phase=\(String(describing: self.phase), privacy: .public) gen=\(gen)")
    }

    /// Ends the current recognition window but leaves the microphone running.
    ///
    /// Capture deliberately outlives the window: tearing the audio engine down
    /// between every question, answer and rating is what broke hands-free use
    /// with the screen locked. The `audio` background mode only keeps the app
    /// alive while audio is actually flowing, so each silent gap was a chance
    /// for iOS to suspend the process — and restarting capture from the
    /// background is frequently refused outright. Detaching the sink is enough
    /// to stay half-duplex: buffers keep arriving and are dropped on the floor.
    private func stopRecognition() {
        generation += 1
        listening = false
        silenceTask?.cancel()
        silenceTask = nil
        clearShortUtteranceWait()
        energyMeter.reset()
        sink.attach(nil)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    // MARK: - Microphone capture

    /// Starts continuous capture, or returns immediately when it's already
    /// running. Safe to call on every listening window.
    private func startAudioCapture() async throws {
        if audioEngine.isRunning, tapInstalled { return }

        var lastError: Error?
        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(150 * attempt))
            }
            // The session may have been deactivated by an interruption (call,
            // Siri) or refused while the screen was locking.
            let controller = audioSessionController ?? AudioSessionController.shared
            audioSessionController = controller
            await controller.activateForRecording()
            do {
                try installTapAndStart()
                observeConfigurationChanges()
                speechLog.info("[VOICE] microphone capture running (attempt \(attempt + 1))")
                return
            } catch {
                lastError = error
                speechLog.error(
                    "[VOICE] capture start failed: \(error.localizedDescription, privacy: .public)"
                )
                stopAudioCapture()
            }
        }
        throw lastError ?? VoiceEngineError.notPrepared
    }

    private func installTapAndStart() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceEngineError.notPrepared
        }
        // The tap runs on the audio render thread and must not inherit
        // main-actor isolation (see ensureSpeechAuthorization for the crash
        // that causes), so it talks to the lock-protected sink instead of
        // touching engine state.
        let sink = self.sink
        let energyMeter = self.energyMeter
        // AVAudioEngine raises Objective-C exceptions for a tap whose format
        // no longer matches the hardware (AirPods switching profiles mid-
        // session is the classic case). Catch them so the session degrades
        // to an error message instead of crashing.
        var startError: Error?
        try ObjCException.catching {
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                // Level is measured only while a window is open, so speech
                // from the speaker leaking into the mic doesn't count.
                if sink.isAttached {
                    energyMeter.observe(buffer)
                }
                sink.append(buffer)
            }
            audioEngine.prepare()
            do { try audioEngine.start() } catch { startError = error }
        }
        if let startError { throw startError }
        tapInstalled = true
    }

    private func stopAudioCapture() {
        sink.attach(nil)
        guard tapInstalled || audioEngine.isRunning else { return }
        try? ObjCException.catching {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine.reset()
        tapInstalled = false
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
        // The engine stops itself on a hardware format change, so capture has
        // to be rebuilt even when no recognition window is open — otherwise
        // the next one starts against a dead engine.
        stopAudioCapture()
        guard listening else { return }
        speechLog.info("[VOICE] audio configuration changed; reinstalling tap")
        restartRecognition(reason: "configuration change")
    }

    /// Capture died underneath an open listening window. Rebuild it a bounded
    /// number of times before handing the user an error, so a wedged input
    /// device can't spin the session.
    private func recoverFromLostCapture() {
        guard listening else { return }
        guard restartCount < 5 else {
            speechLog.error("[VOICE] microphone did not come back; giving up")
            listening = false
            stopRecognition()
            stopAudioCapture()
            continuation.yield(.failure("The microphone stopped responding. Tap Resume to try again."))
            return
        }
        restartCount += 1
        stopAudioCapture()
        restartRecognition(reason: "microphone stopped")
    }

    /// Restarts recognition in the same phase after the recognizer closed the
    /// request on its own (silence timeout, ~1 minute cloud limit, transient
    /// error). Preserves the phase so a rating window can wait indefinitely.
    private func restartRecognition(reason: String) {
        guard listening else { return }
        speechLog.info("[VOICE] restarting recognition (\(reason, privacy: .public))")
        stopRecognition()
        listening = true
        let ticket = generation
        Task { [weak self] in
            guard let self, self.generation == ticket else { return }
            do {
                try await self.beginRecognition()
            } catch {
                // A stop or a newer window moved the generation on; it owns the mic.
                guard self.generation == ticket || self.generation == ticket &+ 1 else { return }
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

        // A non-empty hypothesis wins over a companion error. Closing a short
        // utterance often delivers the word and "no speech" together; dropping
        // the word is the bug this path exists to avoid.
        var heardSpeech = false
        if let result {
            let text = result.text
            let normalized = CommandRecognizer.normalize(text)
            if !normalized.isEmpty, normalized != lastNormalizedTranscript {
                heardSpeech = true
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
                clearShortUtteranceWait()
                endUtterance(reason: "final result")
                return
            }
        }

        if heardSpeech { return }

        if let error {
            clearShortUtteranceWait()
            handleRecognitionError(error as NSError)
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
    ///
    /// When the recognizer has produced no transcript at all, a shorter quiet
    /// stretch after detected speech closes the request instead. Leaving it
    /// open is what makes "easy" and a one-word answer disappear.
    private func startSilenceWatchdog(generation gen: Int) {
        silenceTask?.cancel()
        let endpoint = Double(endpointMs) / 1000.0
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, self.generation == gen, self.listening else { return }
                // Capture can die without a notification — the system clawing
                // back the input while locked, say — which would otherwise
                // leave the window open and deaf forever.
                guard self.audioEngine.isRunning else {
                    self.recoverFromLostCapture()
                    return
                }
                if let last = self.lastSpeechAt {
                    if Date().timeIntervalSince(last) >= endpoint {
                        self.endUtterance(reason: "silence")
                        return
                    }
                    continue
                }
                // No transcript yet. If the mic heard a word and then quiet,
                // close the request so the on-device model has to commit
                // instead of eventually reporting "no speech" and dropping it.
                let required = Self.unreportedSpeechSilence(phase: self.phase, endpointMs: self.endpointMs)
                if Self.shouldForceFinalize(
                    hasTranscript: false,
                    alreadyFinalizing: self.finalizingUtterance,
                    trailingSilence: self.energyMeter.trailingSilence(),
                    silenceRequired: required
                ) {
                    self.finalizeUnreportedSpeech()
                    return
                }
            }
        }
    }

    /// Closes the recognition request without cancelling it, so the on-device
    /// model has to return a hypothesis for the short audio it already has.
    /// Cancelling here is what drops the word; `finish()` is what surfaces it.
    private func finalizeUnreportedSpeech() {
        guard listening, !finalizingUtterance, let request, let task else { return }
        finalizingUtterance = true
        let gen = generation
        speechLog.info("[VOICE] ending audio to recognize a short utterance")
        sink.attach(nil)
        finalizeTimeout?.cancel()
        finalizeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2000))
            guard let self, self.generation == gen, self.listening, self.finalizingUtterance else { return }
            if self.lastTranscript.isEmpty {
                self.restartRecognition(reason: "short utterance produced no result")
            } else {
                // A hypothesis arrived without isFinal. Don't throw the words away.
                self.endUtterance(reason: "short utterance")
            }
        }
        request.endAudio()
        task.finish()
    }

    private func clearShortUtteranceWait() {
        finalizingUtterance = false
        finalizeTimeout?.cancel()
        finalizeTimeout = nil
    }

    // MARK: - Helpers

    private func ensureSpeaker() -> TextToSpeech {
        if let tts { return tts }
        let speaker = TextToSpeech(mediaDirectory: try? AppServices.mediaDirectory())
        tts = speaker
        return speaker
    }

    /// Quiet after speech the recognizer still hasn't transcribed, before the
    /// request is closed. Long enough for a word to decay into the buffer,
    /// short enough that the on-device model hasn't discarded it. The rating
    /// window's longer "um…" pause still applies once a transcript exists.
    nonisolated static let shortUtteranceSilence: TimeInterval = 0.60

    nonisolated static func recognitionTaskHint(for phase: CommandRecognizer.ListeningPhase) -> SFSpeechRecognitionTaskHint {
        switch phase {
        case .awaitingAnswer:
            return .search
        case .awaitingRating, .paused:
            return .confirmation
        }
    }

    /// Answer turns use the configured endpoint, so a patient pause still
    /// holds the mic. Command turns cap it: two seconds of trailing silence
    /// is long enough for the model to throw a one-word rating away.
    nonisolated static func unreportedSpeechSilence(
        phase: CommandRecognizer.ListeningPhase,
        endpointMs: Int
    ) -> TimeInterval {
        let configured = Double(endpointMs) / 1000
        switch phase {
        case .awaitingAnswer:
            return configured
        case .awaitingRating, .paused:
            return min(configured, shortUtteranceSilence)
        }
    }

    nonisolated static func shouldForceFinalize(
        hasTranscript: Bool,
        alreadyFinalizing: Bool,
        trailingSilence: TimeInterval?,
        silenceRequired: TimeInterval
    ) -> Bool {
        guard !alreadyFinalizing, !hasTranscript, let trailingSilence else { return false }
        return trailingSilence >= silenceRequired
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

// MARK: - Short-utterance energy meter

/// Tracks whether the microphone has heard speech, independent of the recognizer.
///
/// On-device recognition often emits no partial and no final result for a
/// single word. The engine uses this to notice the word anyway and close
/// the request, which is what forces a hypothesis.
struct UtteranceEnergyMeter: Sendable {
    /// About −38 dBFS. Quiet room noise sits under this; a spoken word doesn't.
    var minimumOnsetRMS: Float = 0.012
    /// Shorter than this is a tap or a click, not a word.
    var minimumSpeech: TimeInterval = 0.12

    private(set) var noiseFloor: Float = 0.003
    private var speaking = false
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    /// Quiet time after speech long enough to be a word. Nil while the user
    /// is still going, or if nothing long enough to be speech has been heard.
    var trailingSilence: TimeInterval? {
        guard speechDuration >= minimumSpeech, silenceDuration > 0 else { return nil }
        return silenceDuration
    }

    mutating func reset() {
        speaking = false
        speechDuration = 0
        silenceDuration = 0
    }

    mutating func observe(rms: Float, duration: TimeInterval) {
        let dt = max(duration, 0)
        guard dt > 0, rms.isFinite else { return }
        let onset = max(minimumOnsetRMS, noiseFloor * 6)
        let release = onset * 0.6

        if !speaking {
            if rms >= onset {
                speaking = true
                speechDuration = dt
                silenceDuration = 0
            } else {
                adaptFloor(toward: rms)
            }
            return
        }

        if rms >= release {
            speechDuration += dt
            silenceDuration = 0
        } else {
            silenceDuration += dt
        }
    }

    private mutating func adaptFloor(toward rms: Float) {
        if rms < noiseFloor {
            noiseFloor += (rms - noiseFloor) * 0.35
        } else {
            noiseFloor += (rms - noiseFloor) * 0.02
        }
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        if let data = buffer.floatChannelData {
            var sum: Float = 0
            for channel in 0..<channels {
                let samples = data[channel]
                for index in 0..<frames {
                    let sample = samples[index]
                    sum += sample * sample
                }
            }
            return (sum / Float(frames * channels)).squareRoot()
        }
        if let data = buffer.int16ChannelData {
            var sum: Float = 0
            let scale = 1 / Float(Int16.max)
            for channel in 0..<channels {
                let samples = data[channel]
                for index in 0..<frames {
                    let sample = Float(samples[index]) * scale
                    sum += sample * sample
                }
            }
            return (sum / Float(frames * channels)).squareRoot()
        }
        return 0
    }
}

/// Audio-thread side of `UtteranceEnergyMeter`. The render thread only holds
/// the lock long enough to record one buffer's RMS.
final class UtteranceEnergyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var meter = UtteranceEnergyMeter()

    func reset() {
        lock.lock()
        meter.reset()
        lock.unlock()
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        guard rate > 0, buffer.frameLength > 0 else { return }
        let rms = UtteranceEnergyMeter.rms(of: buffer)
        let duration = Double(buffer.frameLength) / rate
        lock.lock()
        meter.observe(rms: rms, duration: duration)
        lock.unlock()
    }

    func trailingSilence() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return meter.trailingSilence
    }
}

// MARK: - Audio tap sink

/// Bridge between the audio render thread and the recognition window.
///
/// The microphone tap runs continuously for the whole session, so the request
/// it feeds has to be swappable from the main actor while buffers are in
/// flight: a fresh request per listening window, and nil while the app is
/// speaking. The lock is held only long enough to read the reference — never
/// across `append`, which must not block the render thread.
final class AudioTapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Buffers dropped because no window was open. Test/diagnostic only.
    private(set) var droppedBuffers = 0

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let target = request
        if target == nil { droppedBuffers += 1 }
        lock.unlock()
        target?.append(buffer)
    }

    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return request != nil
    }
}

// MARK: - Errors

enum VoiceEngineError: LocalizedError {
    case notPrepared
    case speechUnavailable
    case speechDenied
    case microphoneDenied
    case localeUnsupported(String)
    case onDeviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "The microphone isn't ready. Check that no other app is using it."
        case .speechUnavailable:
            return "Speech recognition isn't available right now. Enable Dictation in Settings → General → Keyboard and try again."
        case .speechDenied:
            return "Speech recognition is turned off for AnkiVoice. Allow it in Settings → Privacy & Security → Speech Recognition."
        case .microphoneDenied:
            return "Microphone access is turned off for AnkiVoice. Allow it in Settings → Privacy & Security → Microphone."
        case .localeUnsupported(let locale):
            return "Speech recognition for \(locale) is not supported on this device."
        case .onDeviceUnavailable(let locale):
            return "The on-device speech model for \(locale) isn't installed. Turn on Dictation in Settings → General → Keyboard so iOS downloads it; AnkiVoice never sends audio off the device."
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
            return "Voice recognition is not ready (\(locale)). Enable Dictation in Settings → General → Keyboard → Dictation so iOS installs the on-device model, then try again."
        case 11_100:
            return "Voice recognition is not available on this device."
        case 11_101, 1101:
            return "Voice recognition is busy. Close other microphone apps and try again."
        case 11_104:
            return "Voice recognition was cancelled."
        case 1110:
            return "Voice recognition didn't hear anything. Tap Reveal or speak again."
        case 203, 1107, 1700:
            return "Voice recognition stopped unexpectedly. Make sure Dictation is enabled for \(locale) in Settings → General → Keyboard, then try again."
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
