import XCTest
@testable import AnkiVoice

/// End-to-end tests of the review state machine with a deterministic mock engine.
@MainActor
final class StudySessionTests: XCTestCase {

    private var db: SQLiteDatabase!
    private var decks: DeckRepository!
    private var cardsRepo: CardRepository!
    private var reviews: ReviewRepository!
    private var stats: StatsStore!
    private var queue: StudyQueue!
    private var settings: SettingsStore!
    private var controller: StudySessionController!
    private var engine: MockVoiceEngine!

    override func setUp() async throws {
        db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        decks = DeckRepository(db: db)
        cardsRepo = CardRepository(db: db)
        reviews = ReviewRepository(db: db)
        stats = StatsStore(db: db)
        queue = StudyQueue(cards: cardsRepo, reviews: reviews)
        let defaults = UserDefaults(suiteName: "StudySessionTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        controller = StudySessionController(
            decks: decks, cards: cardsRepo, reviews: reviews, queue: queue, settings: settings
        )
        engine = MockVoiceEngine()
    }

    @discardableResult
    private func makeDeck(with pairs: [(String, String)], name: String = "Test") throws -> Deck {
        let deck = try decks.create(fullName: name)
        for (front, back) in pairs {
            _ = try cardsRepo.createNote(fields: [front, back], deckID: deck.id)
        }
        return deck
    }

