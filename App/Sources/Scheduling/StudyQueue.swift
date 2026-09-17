import Foundation

/// Selects the next card to study for a deck tree, respecting daily limits.
///
/// Priority (Anki-like):
/// 1. Due learning/relearning cards (time-due, earliest first)
/// 2. Due review cards (due first)
/// 3. New cards up to the remaining daily new limit
///
/// Daily limits are enforced via review-log counts for the study day (4 AM boundary).
public final class StudyQueue: @unchecked Sendable {
    private let cards: CardRepository
    private let reviews: ReviewRepository

    public init(cards: CardRepository, reviews: ReviewRepository) {
        self.cards = cards
        self.reviews = reviews
    }

    public struct Remaining: Sendable, Equatable {
        public var learning = 0
        public var dueReviews = 0
        public var newCards = 0
        public var total: Int { learning + dueReviews + newCards }
    }

    /// Computes remaining study workload for a deck tree after applying daily limits.
    public func remaining(forDeck deckID: Int64, config: StudyConfig, now: Date = Date()) throws -> Remaining {
        let deckIDs = try cards.descendantDeckIDs(including: deckID)
        let placeholders = deckIDs.map { _ in "?" }.joined(separator: ",")
        let nowSec = now.timeIntervalSince1970
        let binds = deckIDs.map { SQLiteValue.int($0) }

        let learning = try cards.db.query(
            """
            SELECT COUNT(*) FROM cards
            WHERE deck_id IN (\(placeholders)) AND suspended = 0
              AND state IN (1, 3) AND due <= ?
            """,
            binds + [.double(nowSec)]
        ) { Int($0.int(0)) }.first ?? 0

        let dueReviews = try cards.db.query(
            """
            SELECT COUNT(*) FROM cards
            WHERE deck_id IN (\(placeholders)) AND suspended = 0
              AND state = 2 AND due <= ?
            """,
            binds + [.double(nowSec)]
        ) { Int($0.int(0)) }.first ?? 0

        let newAvailable = try cards.db.query(
            """
            SELECT COUNT(*) FROM cards
            WHERE deck_id IN (\(placeholders)) AND suspended = 0 AND state = 0
            """,
            binds
        ) { Int($0.int(0)) }.first ?? 0

        let newToday = try reviews.newCountToday(deckID: deckID, now: now)
        let reviewsToday = try reviews.reviewsToday(deckID: deckID, now: now)
        let newRemaining = max(0, min(config.newPerDay - newToday, newAvailable))
        let reviewRemaining = max(0, config.reviewsPerDay - reviewsToday)

        var result = Remaining()
        result.learning = learning
        result.dueReviews = min(dueReviews, reviewRemaining)
        result.newCards = newRemaining
        return result
    }

    /// Pulls the next card for a study session, or nil when today's queue is exhausted.
    public func next(
        forDeck deckID: Int64, config: StudyConfig, now: Date = Date(),
        exclude: Set<Int64> = []
    ) throws -> StudyCard? {
        let deckIDs = try cards.descendantDeckIDs(including: deckID)
        let placeholders = deckIDs.map { _ in "?" }.joined(separator: ",")
        let nowSec = now.timeIntervalSince1970
        let binds = deckIDs.map { SQLiteValue.int($0) }

        func fetch(_ condition: String, _ extra: [SQLiteValue]) throws -> StudyCard? {
            let sql = "\(CardRepository.studyCardSQL) WHERE \(condition) ORDER BY c.due ASC, c.id ASC LIMIT 32"
            for row in try cards.db.query(sql, binds + extra, CardRepository.rowToStudyCard) {
                if !exclude.contains(row.id) { return row }
            }
            return nil
        }

        // 1. Learning / relearning due now.
        if let card = try fetch(
            "c.deck_id IN (\(placeholders)) AND c.suspended = 0 AND c.state IN (1, 3) AND c.due <= ?",
            [.double(nowSec)]
        ) { return card }

        // 2. Due reviews, subject to the daily review limit.
        let reviewsToday = try reviews.reviewsToday(deckID: deckID, now: now)
        if config.reviewsPerDay - reviewsToday > 0,
           let card = try fetch(
            "c.deck_id IN (\(placeholders)) AND c.suspended = 0 AND c.state = 2 AND c.due <= ?",
            [.double(nowSec)]
           ) { return card }

        // 3. New cards, subject to the daily new limit.
        let newToday = try reviews.newCountToday(deckID: deckID, now: now)
        if config.newPerDay - newToday > 0,
           let card = try fetch(
            "c.deck_id IN (\(placeholders)) AND c.suspended = 0 AND c.state = 0",
            []
           ) { return card }

        return nil
    }
}
