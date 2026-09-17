import Foundation
import Observation

/// The deterministic review state machine (PRD §10).
///
/// Owns review state and drives the voice engine. All voice commands and all
/// touch controls funnel through the same transitions, so the touchscreen is
/// always a complete fallback (PRD §32).
@MainActor
@Observable
public final class StudySessionController {

    // MARK: - States (PRD §10)

    public enum SessionState: String, Equatable, Sendable {
        case idle
        case loadingCard
        case speakingPrompt
        case awaitingAnswer
        case answerInProgress
        case answerComplete
        case speakingAnswer
        case awaitingRating
        case processingRating
        case paused
        case finished
    }

    /// Which side of the card is being spoken.
    public enum Side: Sendable {
        case question, answer
    }

    // MARK: - Dependencies

    private let decks: DeckRepository
    private let cards: CardRepository
    private let reviews: ReviewRepository
    private let queue: StudyQueue
    private let renderer = SpeechRenderer()
    private let recognizer = CommandRecognizer()
    public let settings: SettingsStore

    /// Voice engine (mocked in tests).
    private(set) var engine: (any VoiceSessionEngine)?

    // MARK: - Session state

    public private(set) var state: SessionState = .idle
    /// False when the speech stack failed and the session degraded to
    /// touch-only mode; UI copy and hints adapt accordingly.
    public private(set) var voiceAvailable = true
    public private(set) var deck: Deck?
    public private(set) var currentCard: StudyCard?
    public private(set) var rendered: SpeechRenderer.RenderedCard?
    public private(set) var transcript: String = ""
    /// The user's spoken answer, accumulated during the answer phase.
    public private(set) var answerTranscript: String = ""
    public private(set) var remaining: StudyQueue.Remaining = .init()
    public private(set) var sessionLog: [SessionEntry] = []
    public private(set) var statusMessage: String?

    /// State before pausing, for resuming from a known position.
    private var stateBeforePause: SessionState?

    // Metrics
    public private(set) var reviewsThisSession = 0
    public private(set) var voiceReviews = 0
    public private(set) var touchReviews = 0
    public private(set) var startedAt: Date?
    public private(set) var touchInteractions = 0

    /// True when the current session ran entirely without touch interactions.
    public var completedWithoutTouch: Bool { touchInteractions == 0 && reviewsThisSession > 0 }

    /// Undo bookkeeping: the persisted review log plus the card's prior state.
    private struct UndoRecord {
        var logID: Int64
        var cardID: Int64
        var previousScheduling: SchedulingState
    }
    private var lastUndoRecord: UndoRecord?

    /// When the current card was shown (for review duration logging).
    private var cardShownAt: Date?
    /// Which side was spoken last (for "repeat").
    private var lastSpokenSide: Side = .question
    private var answerTimeoutTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var hintGivenForCurrentCard = false
    /// Cards temporarily skipped this session.
    private var skipSet: Set<Int64> = []
    /// Cached deck configs for the running session.
    private var studyConfig = StudyConfig()
    private var voiceConfig = VoiceConfig()

