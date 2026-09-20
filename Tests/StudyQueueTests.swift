import XCTest
@testable import AnkiVoice

final class StudyQueueTests: XCTestCase {
    private var db: SQLiteDatabase!
    private var decks: DeckRepository!
    private var cards: CardRepository!
    private var reviews: ReviewRepository!
    private var queue: StudyQueue!

    override func setUp() {
        db = try? SQLiteDatabase.inMemory()
        try? Schema.migrate(db: db)
        decks = DeckRepository(db: db)
        cards = CardRepository(db: db)
        reviews = ReviewRepository(db: db)
        queue = StudyQueue(cards: cards, reviews: reviews)
    }

    func testEmptyQueueReturnsNil() throws {
        let deck = try decks.create(fullName: "Empty")
        XCTAssertNil(try queue.next(forDeck: deck.id, config: StudyConfig()))
        let remaining = try queue.remaining(forDeck: deck.id, config: StudyConfig())
        XCTAssertEqual(remaining.total, 0)
    }

    func testNewCardsCountedAndServedInOrder() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)
        _ = try cards.createNote(fields: ["B", "b"], deckID: deck.id)

        let remaining = try queue.remaining(forDeck: deck.id, config: StudyConfig())
        XCTAssertEqual(remaining.newCards, 2)

        // Anki's default: position order, not a shuffle. A was added first.
        let first = try queue.next(forDeck: deck.id, config: StudyConfig())
        XCTAssertEqual(first?.note.front, "A")
        let second = try queue.next(forDeck: deck.id, config: StudyConfig(), exclude: [first!.id])
        XCTAssertEqual(second?.note.front, "B")
    }

    /// Anki stores a position in the new card's due field. Lower positions
    /// come first even when the card was imported later.
    func testNewCardsFollowAnkiPosition() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["later", "x"], deckID: deck.id)
        _ = try cards.createNote(fields: ["sooner", "y"], deckID: deck.id)
        let stored = try cards.cards(inDeck: deck.id)
        let later = try XCTUnwrap(stored.first { $0.noteID != 0 })
        // The two notes share the deck; identify by front via study cards.
        let all = try cards.studyCards(inDeckIDs: [deck.id])
        let laterCard = try XCTUnwrap(all.first { $0.note.front == "later" })
        let soonerCard = try XCTUnwrap(all.first { $0.note.front == "sooner" })
        var laterState = laterCard.card.scheduling
        laterState.due = Date(timeIntervalSince1970: 20)
        var soonerState = soonerCard.card.scheduling
        soonerState.due = Date(timeIntervalSince1970: 5)
        try cards.replaceScheduling(laterState, cardID: laterCard.id)
        try cards.replaceScheduling(soonerState, cardID: soonerCard.id)
        _ = later
        XCTAssertEqual(try queue.next(forDeck: deck.id, config: StudyConfig())?.note.front, "sooner")
    }

    func testNewAndReviewsAreMixedTheWayAnkiDoes() {
        XCTAssertEqual(StudyQueue.intersperse([1, 2, 3], [11, 22, 33]), [1, 11, 2, 22, 3, 33])
        XCTAssertEqual(StudyQueue.intersperse([1, 2, 3], [11, 22]), [1, 11, 2, 22, 3])
        XCTAssertEqual(
            StudyQueue.intersperse([1, 2, 3], [11, 22, 33, 44, 55, 66]),
            [11, 1, 22, 33, 2, 44, 55, 3, 66]
        )
    }

    func testDailyNewLimitEnforced() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)
        _ = try cards.createNote(fields: ["B", "b"], deckID: deck.id)

        var config = StudyConfig()
        config.newPerDay = 1

        let first = try XCTUnwrap(try queue.next(forDeck: deck.id, config: config))
        XCTAssertEqual(first.note.front, "A")
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let (memory, _) = scheduler.review(first.card.scheduling.memoryState, rating: .good, at: Date())
        let newState = SchedulingState(memory: memory)
        try cards.replaceScheduling(newState, cardID: first.id)
        _ = try reviews.append(
            ReviewLog(id: 0, cardID: first.id, rating: .good, reviewedAt: Date(),
                      durationMs: 1000, studyMode: .voice,
                      previousState: first.card.scheduling, newState: newState)
        )

        // The new limit is exhausted for today.
        let remaining = try queue.remaining(forDeck: deck.id, config: config)
        XCTAssertEqual(remaining.newCards, 0)
        XCTAssertNil(try queue.next(forDeck: deck.id, config: config, exclude: [first.id]))
    }

    func testDueReviewCardsServedBeforeNew() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)

        // Make A a review card due now.
        let scheduler = FSRSScheduler(enableFuzzing: false)
        var memory: FSRSMemoryState
        let (m1, _) = scheduler.review(FSRSMemoryState(), rating: .easy, at: Date().addingTimeInterval(-86_400 * 10))
        memory = m1
        // fast-forward: re-review at due in the past
        let (m2, _) = scheduler.review(memory, rating: .good, at: Date().addingTimeInterval(-86_400 * 5))
        memory = m2
        var state = SchedulingState(memory: memory)
        state.due = Date().addingTimeInterval(-60)
        try cards.replaceScheduling(state, cardID: try XCTUnwrap(try cards.cards(inDeck: deck.id).first).id)

        _ = try cards.createNote(fields: ["B", "b"], deckID: deck.id)

        let next = try queue.next(forDeck: deck.id, config: StudyConfig())
        XCTAssertEqual(next?.note.front, "A", "due review beats new card")
    }

    func testLearningCardDueNowServedFirst() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)

        var state = SchedulingState()
        state.kind = .learning
        state.step = 1
        state.stability = 2.0
        state.difficulty = 5.0
        state.due = Date().addingTimeInterval(-30)
        try cards.replaceScheduling(state, cardID: try XCTUnwrap(try cards.cards(inDeck: deck.id).first).id)

        let next = try queue.next(forDeck: deck.id, config: StudyConfig())
        XCTAssertEqual(next?.card.scheduling.kind, .learning)
    }

    func testSuspendedCardsExcluded() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)
        try cards.setSuspended(true, cardID: try XCTUnwrap(try cards.cards(inDeck: deck.id).first).id)

        XCTAssertNil(try queue.next(forDeck: deck.id, config: StudyConfig()))
    }

    func testStudyMoreIgnoresTheDailyCapAndFutureReviews() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)
        _ = try cards.createNote(fields: ["B", "b"], deckID: deck.id)
        var config = StudyConfig()
        config.newPerDay = 0
        XCTAssertNil(try queue.next(forDeck: deck.id, config: config, gather: .scheduled))
        let more = try queue.next(forDeck: deck.id, config: config, gather: .more)
        XCTAssertEqual(more?.note.front, "A")

        let future = SchedulingState(
            kind: .review, stability: 10, difficulty: 5,
            due: Date().addingTimeInterval(86_400 * 3), lapses: 0, reps: 2
        )
        let id = try XCTUnwrap(try cards.cards(inDeck: deck.id).first).id
        try cards.replaceScheduling(future, cardID: id)
        let ahead = try queue.next(forDeck: deck.id, config: StudyConfig(reviewsPerDay: 0), gather: .more)
        XCTAssertEqual(ahead?.id, id)
    }

    func testNewSiblingIsBuriedUntilTomorrow() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["front", "back"], deckID: deck.id, noteTypeID: 2)
        let siblings = try cards.cards(inDeck: deck.id)
        XCTAssertEqual(siblings.count, 2)
        try cards.burySiblings(of: siblings[0], config: StudyConfig())
        let left = try queue.next(forDeck: deck.id, config: StudyConfig(), exclude: [siblings[0].id])
        XCTAssertNil(left, "the reverse card should be buried")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        let later = try queue.next(forDeck: deck.id, config: StudyConfig(), now: tomorrow, exclude: [siblings[0].id])
        XCTAssertNotNil(later)
    }

    func testChildDecksIncluded() throws {
        _ = try decks.create(fullName: "Parent::Child")
        let parent = try XCTUnwrap(try decks.deck(named: "Parent"))
        _ = try cards.createNote(fields: ["A", "a"], deckID: try XCTUnwrap(try decks.deck(named: "Parent::Child")).id)

        let next = try queue.next(forDeck: parent.id, config: StudyConfig())
        XCTAssertEqual(next?.note.front, "A")
    }

    func testStudyDayBoundaryIs4AM() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let at3am = formatter.date(from: "2026-01-15 03:00")!
        let at5am = formatter.date(from: "2026-01-15 05:00")!

        let start3 = ReviewRepository.startOfStudyDay(at3am, calendar: calendar)
        let start5 = ReviewRepository.startOfStudyDay(at5am, calendar: calendar)
        // 3 AM belongs to the previous study day (started yesterday 4 AM).
        XCTAssertEqual(formatter.string(from: start3), "2026-01-14 04:00")
        XCTAssertEqual(formatter.string(from: start5), "2026-01-15 04:00")
    }
}