    /// Waits until `condition` holds (event pump is async).
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 2,
        _ message: String = ""
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition never met \(message)")
    }

    // MARK: - Happy path

    func testFullVoiceLoopHappyPath() async throws {
        let deck = try makeDeck(with: [
            ("Capital of France?", "Paris"),
            ("Capital of Japan?", "Tokyo"),
        ])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer, "session should listen for answer")

        // App spoke the question first.
        XCTAssertTrue(engine.entries().contains { $0.contains("Capital of France") })
        XCTAssertEqual(controller.remaining.newCards, 2)

        // User answers; endpoint detected.
        engine.emitSpeechStarted()
        await waitUntil(controller.state == .answerInProgress)
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        XCTAssertTrue(engine.entries().contains { $0.contains("Paris") })

        // User rates Good by voice.
        engine.emitCommand(.good)
        await waitUntil(controller.reviewsThisSession == 1)
        XCTAssertEqual(controller.voiceReviews, 1)
        XCTAssertEqual(controller.touchReviews, 0)

        // Next card begins automatically.
        await waitUntil(controller.state == .awaitingAnswer)
        XCTAssertTrue(engine.entries().contains { $0.contains("Capital of Japan") })

        // History persisted with voice study mode.
        let today = try stats.today()
        XCTAssertEqual(today.reviews, 1)
        XCTAssertEqual(today.handsFreeReviews, 1)
    }

    func testSecondCardContinuesAndFinishes() async throws {
        let deck = try makeDeck(with: [
            ("2 + 2?", "Four"),
            ("3 + 3?", "Six"),
        ])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        engine.emitCommand(.easy)
        await waitUntil(controller.state == .awaitingAnswer, "second card")

        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        engine.emitCommand(.good)
        // Queue exhausted (new limit reached) → finished.
        await waitUntil(controller.state == .finished)
        XCTAssertEqual(controller.reviewsThisSession, 2)
        XCTAssertTrue(engine.entries().contains { $0.contains("Session complete") })
    }

    // MARK: - Commands

    func testRatingWordsDuringAnswerAreNotRatings() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitCommand(.hard)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.state, .awaitingAnswer, "'hard' during answer must not grade")
        XCTAssertEqual(controller.reviewsThisSession, 0)
    }

    func testRepeatQuestionRepeatsAndResumesListening() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitCommand(.repeatQuestion)
        await waitUntil(engine.entries().filter { $0.contains("speak(\"Q1") }.count >= 2)
        await waitUntil(controller.state == .awaitingAnswer)
    }

    func testRevealSkipsAnswerRequirement() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitCommand(.reveal)
        await waitUntil(controller.state == .awaitingRating)
        XCTAssertTrue(engine.entries().contains { $0.contains("A1") })
    }

    func testPauseAndResume() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitCommand(.pause)
        await waitUntil(controller.state == .paused)
        // Pause announcement spoken.
        XCTAssertTrue(engine.entries().contains { $0.contains("paused") })

        // Commands other than resume/stop are ignored while paused.
        engine.emitCommand(.good)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.reviewsThisSession, 0)

        engine.emitCommand(.resume)
        await waitUntil(controller.state == .awaitingAnswer)
    }

    func testUndoRestoresPreviousScheduling() async throws {
        let deck = try makeDeck(with: [("Q1", "A1"), ("Q2", "A2")])
        let originalCard = try XCTUnwrap(try queue.next(forDeck: deck.id, config: StudyConfig()))

        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        engine.emitCommand(.easy)
        await waitUntil(controller.reviewsThisSession == 1)
        await waitUntil(controller.state == .awaitingAnswer, "moved to second card")

        // Undo.
        engine.emitCommand(.undo)
        await waitUntil(controller.reviewsThisSession == 0)
        XCTAssertTrue(engine.entries().contains { $0.contains("Previous rating undone") })

        // The card's scheduling is back to new.
        let restored = try XCTUnwrap(try cardsRepo.card(id: originalCard.id))
        XCTAssertEqual(restored.scheduling.kind, .new)
        XCTAssertNil(restored.scheduling.lastReview)

        // Review log removed.
        let count = try db.query("SELECT COUNT(*) FROM reviews") { Int($0.int(0)) }.first
        XCTAssertEqual(count, 0)

        // The restored card is re-presented.
        await waitUntil(controller.state == .awaitingAnswer)
        XCTAssertEqual(controller.currentCard?.id, originalCard.id)
    }

    func testSkipMovesCardToBackOfQueue() async throws {
        let deck = try makeDeck(with: [("Q1", "A1"), ("Q2", "A2")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        let first = controller.currentCard?.id

        engine.emitCommand(.skip)
        let skippedTo = controller.currentCard?.id
        await waitUntil(controller.currentCard?.id != first && controller.state == .awaitingAnswer)
        XCTAssertNotEqual(controller.currentCard?.id, skippedTo, "skipped card should be deferred")
    }

    // MARK: - Unrecognized speech in command phases

    /// Mumbling something that isn't a rating must not be met with silence:
    /// the app says what it expects, then listens for a rating again.
    func testUnrecognizedSpeechDuringRatingGetsHintAndListensAgain() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        XCTAssertEqual(engine.listenCount("rating"), 1)

        engine.emitUnrecognized("I think that was pretty close")
        await waitUntil(engine.entries().contains { $0.contains("Say again, hard, good, or easy.") }, "spoken hint")
        await waitUntil(engine.listenCount("rating") == 2, "rating window reopened after the hint")
        XCTAssertEqual(controller.state, .awaitingRating)
        XCTAssertEqual(controller.reviewsThisSession, 0, "nothing was graded")

        // A real rating still goes through afterwards.
        engine.emitCommand(.good)
        await waitUntil(controller.reviewsThisSession == 1)
    }

    func testRatingHintMatchesSimplifiedRatings() async throws {
        settings.simplifiedRatings = true
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)

        engine.emitUnrecognized("hmm")
        await waitUntil(engine.entries().contains { $0.contains("Say again if you missed it, or good if you knew it.") })
        XCTAssertFalse(engine.entries().contains { $0.contains("hard") }, "simplified mode never mentions hard/easy")
    }

    /// While paused only resume/stop apply; anything else earns the same courtesy.
    func testUnrecognizedSpeechWhilePausedGetsResumeHint() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        engine.emitCommand(.pause)
        await waitUntil(controller.state == .paused)
        let pausedWindows = engine.listenCount("paused")

        engine.emitUnrecognized("keep going")
        await waitUntil(engine.entries().contains { $0.contains("Say resume to continue, or stop to end the session.") })
        await waitUntil(engine.listenCount("paused") == pausedWindows + 1, "listening for resume again")
        XCTAssertEqual(controller.state, .paused)
    }

    /// Free-form speech is the answer, never a mistake — no hint there.
    func testUnrecognizedSpeechDuringAnswerIsIgnored() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        let before = engine.entries().count

        engine.emitUnrecognized("the answer is Paris")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.state, .awaitingAnswer)
        XCTAssertFalse(engine.entries().dropFirst(before).contains { $0.hasPrefix("speak(") })
    }

    /// A rating tapped while the hint is being spoken wins; the stale hint
    /// must not reopen a rating window on the next card.
    func testTouchRatingDuringHintIsNotUndoneByStaleHint() async throws {
        let deck = try makeDeck(with: [("Q1", "A1"), ("Q2", "A2")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)

        engine.stallSpeaking = true
        engine.emitUnrecognized("uhh")
        await waitUntil(engine.entries().contains { $0.contains("Say again, hard, good, or easy.") })

        engine.stallSpeaking = false
        await controller.rate(.good, mode: .touch)
        engine.finishSpeaking()  // the hint finishes after the rating landed
        await waitUntil(controller.state == .awaitingAnswer, "second card")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(controller.state, .awaitingAnswer)
        XCTAssertEqual(engine.listenCount("rating"), 1, "hint must not reopen the rating window")
    }

    // MARK: - Ending the session

    /// Tapping End closes the screen; that's confirmation enough. Nothing is spoken.
    func testTappingEndIsSilent() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        await controller.stop()
        XCTAssertEqual(controller.state, .idle)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(engine.entries().contains { $0.contains("ended") })
        XCTAssertTrue(engine.entries().contains("shutdown"))
    }

    /// Saying "stop" hands-free gets a short spoken acknowledgement.
    func testSpokenStopIsAcknowledged() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitCommand(.stop)
        await waitUntil(controller.state == .idle)
        await waitUntil(engine.entries().contains { $0.contains("Session ended.") })
    }

    // MARK: - Interruptions (PRD §34)

    func testInterruptionPausesWithoutGrading() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emit(.interruptionBegan)
        await waitUntil(controller.state == .paused)
        XCTAssertEqual(controller.reviewsThisSession, 0, "never grade on interruption")

        engine.emit(.interruptionEnded)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(controller.state, .paused, "resume requires explicit user action")

        engine.emitCommand(.resume)
        await waitUntil(controller.state == .awaitingAnswer)
    }

    func testHeadphoneRemovalPauses() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emit(.routeChanged(oldDescription: "AirPods Headphone", newDescription: "iPhone Speaker"))
        await waitUntil(controller.state == .paused)
    }

    // MARK: - Touch fallback

    func testTouchControlsDriveSameStateMachine() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        await controller.reveal(mode: .touch)
        await waitUntil(controller.state == .awaitingRating)
        await controller.rate(.good, mode: .touch)
        await waitUntil(controller.reviewsThisSession == 1)

        XCTAssertEqual(controller.touchReviews, 1)
        XCTAssertEqual(controller.voiceReviews, 0)
        XCTAssertFalse(controller.completedWithoutTouch)

        let today = try stats.today()
        XCTAssertEqual(today.handsFreeReviews, 0, "touch reviews are not hands-free")
        XCTAssertEqual(today.reviews, 1)
    }

    // MARK: - Scheduling effects

    func testRatingAdvancesSchedulingState() async throws {
        let deck = try makeDeck(with: [
            ("What is TCP?", "Transmission Control Protocol"),
        ])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        let cardID = controller.currentCard!.id

        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        engine.emitCommand(.good)
        await waitUntil(controller.reviewsThisSession == 1)

        // First Good → learning step 2 (10 minutes), not yet review.
        let card = try XCTUnwrap(try cardsRepo.card(id: cardID))
        XCTAssertEqual(card.scheduling.kind, .learning)
        XCTAssertEqual(card.scheduling.step, 1)
        XCTAssertNotNil(card.scheduling.stability)
        let dueIn = card.scheduling.due.timeIntervalSinceNow
        XCTAssertGreaterThan(dueIn, 8 * 60)
        XCTAssertLessThan(dueIn, 12 * 60)
    }

    func testSimplifiedRatingsCollapseHardEasy() async throws {
        settings.simplifiedRatings = true
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)

        let cardID = controller.currentCard!.id
        engine.emitCommand(.hard)
        await waitUntil(controller.reviewsThisSession == 1)

        let log = try XCTUnwrap(try reviews.mostRecent())
        XCTAssertEqual(log.rating, .good, "hard collapses to good in simplified mode")
        XCTAssertEqual(log.cardID, cardID)
    }

    func testAnnounceIntervalSpeaksCompactInterval() async throws {
        settings.announceNextInterval = true
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)

        // Graduate with easy so the interval is day-level.
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        engine.emitCommand(.easy)
        await waitUntil(controller.reviewsThisSession == 1)
        XCTAssertTrue(
            engine.entries().contains { $0.contains("Easy.") },
            "should announce rating with interval"
        )
    }

    // MARK: - Session metrics

    func testTouchlessMetric() async throws {
        let deck = try makeDeck(with: [("Q1", "A1")])
        await controller.start(deck: deck, engine: engine)
        await waitUntil(controller.state == .awaitingAnswer)
        engine.emitAnswerEnded()
        await waitUntil(controller.state == .awaitingRating)
        engine.emitCommand(.good)
        await waitUntil(controller.state == .finished || controller.reviewsThisSession == 1)
        XCTAssertTrue(controller.completedWithoutTouch)
    }
}

