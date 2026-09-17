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
    private var mediaDirectory: URL?
    private var warmedUp = false

    /// Voice catalog dependency (injected for tests).
    var catalog: VoiceCatalogProtocol = SystemVoiceCatalog()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speaks segments to completion. Cancels anything in flight when the
    /// session controller interrupts.
    public func speak(_ segments: [SpeechRenderer.Segment], config: VoiceConfig) async {
        guard !segments.isEmpty else { return }
        for segment in segments {
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
    public func preview(voiceIdentifier: String, text: String, rate: Double) async {
        stopSpeaking()
        Self.ensurePlaybackSession()
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
        stopSpeaking()
        Self.ensurePlaybackSession()
        let config = VoiceConfig(questionLocale: locale, answerLocale: locale, questionVoice: preferredVoice, answerVoice: preferredVoice)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(locale: locale, config: config)
        utterance.rate = Self.utteranceRate(multiplier: rate)
        utterance.prefersAssistiveTechnologySettings = false
        await speakAndWait(utterance)
    }

    /// Queues `utterance` and suspends until it finishes or is cancelled.
    private func speakAndWait(_ utterance: AVSpeechUtterance) async {
        await withCheckedContinuation { continuation in
            continuations.append((ObjectIdentifier(utterance), continuation))
            synthesizer.speak(utterance)
        }
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        resumeAll()
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

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
    /// 1. The deck's explicit voice for the side being spoken, when it is
    ///    installed and speaks the segment's language.
    /// 2. The best automatic voice for the locale (see `VoiceSelector`).
    func selectVoice(locale: String, config: VoiceConfig) -> String? {
        let languageKey = SettingsStore.languageKey(for: locale)
        let localized = catalog.voices(matching: languageKey)

        let side: SpeechSide = config.activeSide
            ?? (locale == config.questionLocale ? .question : .answer)
        if let explicit = config.explicitVoice(for: side), !explicit.isEmpty,
           let match = localized.first(where: { $0.identifier == explicit }) {
            return match.identifier
        }

        return VoiceSelector.best(
            localized: localized,
            allVoices: catalog.voices(matching: ""),
            requestedLocale: locale,
            preferredQuality: config.preferredQuality
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(locale: locale, config: config)
        utterance.rate = Self.utteranceRate(multiplier: config.speechRate)
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        await speakAndWait(utterance)
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
    /// locale and quality preference. No AVFoundation calls — safe to unit test
    /// with an `InMemoryVoiceCatalog`.
    enum VoiceSelector {
        /// Picks the best voice for `requestedLocale`.
        ///
        /// Language match always beats quality: a premium Japanese voice must
        /// never be chosen to read English. Within the requested language,
        /// quality tiers are walked from the preferred one down, preferring the
        /// exact regional variant inside each tier. Novelty and personal
        /// voices are never auto-selected. Only when the language has no
        /// usable voice at all do we fall back to the best voice in any
        /// language, so the text is still spoken.
        static func best(
            localized: [VoiceCatalogVoice],
            allVoices: [VoiceCatalogVoice],
            requestedLocale: String,
            preferredQuality: SettingsStore.VoiceQuality
        ) -> String? {
            let tiers: [VoiceQualityTier] = {
                switch preferredQuality {
                case .premium, .auto: return [.premium, .enhanced, .compact]
                case .enhanced: return [.enhanced, .premium, .compact]
                }
            }()

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

    public func setMediaDirectory(_ url: URL?) {
        self.mediaDirectory = url
    }

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
