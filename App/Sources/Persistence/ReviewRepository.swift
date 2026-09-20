import Foundation

/// Stores review logs and implements undo by restoring the recorded previous state.
public final class ReviewRepository: @unchecked Sendable {
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    static func rowToReview(_ r: Row) -> ReviewLog {
        ReviewLog(
            id: r.int(0),
            cardID: r.int(1),
            rating: Rating(rawValue: r.int32(2)) ?? .good,
            reviewedAt: r.date(3),
            durationMs: r.int32(4),
            studyMode: StudyMode(rawValue: r.int32(5)) ?? .voice,
            previousState: decodeJSON(SchedulingState.self, r.string(6)) ?? SchedulingState(),
            newState: decodeJSON(SchedulingState.self, r.string(7)) ?? SchedulingState()
        )
    }

    static let select = "SELECT id, card_id, rating, reviewed_at, duration_ms, study_mode, previous_state, new_state FROM reviews"

    @discardableResult
    public func append(_ log: ReviewLog) throws -> ReviewLog {
        let id = try db.run(
            """
            INSERT INTO reviews (card_id, rating, reviewed_at, duration_ms, study_mode, previous_state, new_state)
            VALUES (?,?,?,?,?,?,?)
            """,
            [
                .int(log.cardID), .int(Int64(log.rating.rawValue)), .date(log.reviewedAt),
                .int(Int64(log.durationMs)), .int(Int64(log.studyMode.rawValue)),
                .json(log.previousState), .json(log.newState),
            ]
        )
        return ReviewLog(
            id: id, cardID: log.cardID, rating: log.rating, reviewedAt: log.reviewedAt,
            durationMs: log.durationMs, studyMode: log.studyMode,
            previousState: log.previousState, newState: log.newState
        )
    }

    public func history(forCard cardID: Int64, limit: Int = 100) throws -> [ReviewLog] {
        try db.query(
            "\(Self.select) WHERE card_id = ? ORDER BY reviewed_at DESC LIMIT \(limit)",
            [.int(cardID)]
        ) { Self.rowToReview($0) }
    }

    /// Review history for cards in the given decks, oldest first — used by Anki export.
    public func history(inDeckIDs ids: [Int64]) throws -> [ReviewLog] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try db.query(
            """
            SELECT r.id, r.card_id, r.rating, r.reviewed_at, r.duration_ms, r.study_mode,
                   r.previous_state, r.new_state
            FROM reviews r JOIN cards c ON c.id = r.card_id
            WHERE c.deck_id IN (\(placeholders))
            ORDER BY r.reviewed_at ASC
            """,
            ids.map { .int($0) }
        ) { Self.rowToReview($0) }
    }

    public func allChronological() throws -> [ReviewLog] {
        try db.query("\(Self.select) ORDER BY reviewed_at ASC") { Self.rowToReview($0) }
    }

    /// Most recent review log in the whole store (for session undo).
    public func mostRecent() throws -> ReviewLog? {
        try db.query("\(Self.select) ORDER BY id DESC LIMIT 1") { Self.rowToReview($0) }.first
    }

    /// Removes a review log, returning it (caller restores the previous scheduling state).
    @discardableResult
    public func remove(id: Int64) throws -> ReviewLog? {
        guard let log = try db.query("\(Self.select) WHERE id = ?", [.int(id)], Self.rowToReview).first else {
            return nil
        }
        try db.run("DELETE FROM reviews WHERE id = ?", [.int(id)])
        return log
    }

    // MARK: - Today counts

    /// Start of "today" — 4 AM local, matching Anki's rolling day boundary.
    public static func startOfStudyDay(_ date: Date = Date(), calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = 4
        comps.minute = 0
        comps.second = 0
        let candidate = calendar.date(from: comps) ?? date
        // Before 4 AM belongs to the previous study day.
        return candidate > date ? calendar.date(byAdding: .day, value: -1, to: candidate) ?? date : candidate
    }

    public func reviewCountToday(deckID: Int64? = nil, now: Date = Date()) throws -> Int {
        let start = Self.startOfStudyDay(now).timeIntervalSince1970
        if let deckID {
            let ids = try CardRepository(db: db).descendantDeckIDs(including: deckID)
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try db.query(
                """
                SELECT COUNT(*) FROM reviews r JOIN cards c ON c.id = r.card_id
                WHERE r.reviewed_at >= ? AND c.deck_id IN (\(placeholders))
                """,
                [.double(start)] + ids.map { .int($0) }
            ) { Int($0.int(0)) }.first ?? 0
        }
        return try db.query(
            "SELECT COUNT(*) FROM reviews WHERE reviewed_at >= ?", [.double(start)]
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// New cards introduced today (first-ever reviews) for a deck tree.
    public func newCountToday(deckID: Int64, now: Date = Date()) throws -> Int {
        let start = Self.startOfStudyDay(now).timeIntervalSince1970
        let ids = try CardRepository(db: db).descendantDeckIDs(including: deckID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try db.query(
            """
            SELECT COUNT(*) FROM (
                SELECT r.card_id, MIN(r.reviewed_at) AS first_at
                FROM reviews r JOIN cards c ON c.id = r.card_id
                WHERE c.deck_id IN (\(placeholders))
                GROUP BY r.card_id
            ) WHERE first_at >= ?
            """,
            ids.map { .int($0) } + [.double(start)]
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// Reviews performed today on cards that were already in the review state
    /// (used to enforce the daily review limit; matches Anki's semantics closely enough).
    public func reviewsToday(deckID: Int64, now: Date = Date()) throws -> Int {
        let start = Self.startOfStudyDay(now).timeIntervalSince1970
        let ids = try CardRepository(db: db).descendantDeckIDs(including: deckID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try db.query(
            """
            SELECT COUNT(*) FROM reviews r JOIN cards c ON c.id = r.card_id
            WHERE r.reviewed_at >= ? AND c.deck_id IN (\(placeholders))
              AND json_extract(r.previous_state, '$.kind') = 2
            """,
            [.double(start)] + ids.map { .int($0) }
        ) { Int($0.int(0)) }.first ?? 0
    }
}