/// A failing speech stack degrades to touch-only mode instead of dead-ending.
final class TouchOnlyFallbackTests: XCTestCase {

    @MainActor
    func testEngineFailureFallsBackToTouchOnly() async throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cardsRepo = CardRepository(db: db)
        let reviews = ReviewRepository(db: db)
        let queue = StudyQueue(cards: cardsRepo, reviews: reviews)
        let defaults = UserDefaults(suiteName: "TouchOnlyFallback-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = StudySessionController(
            decks: decks, cards: cardsRepo, reviews: reviews, queue: queue, settings: settings
        )

        let deck = try decks.create(fullName: "Fallback")
        _ = try cardsRepo.createNote(fields: ["Q1", "A1"], deckID: deck.id)

        final class BrokenEngine: VoiceSessionEngine, @unchecked Sendable {
            let events: AsyncStream<VoiceEvent> = AsyncStream { $0.finish() }
            func prepare(voice: VoiceConfig, commandLocale: String) async throws {
                throw VoiceEngineError.speechUnavailable
            }
            func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async {}
            func playConfirmationTone() async {}
            func startListening(phase: CommandRecognizer.ListeningPhase, endpointMs: Int, recognizer: CommandRecognizer) async throws {}
            func stopListening() {}
            func stopSpeaking() {}
            func shutdown() {}
        }

