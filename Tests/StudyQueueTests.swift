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

        let first = try queue.next(forDeck: deck.id, config: StudyConfig())
        XCTAssertEqual(first?.note.front, "A")
        let second = try queue.next(forDeck: deck.id, config: StudyConfig(), exclude: [first!.id])
        XCTAssertEqual(second?.note.front, "B")
    }

    func testDailyNewLimitEnforced() throws {
        let deck = try decks.create(fullName: "D")
        _ = try cards.createNote(fields: ["A", "a"], deckID: deck.id)
        _ = try cards.createNote(fields: ["B", "b"], deckID: deck.id)

        var config = StudyConfig()
        config.newPerDay = 1

        // Serve one card and review it.
        let first = try queue.next(forDeck: deck.id, config: config)
        XCTAssertEqual(first?.note.front, "A")
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let (memory, _) = scheduler.review(first!.card.scheduling.memoryState, rating: .good, at: Date())
        let newState = SchedulingState(memory: memory)
        try cards.replaceScheduling(newState, cardID: first!.id)
        _ = try reviews.append(
            ReviewLog(id: 0, cardID: first!.id, rating: .good, reviewedAt: Date(),
                      durationMs: 1000, studyMode: .voice,
                      previousState: first!.card.scheduling, newState: newState)
        )

        // The new limit is exhausted for today.
        let remaining = try queue.remaining(forDeck: deck.id, config: config)
        XCTAssertEqual(remaining.newCards, 0)
        XCTAssertNil(try queue.next(forDeck: deck.id, config: config, exclude: [first!.id]))
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