    public struct SessionEntry: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var timestamp: Date
        public var cardFront: String
        public var rating: Rating
        public var mode: StudyMode
        public var intervalDays: Int
    }

    // MARK: - Init

    public init(
        decks: DeckRepository, cards: CardRepository, reviews: ReviewRepository,
        queue: StudyQueue, settings: SettingsStore
    ) {
        self.decks = decks
        self.cards = cards
        self.reviews = reviews
        self.queue = queue
        self.settings = settings
    }

    // MARK: - Session lifecycle

    /// Starts a hands-free session for a deck.
    public func start(deck: Deck, engine: any VoiceSessionEngine) async {
        teardown(announce: false)
        self.engine = engine
        self.deck = deck
        startedAt = Date()
        voiceAvailable = true
        reviewsThisSession = 0
        voiceReviews = 0
        touchReviews = 0
        touchInteractions = 0
        sessionLog = []
        skipSet = []
        lastUndoRecord = nil
        statusMessage = nil

        let configs = (try? decks.config(for: deck.id)) ?? (StudyConfig(), VoiceConfig(), nil)
        studyConfig = configs.0
        voiceConfig = resolved(configs.1)

        do {
            try await engine.prepare(voice: voiceConfig, commandLocale: settings.commandLocale)
        } catch {
            voiceAvailable = false
            // Voice is unavailable (e.g. speech assets missing): continue in
            // touch-only mode rather than trapping the user (PRD §32).
            statusMessage = "Voice unavailable — running in touch-only mode. \(error.localizedDescription)"
            engine.shutdown()
            self.engine = TouchOnlyVoiceEngine()
            startEventPump()
            await loadNextCard()
            return
        }

        startEventPump()
        await loadNextCard()
    }

    /// Fills in the deck's unset voice options from the global settings:
    /// the user's default voice per language and the global speaking speed.
    private func resolved(_ config: VoiceConfig) -> VoiceConfig {
        var result = config
        if result.questionVoice == nil {
            result.questionVoice = settings.defaultVoice(forLocale: config.questionLocale)
        }
        if result.answerVoice == nil {
            result.answerVoice = settings.defaultVoice(forLocale: config.answerLocale)
        }
        if result.usesDefaultSpeechRate {
            result.speechRate = settings.speechRate
        }
        result.preferredQuality = settings.voiceQuality
        return result
    }

    /// Voice for app prompts ("Session paused", intervals): the user's default
    /// English voice at the global speed.
    private var noticeVoice: VoiceConfig {
        resolved(VoiceConfig()).speaking(.question)
    }

    /// Graceful stop; reviews are already persisted.
    ///
    /// Only a spoken "stop" gets a spoken acknowledgement — hands-free, it's
    /// the sole confirmation the command landed. Tapping End is its own
    /// confirmation: the screen closes, so the app just goes quiet.
    public func stop(mode: StudyMode = .touch) async {
        guard state != .idle else { return }
        if state == .finished {
            // Completion already announced itself; just clean up.
            teardown(announce: false)
            return
        }
        teardown(announce: mode == .voice)
    }

    private func teardown(announce: Bool) {
        NotificationCenter.default.post(name: .ankivoiceSessionDidEnd, object: nil)
        answerTimeoutTask?.cancel()
        eventTask?.cancel()
        engine?.stopListening()
        engine?.stopSpeaking()
        if announce {
            let engine = self.engine
            let voice = noticeVoice
            Task {
                await engine?.speak(
                    [.speech(text: "Session ended.", locale: "en-US")],
                    voice: voice
                )
                engine?.shutdown()
            }
        } else {
            engine?.shutdown()
        }
        engine = nil
        state = .idle
        currentCard = nil
        rendered = nil
    }

    private func startEventPump() {
        guard let engine else { return }
        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: - Card flow

    private func loadNextCard() async {
        state = .loadingCard
        transcript = ""
        answerTranscript = ""
        hintGivenForCurrentCard = false

        let deckID = deck?.id ?? 0
        if let card = try? queue.next(forDeck: deckID, config: studyConfig, exclude: skipSet) {
            currentCard = card
            cardShownAt = Date()
            rendered = renderer.render(
                card, questionLocale: voiceConfig.questionLocale,
                answerLocale: voiceConfig.answerLocale
            )
            remaining = (try? queue.remaining(forDeck: deckID, config: studyConfig)) ?? .init()
            lastSpokenSide = .question
            await speakPrompt()
        } else {
            await finishSession()
        }
    }

    private func speakPrompt() async {
        guard let rendered, let engine else { return }
        state = .speakingPrompt
        await engine.speak(rendered.question, voice: voiceConfig.speaking(.question))
        guard state == .speakingPrompt else { return }  // paused/interrupted mid-speech
        await beginAnswerPhase()
    }

    private func beginAnswerPhase() async {
        guard let engine else { return }
        state = .awaitingAnswer
        transcript = ""
        do {
            try await engine.startListening(
                phase: .awaitingAnswer, endpointMs: effectiveEndpointMs, recognizer: recognizer
            )
            scheduleAnswerTimeout()
        } catch {
            // Keep the card on screen: Reveal and the rating buttons still work.
            reportListeningFailure(error)
        }
    }

    private func speakAnswer() async {
        guard let rendered, let engine else { return }
        // Keep the user's spoken answer; from here on the transcript holds
        // rating-phase speech ("repeat", a hint-worthy mumble), not the answer.
        if !transcript.isEmpty {
            answerTranscript = transcript
        }
        state = .speakingAnswer
        lastSpokenSide = .answer
        await engine.speak(rendered.answer, voice: voiceConfig.speaking(.answer))
        guard state == .speakingAnswer else { return }
        await beginRatingPhase()
    }

    /// Silence after speech, in milliseconds, before the rating window treats
    /// an utterance as finished. Long enough for "um… good", short enough that
    /// a missed rating gets its hint promptly.
    static let ratingEndpointMs = 2000

    private func beginRatingPhase() async {
        guard let engine else { return }
        state = .awaitingRating
        transcript = ""
        do {
            try await engine.startListening(phase: .awaitingRating, endpointMs: Self.ratingEndpointMs, recognizer: recognizer)
        } catch {
            reportListeningFailure(error)
        }
    }

    /// Listens for "resume" / "stop" while paused.
    private func listenWhilePaused() async {
        guard let engine, state == .paused, voiceAvailable else { return }
        do {
            try await engine.startListening(phase: .paused, endpointMs: 2500, recognizer: recognizer)
        } catch {
            reportListeningFailure(error)
        }
    }

    /// The microphone or recognizer failed to start. The session stays in its
    /// current state so the on-screen controls remain a complete fallback.
    private func reportListeningFailure(_ error: Error) {
        statusMessage = "Voice paused — \(error.localizedDescription) You can keep going with the buttons."
    }

    private func finishSession() async {
        answerTimeoutTask?.cancel()
        engine?.stopListening()
        remaining = StudyQueue.Remaining()
        state = .finished
        NotificationCenter.default.post(name: .ankivoiceSessionDidEnd, object: nil)
        let summary = "Session complete. \(reviewsThisSession) cards reviewed."
        await engine?.speak([.speech(text: summary, locale: "en-US")], voice: noticeVoice)
    }

    // MARK: - Event handling

    private func handle(_ event: VoiceEvent) async {
        switch event {
        case .speechStarted:
            if state == .awaitingAnswer {
                answerTimeoutTask?.cancel()
                state = .answerInProgress
            }

        case .answerEnded:
            if state == .answerInProgress || state == .awaitingAnswer {
                engine?.stopListening()
                state = .answerComplete
                await speakAnswer()
            }

        case .command(let command):
            await handleCommand(command, mode: .voice)

        case .commandNotRecognized(let heard):
            await handleUnrecognizedSpeech(heard)

        case .transcript(let text):
            transcript = text

        case .interruptionBegan:
            pauseForInterruption(announce: false)

        case .interruptionEnded:
            if state == .paused {
                statusMessage = "Say resume, or tap Resume, to continue."
                await listenWhilePaused()
            }

        case .routeChanged(let old, let new):
            if settings.pauseWhenHeadphonesDisconnect,
               Self.isHeadphoneRoute(old), !Self.isHeadphoneRoute(new) {
                await pause(mode: .voice)
            }

        case .failure(let message):
            statusMessage = message
        }
    }

    /// The user said something in a command phase that wasn't a command.
    /// Ignoring it is what makes voice mode feel broken, so say exactly what
    /// the app is waiting for, then reopen the microphone for another try.
    private func handleUnrecognizedSpeech(_ heard: String) async {
        switch state {
        case .awaitingRating:
            transcript = heard
            await speakNotice(ratingHint)
            guard state == .awaitingRating else { return }  // rated by touch / paused meanwhile
            await beginRatingPhase()
        case .paused:
            statusMessage = "Say resume, or tap Resume, to continue."
            await speakNotice("Say resume to continue, or stop to end the session.")
            guard state == .paused else { return }
            await listenWhilePaused()
        default:
            break
        }
    }

    /// What to say when a rating was expected but not heard.
    var ratingHint: String {
        settings.simplifiedRatings
            ? "Say again if you missed it, or good if you knew it."
            : "Say again, hard, good, or easy."
    }

    static func isHeadphoneRoute(_ description: String) -> Bool {
        let lower = description.lowercased()
        return lower.contains("headphone") || lower.contains("airpod") || lower.contains("bluetooth")
            || lower.contains("beats") || lower.contains("buds") || lower.contains("headset")
    }

    private func handleCommand(_ command: CommandRecognizer.Command, mode: StudyMode) async {
        switch command {
        case .pause:
            await pause(mode: mode)
        case .resume:
            await resume(mode: mode)
        case .stop:
            await stop(mode: mode)
        case .repeatContent, .repeatQuestion, .repeatAnswer:
            let side: Side = command == .repeatAnswer
                ? .answer
                : (command == .repeatQuestion ? .question : lastSpokenSide)
            await repeatSpoken(side: side, mode: mode)
        case .reveal:
            if state == .awaitingAnswer || state == .answerInProgress {
                guard settings.allowRevealCommand else { return }
                await reveal(mode: mode)
            }
        case .undo:
            await undo(mode: mode)
        case .skip:
            if state == .awaitingAnswer || state == .answerInProgress {
                await skip(mode: mode)
            }
        case .again, .hard, .good, .easy:
            if state == .awaitingRating {
                await rate(ratingFor(command), mode: mode)
            }
            // During awaitingAnswer, rating words are treated as answer content (PRD §13).
        }
    }

    /// Maps commands to ratings, collapsing to the simplified set when enabled.
    private func ratingFor(_ command: CommandRecognizer.Command) -> Rating {
        switch command {
        case .again: return .again
        case .hard: return settings.simplifiedRatings ? .good : .hard
        case .good: return .good
        case .easy: return settings.simplifiedRatings ? .good : .easy
        default: return .good
        }
    }

    // MARK: - Public actions (voice commands and touch controls both land here)

    /// Applies a rating to the current card, persists the review, and advances.
    public func rate(_ rating: Rating, mode: StudyMode) async {
        guard state == .awaitingRating, let card = currentCard, let deck else { return }
        answerTimeoutTask?.cancel()
        engine?.stopListening()
        state = .processingRating

        let scheduler = FSRSScheduler(
            desiredRetention: studyConfig.desiredRetention,
            maximumInterval: studyConfig.maximumIntervalDays,
            enableFuzzing: false
        )
        let previous = card.card.scheduling
        let (memory, intervalSeconds) = scheduler.review(
            card.card.scheduling.memoryState, rating: rating, at: Date()
        )

        // Fuzz applies only to day-level review intervals (PRD §30).
        var finalInterval = intervalSeconds
        if memory.state == .review && intervalSeconds >= 86_400 {
            let fuzzedDays = FSRSScheduler(
                desiredRetention: studyConfig.desiredRetention,
                maximumInterval: studyConfig.maximumIntervalDays,
                enableFuzzing: true
            ).applyFuzz(toIntervalDays: Int(intervalSeconds / 86_400))
            finalInterval = TimeInterval(fuzzedDays) * 86_400
        }

        var newScheduling = SchedulingState(memory: memory)
        if memory.state == .review {
            newScheduling.due = Date().addingTimeInterval(finalInterval)
        }

        let durationMs = Int(Date().timeIntervalSince(cardShownAt ?? Date()) * 1000)
        let log = ReviewLog(
            id: 0, cardID: card.id, rating: rating, reviewedAt: Date(),
            durationMs: durationMs, studyMode: mode,
            previousState: previous, newState: newScheduling
        )

        do {
            try cards.replaceScheduling(newScheduling, cardID: card.id)
            let persisted = try reviews.append(log)
            lastUndoRecord = UndoRecord(
                logID: persisted.id, cardID: card.id, previousScheduling: previous
            )
            try? decks.markStudied(deck.id)
        } catch {
            state = .idle
            statusMessage = "Failed to save review: \(error.localizedDescription)"
            return
        }

        reviewsThisSession += 1
        if mode == .voice { voiceReviews += 1 } else { touchReviews += 1 }
        sessionLog.append(
            SessionEntry(
                timestamp: Date(), cardFront: card.note.front, rating: rating,
                mode: mode, intervalDays: Int(finalInterval / 86_400)
            )
        )
        skipSet.remove(card.id)

        // Feedback: brief confirmation, then straight to the next card (PRD §40).
        if settings.announceNextInterval && memory.state == .review {
            let days = Int(finalInterval / 86_400)
            await speakNotice("\(rating.title). \(Self.speakableInterval(days)).")
        } else if settings.announceRatingConfirmation {
            await speakNotice(rating.title)
        } else {
            await engine?.playConfirmationTone()
        }

        guard settings.autoStartNextCard else {
            // Resuming continues with the next card, not another rating window.
            stateBeforePause = .loadingCard
            state = .paused
            await listenWhilePaused()
            return
        }
        await loadNextCard()
    }

    /// Reveals the answer without requiring a spoken response.
    public func reveal(mode: StudyMode) async {
        guard state == .awaitingAnswer || state == .answerInProgress else { return }
        if mode == .touch { touchInteractions += 1 }
        answerTimeoutTask?.cancel()
        engine?.stopListening()
        state = .answerComplete
        await speakAnswer()
    }

    /// Repeats the question or answer, then resumes the prior listening phase.
    public func repeatSpoken(side: Side, mode: StudyMode) async {
        guard let rendered, let engine else { return }
        if mode == .touch { touchInteractions += 1 }
        let segments = side == .question ? rendered.question : rendered.answer
        let stateBefore = state
        await engine.speak(
            segments,
            voice: voiceConfig.speaking(side == .question ? .question : .answer)
        )
        guard state == stateBefore else { return }  // paused or stopped mid-speech
        switch state {
        case .awaitingAnswer, .answerInProgress:
            await beginAnswerPhase()
        case .awaitingRating:
            await beginRatingPhase()
        case .paused:
            await listenWhilePaused()
        default:
            break
        }
    }

    /// Pauses the session (voice command or touch). Announces the pause and
    /// keeps listening for "resume".
    public func pause(mode: StudyMode) async {
        guard state != .paused, state != .idle, state != .finished else { return }
        if mode == .touch { touchInteractions += 1 }
        pauseForInterruption(announce: false)
        await engine?.speak(
            [.speech(text: "Session paused. Say resume to continue.", locale: "en-US")],
            voice: noticeVoice
        )
        await listenWhilePaused()
    }

    /// Stops audio and freezes the state machine. Interruptions don't announce
    /// (the audio session is gone); `interruptionEnded` re-arms listening.
    private func pauseForInterruption(announce: Bool) {
        guard state != .paused, state != .idle, state != .finished else { return }
        answerTimeoutTask?.cancel()
        engine?.stopListening()
        engine?.stopSpeaking()
        stateBeforePause = state
        state = .paused
        if announce {
            let engine = self.engine
            let voice = noticeVoice
            Task {
                await engine?.speak(
                    [.speech(text: "Session paused. Say resume to continue.", locale: "en-US")],
                    voice: voice
                )
            }
        }
    }

    /// Resumes from pause, returning to a known state (PRD §33).
    public func resume(mode: StudyMode) async {
        guard state == .paused else { return }
        if mode == .touch { touchInteractions += 1 }
        engine?.stopListening()
        let resumeState = stateBeforePause ?? .awaitingRating
        stateBeforePause = nil
        switch resumeState {
        case .awaitingAnswer, .answerInProgress, .answerComplete:
            // Re-read the question so the user regains context (PRD §33).
            lastSpokenSide = .question
            await speakPrompt()
        case .awaitingRating, .speakingAnswer:
            await beginRatingPhase()
        case .speakingPrompt:
            await speakPrompt()
        case .loadingCard, .processingRating:
            await loadNextCard()
        default:
            await beginRatingPhase()
        }
    }

    /// Undoes the most recent rating; the card returns to its pre-review state (PRD §41).
    public func undo(mode: StudyMode) async {
        guard let record = lastUndoRecord else {
            await speakNotice("Nothing to undo.")
            return
        }
        if mode == .touch { touchInteractions += 1 }
        guard let log = try? reviews.remove(id: record.logID) else { return }
        try? cards.replaceScheduling(record.previousScheduling, cardID: record.cardID)
        lastUndoRecord = nil
        reviewsThisSession = max(0, reviewsThisSession - 1)
        if log.studyMode == .voice {
            voiceReviews = max(0, voiceReviews - 1)
        } else {
            touchReviews = max(0, touchReviews - 1)
        }
        if !sessionLog.isEmpty { sessionLog.removeLast() }

        engine?.stopListening()
        await speakNotice("Previous rating undone.")

        // Re-present the restored card from the beginning; the user then
        // proceeds (answer again or rate) when ready.
        if let restored = try? cards.studyCard(id: record.cardID) {
            currentCard = restored
            cardShownAt = Date()
            rendered = renderer.render(
                restored, questionLocale: voiceConfig.questionLocale,
                answerLocale: voiceConfig.answerLocale
            )
            remaining = (try? queue.remaining(forDeck: deck?.id ?? 0, config: studyConfig)) ?? .init()
            await speakPrompt()
        }
    }

    /// Temporarily skips the current card; it returns after other due cards.
    public func skip(mode: StudyMode) async {
        guard state == .awaitingAnswer || state == .answerInProgress, let card = currentCard else { return }
        if mode == .touch { touchInteractions += 1 }
        answerTimeoutTask?.cancel()
        engine?.stopListening()
        skipSet.insert(card.id)
        await loadNextCard()
    }

    // MARK: - Timeout

    private func scheduleAnswerTimeout() {
        answerTimeoutTask?.cancel()
        let timeout = settings.answerTimeoutSeconds
        guard timeout > 0 else { return }
        answerTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            guard self.state == .awaitingAnswer || self.state == .answerInProgress else { return }
            if !self.settings.requireSpokenAnswer {
                // A spoken answer is optional: auto-reveal after the silence window.
                self.hintGivenForCurrentCard = true
                await self.reveal(mode: .voice)
                return
            }
            if !self.hintGivenForCurrentCard {
                self.hintGivenForCurrentCard = true
                if self.voiceAvailable {
                    await self.speakNotice("Say repeat to hear the card again, or reveal to hear the answer.")
                } else {
                    await self.speakNotice("Tap reveal to hear the answer.")
                }
                if self.state == .awaitingAnswer {
                    self.scheduleAnswerTimeout()
                }
            }
        }
    }

    // MARK: - Helpers

    private var effectiveEndpointMs: Int {
        // A deck-level override wins when it deviates from the default;
        // otherwise the global endpoint profile applies.
        if voiceConfig.endpointDelayMs != 700 { return voiceConfig.endpointDelayMs }
        return settings.endpointProfile.silenceMs
    }

    private func speakNotice(_ text: String) async {
        await engine?.speak([.speech(text: text, locale: "en-US")], voice: noticeVoice)
    }

    /// "Four days" / "two weeks" — compact spoken interval (PRD §40).
    static func speakableInterval(_ days: Int) -> String {
        switch days {
        case ..<1: return "less than a day"
        case 1: return "one day"
        case 2...6: return "\(days) days"
        case 7...13: return "one week"
        case 14...29: return "\(max(1, days / 7)) weeks"
        case 30...59: return "one month"
        case 60...364: return "\(max(1, days / 30)) months"
        default: return "\(max(1, days / 365)) years"
        }
    }
}


extension Notification.Name {
    /// Posted when a study session ends (stop, finish, or teardown) so deck
    /// screens refresh their counts.
    static let ankivoiceSessionDidEnd = Notification.Name("ankivoiceSessionDidEnd")
}
