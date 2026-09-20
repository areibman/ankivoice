import Foundation
import AVFAudio

/// Text-to-speech via AVSpeechSynthesizer (PRD §17).
///
/// Speaks `SpeechRenderer.Segment`s sequentially: per-utterance voices and
/// locales, pauses, and pre-recorded media. Completion is awaitable so the
/// session controller can enforce half-duplex ordering.
@MainActor
public final class TextToSpeech: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    /// One waiter per in-flight utterance, keyed by the utterance's identity
    /// so a late `didCancel` for an utterance that `stopSpeaking()` already
    /// resumed can't steal the continuation of the one that replaced it.
    private var continuations: [(utterance: ObjectIdentifier, continuation: CheckedContinuation<Void, Never>)] = []
    private var playerContinuations: [CheckedContinuation<Void, Never>] = []
    private var audioPlayer: AVAudioPlayer?
    /// Where `.media` segments are resolved; nil skips recorded audio.
    private let mediaDirectory: URL?
    private var warmedUp = false
    /// Bumped by `stopSpeaking()` so an in-flight neural synthesis is dropped.
    private var neuralGeneration = 0
    /// Set by `stopSpeaking()` so a cancelled `speak()` doesn't continue
    /// to the next segment after a long neural inference returns.
    private var stopped = false

    /// Voice catalog dependency (injected for tests).
    var catalog: VoiceCatalogProtocol = AppVoiceCatalog()

    public init(mediaDirectory: URL? = nil) {
        self.mediaDirectory = mediaDirectory
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speaks segments to completion. Cancels anything in flight when the
    /// session controller interrupts.
    public func speak(_ segments: [SpeechRenderer.Segment], config: VoiceConfig) async {
        guard !segments.isEmpty else { return }
        stopped = false
        for segment in segments {
            if stopped { return }
            switch segment {
            case .speech(let text, let locale):
                await speakText(text, locale: locale, config: config)
            case .pause(let seconds):
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            case .media(let filename):
                await playMedia(filename)
            }
        }
    }

    /// Speaks a short sample with a specific voice (voice picker preview).
    /// Interrupts any current speech.
    public func preview(voiceIdentifier: String, text: String, rate: Double, locale: String = "en-US") async {
        stopSpeaking()
        stopped = false
        Self.ensurePlaybackSession()
        if SupertonicVoiceCatalog.isSupertonic(voiceIdentifier) {
            await speakSupertonic(text: text, locale: locale, voiceIdentifier: voiceIdentifier, rate: rate)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        utterance.rate = Self.utteranceRate(multiplier: rate)
        utterance.prefersAssistiveTechnologySettings = false
        await speakAndWait(utterance)
    }

    /// Reads arbitrary text in `locale` with the voice the app would use for
    /// that language (deck previews). Interrupts any current speech.
    ///
    /// - Parameter preferredVoice: the user's chosen default voice for the
    ///   language (Settings ▸ Voices), so previews sound like sessions will.
    ///   Ignored when it isn't installed or doesn't speak `locale`.
    public func previewText(_ text: String, locale: String, rate: Double, preferredVoice: String? = nil) async {
        await previewRuns([(text: text, locale: locale, voice: preferredVoice)], rate: rate)
    }

    /// Speaks each run in order. Callers that want one speaker pass the same
    /// voice on every run; the locale is only how that speaker pronounces
    /// the chunk (Supertonic), not a reason to pick someone else.
    public func previewRuns(_ runs: [(text: String, locale: String, voice: String?)], rate: Double) async {
        stopSpeaking()
        stopped = false
        Self.ensurePlaybackSession()
        for run in runs {
            if stopped { return }
            let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let config = VoiceConfig(
                questionLocale: run.locale,
                answerLocale: run.locale,
                questionVoice: run.voice,
                speechRate: rate,
                activeSide: .question
            )
            await speakText(trimmed, locale: run.locale, config: config)
        }
    }

    /// Queues `utterance` and suspends until it finishes or is cancelled.
    private func speakAndWait(_ utterance: AVSpeechUtterance) async {
        await withCheckedContinuation { continuation in
            continuations.append((ObjectIdentifier(utterance), continuation))
            synthesizer.speak(utterance)
        }
    }

    public func stopSpeaking() {
        stopped = true
        neuralGeneration += 1
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        resumeAll()
    }

    /// Warms the synthesis engine with an empty utterance to avoid first-
    /// utterance latency on real devices.
    public func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        let utterance = AVSpeechUtterance(string: " ")
        utterance.volume = 0
        utterance.rate = AVSpeechUtteranceMaximumSpeechRate
        warmUpUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// The silent warm-up utterance has no awaiting continuation, so its
    /// delegate callbacks must not pop a real one.
    private var warmUpUtterance: AVSpeechUtterance?

    // MARK: - Voice selection

    /// Resolves the voice identifier for one utterance.
    ///
    /// Order of precedence:
    /// 1. The voice chosen for this side of the card, if it is still
    ///    installed. It stays for the whole side — a Japanese deck must not
    ///    swap speakers every time a gloss, reading, or kanji run is detected
    ///    as another language.
    /// 2. The user's default voice for the utterance's language.
    /// 3. The best automatic voice for the locale (see `VoiceSelector`).
    func selectVoice(locale: String, config: VoiceConfig) -> String? {
        let languageKey = SettingsStore.languageKey(for: locale)
        let localized = catalog.voices(matching: languageKey)
        let installed = catalog.voices(matching: "")

        let side: SpeechSide = config.activeSide
            ?? (locale == config.questionLocale ? .question : .answer)
        func known(_ identifier: String?, in voices: [VoiceCatalogVoice]) -> String? {
            guard let identifier, !identifier.isEmpty else { return nil }
            return voices.first { $0.identifier == identifier }?.identifier
        }
        if let match = known(config.explicitVoice(for: side), in: installed) { return match }
        if let match = known(config.languageVoices[languageKey], in: localized) { return match }
        // The user picked one Supertonic speaker for some other language.
        // Keep that person when this language has no pick of its own.
        if SupertonicVoiceCatalog.supports(languageKey: languageKey),
           let carried = config.languageVoices.values
            .filter(SupertonicVoiceCatalog.isSupertonic)
            .sorted()
            .first,
           let match = known(carried, in: installed) {
            return match
        }

        return VoiceSelector.best(
            localized: localized,
            allVoices: catalog.voices(matching: ""),
            requestedLocale: locale
        )
    }

    private func voice(locale: String, config: VoiceConfig) -> AVSpeechSynthesisVoice? {
        guard let identifier = selectVoice(locale: locale, config: config) else {
            // Nothing installed for the language: let the system pick its
            // default so the text is at least spoken.
            return AVSpeechSynthesisVoice(language: locale)
        }
        return AVSpeechSynthesisVoice(identifier: identifier)
    }

    private func speakText(_ text: String, locale: String, config: VoiceConfig) async {
        if let identifier = selectVoice(locale: locale, config: config),
           SupertonicVoiceCatalog.isSupertonic(identifier) {
            await speakSupertonic(text: text, locale: locale, voiceIdentifier: identifier, rate: config.speechRate)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(locale: locale, config: config)
        utterance.rate = Self.utteranceRate(multiplier: config.speechRate)
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        await speakAndWait(utterance)
    }

    /// Runs Supertonic 3 and plays the resulting PCM. Falls back to the
    /// system voice if the model isn't ready or synthesis fails, so a
    /// study session never stalls on a download error.
    private func speakSupertonic(
        text: String,
        locale: String,
        voiceIdentifier: String,
        rate: Double
    ) async {
        neuralGeneration += 1
        let generation = neuralGeneration
        do {
            let result = try await SupertonicTTS.shared.synthesize(
                text: text,
                locale: locale,
                voiceIdentifier: voiceIdentifier,
                speed: rate
            )
            guard generation == neuralGeneration, !stopped else { return }
            await playPCM(result.samples, sampleRate: result.sampleRate)
        } catch {
            guard generation == neuralGeneration, !stopped else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: locale)
            utterance.rate = Self.utteranceRate(multiplier: rate)
            utterance.prefersAssistiveTechnologySettings = false
            await speakAndWait(utterance)
        }
    }

    private func playPCM(_ samples: [Float], sampleRate: Int) async {
        guard !samples.isEmpty else { return }
        let data = PCMWav.data(samples: samples, sampleRate: sampleRate)
        await withCheckedContinuation { continuation in
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.audioPlayer = player
                playerContinuations.append(continuation)
                player.play()
            } catch {
                continuation.resume()
            }
        }
    }

    /// Maps the 0.5…2.0 user multiplier onto AVSpeechUtterance's rate range.
    static func utteranceRate(multiplier: Double) -> Float {
        let clamped = Float(min(max(multiplier, 0.5), 2.0))
        let base = AVSpeechUtteranceDefaultSpeechRate
        return min(max(base * clamped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Makes sure previews are audible when no study session has configured
    /// the audio session (the default category is silenced by the ring switch).
    static func ensurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord, session.category != .playback else { return }
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Pure selector: pick the best voice identifier for the requested
    /// locale. No AVFoundation calls — safe to unit test with an
    /// `InMemoryVoiceCatalog`.
    enum VoiceSelector {
        /// Picks the best voice for `requestedLocale`.
        ///
        /// Language match always beats quality: a premium Japanese voice must
        /// never be chosen to read English. Within the requested language,
        /// quality tiers are walked from Premium down, preferring the exact
        /// regional variant inside each tier. Novelty and personal voices are
        /// never auto-selected. Only when the language has no usable voice at
        /// all do we fall back to the best voice in any language, so the text
        /// is still spoken.
        static func best(
            localized: [VoiceCatalogVoice],
            allVoices: [VoiceCatalogVoice],
            requestedLocale: String
        ) -> String? {
            let tiers: [VoiceQualityTier] = [.premium, .enhanced, .compact]

            let eligible = localized.filter(\.isAutoEligible)
            let exact = eligible.filter { $0.language.caseInsensitiveCompare(requestedLocale) == .orderedSame }
            for tier in tiers {
                if let v = exact.first(where: { $0.quality == tier }) { return v.identifier }
                if let v = eligible.first(where: { $0.quality == tier }) { return v.identifier }
            }

            let anyEligible = allVoices.filter(\.isAutoEligible)
            for tier in tiers {
                if let v = anyEligible.first(where: { $0.quality == tier }) { return v.identifier }
            }
            return nil
        }
    }

    // MARK: - Media

    /// Plays an imported recording; silently skips files that aren't there.
    private func playMedia(_ filename: String) async {
        guard let dir = mediaDirectory else { return }
        let sanitized = filename.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        await withCheckedContinuation { continuation in
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                self.audioPlayer = player
                playerContinuations.append(continuation)
                player.play()
            } catch {
                continuation.resume()
            }
        }
    }

    // MARK: - Completion plumbing

    private func resumeAll() {
        let pending = continuations.map(\.continuation) + playerContinuations
        continuations = []
        playerContinuations = []
        pending.forEach { $0.resume() }
    }

    /// Resumes the waiter for one utterance. No-op when `stopSpeaking()`
    /// already resumed it — the synthesizer still reports the cancellation
    /// afterwards, and that report must not touch newer utterances.
    private func resume(utterance id: ObjectIdentifier) {
        guard let index = continuations.firstIndex(where: { $0.utterance == id }) else { return }
        continuations.remove(at: index).continuation.resume()
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in
            if self.consumeWarmUp(finished) { return }
            self.resume(utterance: finished)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelled = ObjectIdentifier(utterance)
        Task { @MainActor in
            if self.consumeWarmUp(cancelled) { return }
            self.resume(utterance: cancelled)
        }
    }

    /// True when the callback belongs to the silent warm-up utterance.
    private func consumeWarmUp(_ id: ObjectIdentifier) -> Bool {
        guard let warm = warmUpUtterance, ObjectIdentifier(warm) == id else { return false }
        warmUpUtterance = nil
        return true
    }
}

extension TextToSpeech: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if !self.playerContinuations.isEmpty {
                self.playerContinuations.removeFirst().resume()
            }
        }
    }
}

/// 16-bit PCM WAV, little-endian. Compact enough to hand to AVAudioPlayer.
enum PCMWav {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * MemoryLayout<Int16>.size
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        withUnsafeBytes(of: UInt32(16).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: Array("data".utf8))
        withUnsafeBytes(of: UInt32(dataSize).littleEndian) { header.append(contentsOf: $0) }

        var pcm = Data(count: dataSize)
        pcm.withUnsafeMutableBytes { raw in
            let dest = raw.bindMemory(to: Int16.self)
            for i in samples.indices {
                let clipped = max(-1, min(1, samples[i]))
                dest[i] = Int16((clipped * Float(Int16.max)).rounded())
            }
        }
        header.append(pcm)
        return header
    }
}
