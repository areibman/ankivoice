import Foundation

/// Selects the next card to study for a deck tree.
///
/// Order matches Anki's defaults (deck options → Display Order):
/// - intraday learning that is due, soonest first
/// - reviews sorted by due day, shuffled within a day ("Due date, then random")
/// - new cards in card-type order, then subdeck, then the position Anki stored
///   ("Card type, then order gathered" with gather order "Deck")
/// - new cards mixed evenly into the review queue ("Mix with reviews")
///
/// `more` ignores the daily caps and continues into future reviews.
/// Filtered decks serve their gathered order.
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

    /// What a session is allowed to pull.
    public enum Gather: Sendable, Equatable {
        /// Today's queue, with daily limits.
        case scheduled
        /// No daily limits. Due cards, then future reviews soonest-first, then new cards.
        case more
        /// Cards already moved into a filtered deck, in gather order. Due dates ignored.
        case filtered(reschedule: Bool)

        public var reschedules: Bool {
            switch self {
            case .filtered(let reschedule): return reschedule
            case .scheduled, .more: return true
            }
        }
    }

    public func remaining(
        forDeck deckID: Int64, config: StudyConfig, gather: Gather = .scheduled, now: Date = Date()
    ) throws -> Remaining {
        try cards.expireSiblingBuries(now: now)
        let scope = try scope(for: deckID)
        if case .filtered = gather {
            var result = Remaining()
            result.dueReviews = try count(scope.ids, "\(active(now))")
            return result
        }
        if scope.filtered {
            var result = Remaining()
            result.dueReviews = try count(scope.ids, "\(active(now))")
            return result
        }

        let nowSec = now.timeIntervalSince1970
        let learning = try count(scope.ids, "\(active(now)) AND c.state IN (1, 3) AND c.due <= ?", extra: [.double(nowSec)])
        let dueReviews = try count(scope.ids, "\(active(now)) AND c.state = 2 AND c.due <= ?", extra: [.double(nowSec)])
        let newAvailable = try count(scope.ids, "\(active(now)) AND c.state = 0")

        if case .more = gather {
            let future = try count(scope.ids, "\(active(now)) AND c.state = 2 AND c.due > ?", extra: [.double(nowSec)])
            var result = Remaining()
            result.learning = learning
            result.dueReviews = dueReviews + future
            result.newCards = newAvailable
            return result
        }

        let newToday = try reviews.newCountToday(deckID: deckID, now: now)
        let reviewsToday = try reviews.reviewsToday(deckID: deckID, now: now)
        var result = Remaining()
        result.learning = learning
        result.dueReviews = min(dueReviews, max(0, config.reviewsPerDay - reviewsToday))
        result.newCards = max(0, min(config.newPerDay - newToday, newAvailable))
        return result
    }

    public func next(
        forDeck deckID: Int64, config: StudyConfig, now: Date = Date(),
        exclude: Set<Int64> = [], gather: Gather = .scheduled
    ) throws -> StudyCard? {
        try cards.expireSiblingBuries(now: now)
        let scope = try scope(for: deckID)
        let ids = scope.ids
        if ids.isEmpty { return nil }
        let nowSec = now.timeIntervalSince1970

        if scope.filtered || isFiltered(gather) {
            return try fetch(
                ids: ids,
                condition: "\(active(now)) AND c.deck_id IN (\(placeholders(ids)))",
                extra: [],
                order: "COALESCE(c.filter_position, 1000000) ASC, c.due ASC, c.id ASC",
                exclude: exclude
            )
        }

        if let card = try fetch(
            ids: ids,
            condition: "\(active(now)) AND c.deck_id IN (\(placeholders(ids))) AND c.state IN (1, 3) AND c.due <= ?",
            extra: [.double(nowSec)],
            order: "c.due ASC, c.id ASC",
            exclude: exclude
        ) { return card }

        let reviewsOpen: Bool
        if case .scheduled = gather {
            reviewsOpen = config.reviewsPerDay - (try reviews.reviewsToday(deckID: deckID, now: now)) > 0
        } else {
            reviewsOpen = true
        }
        let reviewBudget: Int
        let newBudget: Int
        if case .scheduled = gather {
            reviewBudget = reviewsOpen
                ? max(0, config.reviewsPerDay - (try reviews.reviewsToday(deckID: deckID, now: now)))
                : 0
            let newToday = try reviews.newCountToday(deckID: deckID, now: now)
            newBudget = max(0, config.newPerDay - newToday)
        } else {
            reviewBudget = reviewsOpen ? .max : 0
            newBudget = .max
        }

        var reviewIDs: [Int64] = []
        if reviewBudget > 0 {
            let dueOnly = if case .scheduled = gather { "AND c.due <= ?" } else { "" }
            let extra: [SQLiteValue] = if case .scheduled = gather { [.double(nowSec)] } else { [] }
            let reviews = try candidateIDs(
                ids: ids,
                condition: "\(active(now)) AND c.deck_id IN (\(placeholders(ids))) AND c.state = 2 \(dueOnly)",
                extra: extra
            )
            reviewIDs = Array(
                shuffleWithinDueDay(reviews, deckID: deckID, now: now)
                    .filter { !exclude.contains($0) }
                    .prefix(reviewBudget)
            )
        }

        var newIDs: [Int64] = []
        if newBudget > 0 {
            let fresh = try newCardRows(
                ids: ids,
                condition: "\(active(now)) AND c.deck_id IN (\(placeholders(ids))) AND c.state = 0"
            )
            newIDs = Array(
                orderedNewCards(fresh)
                    .filter { !exclude.contains($0) }
                    .prefix(newBudget)
            )
        }

        return try firstCard(in: Self.intersperse(reviewIDs, newIDs), exclude: [])
    }

    /// Anki's `Intersperser`: spread the shorter queue evenly through the longer one.
    static func intersperse<T>(_ reviews: [T], _ newCards: [T]) -> [T] {
        if reviews.isEmpty { return newCards }
        if newCards.isEmpty { return reviews }
        let ratio = Float(reviews.count + 1) / Float(newCards.count + 1)
        var result: [T] = []
        result.reserveCapacity(reviews.count + newCards.count)
        var reviewIndex = 0
        var newIndex = 0
        while reviewIndex < reviews.count || newIndex < newCards.count {
            if reviewIndex < reviews.count, newIndex < newCards.count {
                let relative = Float(newIndex + 1) * ratio
                if relative < Float(reviewIndex + 1) {
                    result.append(newCards[newIndex])
                    newIndex += 1
                } else {
                    result.append(reviews[reviewIndex])
                    reviewIndex += 1
                }
            } else if reviewIndex < reviews.count {
                result.append(reviews[reviewIndex])
                reviewIndex += 1
            } else {
                result.append(newCards[newIndex])
                newIndex += 1
            }
        }
        return result
    }

    // MARK: - SQL

    private struct Scope {
        var ids: [Int64]
        var filtered: Bool
    }

    private func scope(for deckID: Int64) throws -> Scope {
        let kind = try cards.db.query(
            "SELECT kind FROM decks WHERE id = ?", [.int(deckID)]
        ) { $0.int32(0) }.first ?? 0
        if kind == DeckKind.filtered.rawValue {
            return Scope(ids: [deckID], filtered: true)
        }
        let all = try cards.descendantDeckIDs(including: deckID)
        let filtered = Set(try cards.db.query(
            "SELECT id FROM decks WHERE kind = ?", [.int(Int64(DeckKind.filtered.rawValue))]
        ) { $0.int(0) })
        return Scope(ids: all.filter { !filtered.contains($0) }, filtered: false)
    }

    private func isFiltered(_ gather: Gather) -> Bool {
        if case .filtered = gather { return true }
        return false
    }

    private func active(_ now: Date) -> String {
        "(c.suspended = 0 AND (c.buried = 0 OR (c.buried = 1 AND c.buried_until IS NOT NULL AND c.buried_until <= \(now.timeIntervalSince1970))))"
    }

    private func placeholders(_ ids: [Int64]) -> String {
        ids.map { _ in "?" }.joined(separator: ",")
    }

    private func count(_ ids: [Int64], _ condition: String, extra: [SQLiteValue] = []) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let sql = "SELECT COUNT(*) FROM cards c WHERE c.deck_id IN (\(placeholders(ids))) AND \(condition)"
        return try cards.db.query(sql, ids.map { .int($0) } + extra) { Int($0.int(0)) }.first ?? 0
    }

    private func candidateIDs(
        ids: [Int64], condition: String, extra: [SQLiteValue]
    ) throws -> [(id: Int64, due: Double)] {
        let sql = "SELECT c.id, c.due FROM cards c WHERE \(condition) ORDER BY c.due ASC, c.id ASC"
        return try cards.db.query(sql, ids.map { SQLiteValue.int($0) } + extra) {
            (id: $0.int(0), due: $0.double(1))
        }
    }

    private struct NewCardRow {
        var id: Int64
        var due: Double
        var ordinal: Int
        var deck: String
    }

    /// New cards in Anki's default display order: card type, then the order
    /// they were gathered (subdeck name, then the position stored in `due`).
    private func newCardRows(ids: [Int64], condition: String) throws -> [NewCardRow] {
        let sql = """
        SELECT c.id, c.due, c.template_ordinal, d.full_name
        FROM cards c JOIN decks d ON d.id = c.deck_id
        WHERE \(condition)
        """
        return try cards.db.query(sql, ids.map { SQLiteValue.int($0) }) {
            NewCardRow(id: $0.int(0), due: $0.double(1), ordinal: $0.int32(2), deck: $0.string(3))
        }
    }

    private func orderedNewCards(_ rows: [NewCardRow]) -> [Int64] {
        rows.sorted { a, b in
            if a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
            let deck = a.deck.localizedCaseInsensitiveCompare(b.deck)
            if deck != .orderedSame { return deck == .orderedAscending }
            if a.due != b.due { return a.due < b.due }
            return a.id < b.id
        }.map(\.id)
    }

    private func firstCard(in ids: [Int64], exclude: Set<Int64>) throws -> StudyCard? {
        for id in ids where !exclude.contains(id) {
            if let card = try cards.studyCard(id: id) { return card }
        }
        return nil
    }

    /// Anki-style: cards due on the same study day are shuffled, days stay in order.
    private func shuffleWithinDueDay(
        _ rows: [(id: Int64, due: Double)], deckID: Int64, now: Date
    ) -> [Int64] {
        var result: [Int64] = []
        var bucket: [Int64] = []
        var bucketDay: TimeInterval?
        func flush() {
            guard let day = bucketDay else { return }
            result.append(contentsOf: seededShuffle(bucket, seed: shuffleSeed(deckID: deckID, now: now, salt: UInt64(day))))
            bucket = []
            bucketDay = nil
        }
        for row in rows {
            let day = ReviewRepository.startOfStudyDay(Date(timeIntervalSince1970: row.due)).timeIntervalSince1970
            if bucketDay != day {
                flush()
                bucketDay = day
            }
            bucket.append(row.id)
        }
        flush()
        return result
    }

    private func shuffleSeed(deckID: Int64, now: Date, salt: UInt64) -> UInt64 {
        let day = UInt64(bitPattern: Int64(ReviewRepository.startOfStudyDay(now).timeIntervalSince1970))
        return day &* 0x9E3779B97F4A7C15 &+ UInt64(bitPattern: deckID) &+ salt
    }

    private func seededShuffle(_ ids: [Int64], seed: UInt64) -> [Int64] {
        var items = ids
        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        guard items.count > 1 else { return items }
        for index in stride(from: items.count - 1, through: 1, by: -1) {
            let swap = Int(next() % UInt64(index + 1))
            items.swapAt(index, swap)
        }
        return items
    }

    private func fetch(
        ids: [Int64], condition: String, extra: [SQLiteValue], order: String, exclude: Set<Int64>
    ) throws -> StudyCard? {
        let sql = "\(CardRepository.studyCardSQL) WHERE \(condition) ORDER BY \(order) LIMIT 64"
        for row in try cards.db.query(sql, ids.map { SQLiteValue.int($0) } + extra, CardRepository.rowToStudyCard) {
            if !exclude.contains(row.id) { return row }
        }
        return nil
    }
}
