import Foundation

/// Aggregates progress and statistics from review logs (PRD §31).
public final class StatsStore: @unchecked Sendable {
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    // MARK: Today

    public struct TodayStats: Sendable, Equatable {
        public var reviews = 0
        public var newCards = 0
        public var reviewCards = 0
        public var studySeconds = 0
        public var again = 0
        public var hard = 0
        public var good = 0
        public var easy = 0
        public var handsFreeReviews = 0
        public var handsFreeSeconds = 0
    }

    public func today(deckID: Int64? = nil, now: Date = Date()) throws -> TodayStats {
        var stats = TodayStats()
        let start = ReviewRepository.startOfStudyDay(now).timeIntervalSince1970

        var whereClause = "r.reviewed_at >= ?"
        var binds: [SQLiteValue] = [.double(start)]
        if let deckID {
            let ids = try CardRepository(db: db).descendantDeckIDs(including: deckID)
            whereClause += " AND c.deck_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            binds.append(contentsOf: ids.map { .int($0) })
        }

        let rows = try db.query(
            """
            SELECT r.rating, r.duration_ms, r.study_mode,
                   json_extract(r.previous_state, '$.kind') AS prev_kind
            FROM reviews r JOIN cards c ON c.id = r.card_id
            WHERE \(whereClause)
            """,
            binds
        ) { (rating: $0.int32(0), durationMs: $0.int32(1), mode: $0.int32(2), prevKind: $0.int32(3)) }

        stats.reviews = rows.count
        for row in rows {
            switch row.rating {
            case Rating.again.rawValue: stats.again += 1
            case Rating.hard.rawValue: stats.hard += 1
            case Rating.good.rawValue: stats.good += 1
            case Rating.easy.rawValue: stats.easy += 1
            default: break
            }
            stats.studySeconds += row.durationMs / 1000
            if row.prevKind == CardStateKind.new.rawValue { stats.newCards += 1 }
            if row.prevKind == CardStateKind.review.rawValue { stats.reviewCards += 1 }
            if row.mode == StudyMode.voice.rawValue {
                stats.handsFreeReviews += 1
                stats.handsFreeSeconds += row.durationMs / 1000
            }
        }
        return stats
    }

    // MARK: History series

    public struct DayStats: Sendable, Equatable, Identifiable {
        public var id: Date { day }
        public var day: Date
        public var reviews = 0
        public var studySeconds = 0
        public var correct = 0  // reviews with rating != again
        public var newCards = 0
        public var handsFreeReviews = 0
        public var handsFreeSeconds = 0
    }

    /// Daily aggregates for the last `days` days.
    public func history(days: Int = 365, deckID: Int64? = nil, now: Date = Date()) throws -> [DayStats] {
        let start = ReviewRepository.startOfStudyDay(now).timeIntervalSince1970 - Double(days) * 86_400

        let joins = "JOIN cards c ON c.id = r.card_id"
        var binds: [SQLiteValue] = [.double(start)]
        var whereClause = "r.reviewed_at >= ?"
        if let deckID {
            let ids = try CardRepository(db: db).descendantDeckIDs(including: deckID)
            whereClause += " AND c.deck_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            binds.append(contentsOf: ids.map { .int($0) })
        }

        let rows = try db.query(
            """
            SELECT r.reviewed_at, r.rating, r.duration_ms, r.study_mode,
                   json_extract(r.previous_state, '$.kind') AS prev_kind
            FROM reviews r \(joins)
            WHERE \(whereClause)
            ORDER BY r.reviewed_at ASC
            """,
            binds
        ) { (at: $0.double(0), rating: $0.int32(1), durationMs: $0.int32(2), mode: $0.int32(3), prevKind: $0.int32(4)) }

        let calendar = Calendar.current
        var byDay: [Date: DayStats] = [:]
        for row in rows {
            let date = Date(timeIntervalSince1970: row.at)
            let key = calendar.startOfDay(for: date)
            var day = byDay[key] ?? DayStats(day: key)
            day.reviews += 1
            if row.rating != Rating.again.rawValue { day.correct += 1 }
            day.studySeconds += row.durationMs / 1000
            if row.prevKind == CardStateKind.new.rawValue { day.newCards += 1 }
            if row.mode == StudyMode.voice.rawValue {
                day.handsFreeReviews += 1
                day.handsFreeSeconds += row.durationMs / 1000
            }
            byDay[key] = day
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    // MARK: Streak

    /// Consecutive study days ending today (or yesterday, if today has no reviews yet).
    public func streak(now: Date = Date()) throws -> Int {
        let days = try history(days: 730, now: now)
        guard !days.isEmpty else { return 0 }
        var daySet = Set(days.map { Calendar.current.startOfDay(for: $0.day) })
        let today = Calendar.current.startOfDay(for: now)
        var cursor = daySet.contains(today) ? today : Calendar.current.date(byAdding: .day, value: -1, to: today)!
        guard daySet.contains(cursor) else { return 0 }
        var streak = 0
        while daySet.contains(cursor) {
            streak += 1
            daySet.remove(cursor)
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    // MARK: Collection overview

    public struct CollectionStats: Sendable, Equatable {
        public var totalCards = 0
        public var matureCards = 0  // stability >= 21 days
        public var suspendedCards = 0
    }

    public func collectionStats(deckID: Int64? = nil) throws -> CollectionStats {
        var stats = CollectionStats()
        var binds: [SQLiteValue] = []
        var whereClause = ""
        if let deckID {
            let ids = try CardRepository(db: db).descendantDeckIDs(including: deckID)
            whereClause = "WHERE deck_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            binds = ids.map { .int($0) }
        }
        let rows = try db.query(
            "SELECT state, suspended, stability FROM cards \(whereClause)",
            binds
        ) { (state: $0.int32(0), suspended: $0.int(1) != 0, stability: $0.doubleOrNil(2)) }
        stats.totalCards = rows.count
        for row in rows {
            if row.suspended { stats.suspendedCards += 1 }
            if let s = row.stability, s >= 21 { stats.matureCards += 1 }
        }
        return stats
    }

    // MARK: Hands-free totals

    public struct HandsFreeStats: Sendable, Equatable {
        public var reviews = 0
        public var seconds = 0
    }

    public func handsFree(now: Date = Date()) throws -> HandsFreeStats {
        var stats = HandsFreeStats()
        let rows = try db.query(
            "SELECT duration_ms, study_mode FROM reviews"
        ) { (durationMs: $0.int32(0), mode: $0.int32(1)) }
        for row in rows where row.mode == StudyMode.voice.rawValue {
            stats.reviews += 1
            stats.seconds += row.durationMs / 1000
        }
        return stats
    }
}
