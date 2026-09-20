import XCTest
@testable import AnkiVoice

final class SchedulingExtraTests: XCTestCase {
    func testLoadBalancerStaysInsideTheFuzzWindow() throws {
        let bounds = FSRSLoadBalancer.fuzzBounds(intervalDays: 20, minimum: 1, maximum: 36_500)
        let picked = FSRSLoadBalancer.select(
            intervalDays: 20,
            maximumDays: 36_500,
            dueCounts: Array(repeating: 8, count: 120),
            easyDays: [1, 1, 1, 1, 1, 1, 1],
            siblingDayOffsets: [],
            seed: 42
        )
        let day = try XCTUnwrap(picked)
        XCTAssertGreaterThanOrEqual(day, bounds.lower)
        XCTAssertLessThanOrEqual(day, bounds.upper)
    }

    func testLoadBalancerPrefersAnEmptyDay() {
        let bounds = FSRSLoadBalancer.fuzzBounds(intervalDays: 20, minimum: 1, maximum: 36_500)
        var counts = Array(repeating: 40, count: 120)
        let empty = bounds.lower
        counts[empty] = 0
        var hits = 0
        for seed in UInt64(1)..<40 {
            let picked = FSRSLoadBalancer.select(
                intervalDays: 20, maximumDays: 36_500, dueCounts: counts,
                easyDays: [1, 1, 1, 1, 1, 1, 1], siblingDayOffsets: [], seed: seed
            )
            if picked == empty { hits += 1 }
        }
        XCTAssertGreaterThan(hits, 30)
    }

    func testBrowserQueryUnderstandsDeckTagAndDue() throws {
        let deck = Deck(id: 1, name: "Words", fullName: "French::Words", parentID: nil, createdAt: Date(), modifiedAt: Date())
        let note = Note(id: 9, noteTypeID: 1, fields: ["chat", "cat"], tags: ["animal"], guid: "g", createdAt: Date(), modifiedAt: Date())
        let card = Card(
            id: 3, noteID: 9, deckID: 1, templateOrdinal: 0,
            scheduling: SchedulingState(kind: .review, stability: 30, difficulty: 5, due: Date().addingTimeInterval(-60))
        )
        let study = StudyCard(card: card, note: note, noteType: .basic, deck: deck)
        XCTAssertEqual(BrowserQuery.match([study], query: "deck:french tag:animal").count, 1)
        XCTAssertEqual(BrowserQuery.match([study], query: "deck:french -tag:animal").count, 0)
        XCTAssertEqual(BrowserQuery.match([study], query: "is:due prop:s>21").count, 1)
        XCTAssertEqual(BrowserQuery.match([study], query: "is:new or is:review").count, 1)
    }

    func testFilteredDeckReturnsCardsHome() throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cards = CardRepository(db: db)
        let reviews = ReviewRepository(db: db)
        let home = try decks.create(fullName: "Home")
        _ = try cards.createNote(fields: ["one", "1"], tags: ["keep"], deckID: home.id)
        _ = try cards.createNote(fields: ["two", "2"], tags: ["skip"], deckID: home.id)
        let filtered = try FilteredDeckBuilder(decks: decks, cards: cards, reviews: reviews)
            .rebuild(named: "Custom Study Session", query: "tag:keep", limit: 10, order: .due, reschedule: true)
        XCTAssertEqual(filtered.kind, .filtered)
        XCTAssertEqual(try cards.cards(inDeck: filtered.id).count, 1)
        XCTAssertEqual(try cards.cards(inDeck: home.id).count, 1)
        try decks.delete(filtered.id)
        XCTAssertEqual(try cards.cards(inDeck: home.id).count, 2)
        XCTAssertNil(try decks.deck(named: "Custom Study Session"))
    }

    func testOptimizerClipsDefaultParameters() {
        let clipped = FSRSOptimizer.clip(FSRSScheduler.defaultParameters, relearningSteps: 1, shortTerm: true)
        XCTAssertEqual(clipped.count, 21)
        XCTAssertTrue(clipped.allSatisfy(\.isFinite))
        XCTAssertEqual(clipped, FSRSOptimizer.clip(clipped, relearningSteps: 1, shortTerm: true))
    }
}