        await controller.start(deck: deck, engine: BrokenEngine())

        // The session survives: it advanced to the answer phase, with a
        // degraded-mode notice, and touch controls still work end to end.
        let deadline = Date().addingTimeInterval(3)
        while controller.state != .awaitingAnswer && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .awaitingAnswer)
        XCTAssertNotNil(controller.statusMessage)

        await controller.reveal(mode: .touch)
        while controller.state != .awaitingRating && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .awaitingRating)

        await controller.rate(.good, mode: .touch)
        XCTAssertEqual(controller.reviewsThisSession, 1)
        let card = try XCTUnwrap(try cardsRepo.cards(inDeck: deck.id).first)
        XCTAssertEqual(card.scheduling.kind, .learning)
    }
}

/// Answer-phase behaviors of the silence watchdog.
final class AnswerTimeoutTests: XCTestCase {

    @MainActor
    func testOptionalSpokenAnswerAutoRevealsAfterTimeout() async throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cardsRepo = CardRepository(db: db)
        let reviews = ReviewRepository(db: db)
        let queue = StudyQueue(cards: cardsRepo, reviews: reviews)
        let defaults = UserDefaults(suiteName: "AnswerTimeout-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.requireSpokenAnswer = false
        settings.answerTimeoutSeconds = 1
        let controller = StudySessionController(
            decks: decks, cards: cardsRepo, reviews: reviews, queue: queue, settings: settings
        )

        let deck = try decks.create(fullName: "T")
        _ = try cardsRepo.createNote(fields: ["Q", "A"], deckID: deck.id)
        await controller.start(deck: deck, engine: MockVoiceEngine())

        let deadline = Date().addingTimeInterval(5)
        while controller.state != .awaitingAnswer && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .awaitingAnswer)

        // No speech at all — after the silence window the answer auto-reveals.
        while controller.state != .awaitingRating && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.state, .awaitingRating)
    }
}
