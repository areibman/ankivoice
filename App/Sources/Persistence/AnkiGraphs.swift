import Foundation

/// The statistics graphs Anki's stats screen shows, computed from this
/// collection. True retention counts a non-Again grade on a review card as
/// a pass, split at the 21-day stability line Anki calls mature.
public struct AnkiGraphs: Sendable, Equatable {
    public struct Bucket: Identifiable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var value: Int
    }

    public var forecast: [Bucket] = []
    public var calendar: [Bucket] = []
    public var intervals: [Bucket] = []
    public var hourly: [Bucket] = []
    public var buttons: [Bucket] = []
    public var cardTypes: [Bucket] = []
    public var added: [Bucket] = []
    public var youngPass = 0
    public var youngFail = 0
    public var maturePass = 0
    public var matureFail = 0
    public var stability: [Bucket] = []
    public var difficulty: [Bucket] = []
    public var retrievability: [Bucket] = []

    public var youngRetention: Double? { ratio(youngPass, youngFail) }
    public var matureRetention: Double? { ratio(maturePass, matureFail) }

    private func ratio(_ pass: Int, _ fail: Int) -> Double? {
        let total = pass + fail
        guard total > 0 else { return nil }
        return Double(pass) / Double(total)
    }

    public static func compute(cards: CardRepository, reviews: ReviewRepository, now: Date = Date()) throws -> AnkiGraphs {
        var graphs = AnkiGraphs()
        let all = try cards.allStudyCards()
        let logs = try reviews.allChronological()
        let calendar = Calendar.current
        let today = ReviewRepository.startOfStudyDay(now)

        var dueByDay: [Int: Int] = [:]
        for card in all where !card.card.suspended && card.card.bury != .user {
            let dueDay = calendar.dateComponents(
                [.day], from: today, to: ReviewRepository.startOfStudyDay(card.card.scheduling.due)
            ).day ?? 0
            if dueDay >= 0, dueDay < 30, card.card.scheduling.kind != .new {
                dueByDay[dueDay, default: 0] += 1
            }
        }
        graphs.forecast = (0..<30).map { day in
            let date = calendar.date(byAdding: .day, value: day, to: today) ?? today
            return Bucket(id: "f\(day)", label: date.formatted(.dateTime.month(.abbreviated).day()), value: dueByDay[day] ?? 0)
        }

        var reviewsByDay: [Date: Int] = [:]
        var addedByDay: [Date: Int] = [:]
        var hours = Array(repeating: 0, count: 24)
        var again = 0, hard = 0, good = 0, easy = 0
        for log in logs {
            let day = calendar.startOfDay(for: log.reviewedAt)
            reviewsByDay[day, default: 0] += 1
            hours[calendar.component(.hour, from: log.reviewedAt)] += 1
            switch log.rating {
            case .again: again += 1
            case .hard: hard += 1
            case .good: good += 1
            case .easy: easy += 1
            }
            if log.previousState.kind == .review {
                let mature = (log.previousState.stability ?? 0) >= 21
                if log.rating == .again {
                    if mature { graphs.matureFail += 1 } else { graphs.youngFail += 1 }
                } else if mature {
                    graphs.maturePass += 1
                } else {
                    graphs.youngPass += 1
                }
            }
        }
        graphs.hourly = hours.enumerated().map { Bucket(id: "h\($0.offset)", label: String(format: "%02d", $0.offset), value: $0.element) }
        graphs.buttons = [
            Bucket(id: "again", label: "Again", value: again),
            Bucket(id: "hard", label: "Hard", value: hard),
            Bucket(id: "good", label: "Good", value: good),
            Bucket(id: "easy", label: "Easy", value: easy),
        ]
        graphs.calendar = (0..<119).reversed().map { ago in
            let date = calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now)) ?? now
            return Bucket(id: "c\(ago)", label: date.formatted(.dateTime.month().day()), value: reviewsByDay[date] ?? 0)
        }

        for card in all {
            let day = calendar.startOfDay(for: card.card.createdAt)
            addedByDay[day, default: 0] += 1
        }
        graphs.added = (0..<30).reversed().map { ago in
            let date = calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now)) ?? now
            return Bucket(id: "a\(ago)", label: date.formatted(.dateTime.month(.abbreviated).day()), value: addedByDay[date] ?? 0)
        }

        var newCards = 0, learning = 0, young = 0, mature = 0, suspended = 0
        var intervalBuckets = [0, 0, 0, 0, 0]
        var stabilityBuckets = [0, 0, 0, 0]
        var difficultyBuckets = [0, 0, 0]
        var recallBuckets = [0, 0, 0, 0]
        let scheduler = FSRSScheduler()
        for card in all {
            if card.card.suspended { suspended += 1; continue }
            switch card.card.scheduling.kind {
            case .new: newCards += 1
            case .learning, .relearning: learning += 1
            case .review:
                let stability = card.card.scheduling.stability ?? 0
                if stability >= 21 { mature += 1 } else { young += 1 }
                switch stability {
                case ..<8: intervalBuckets[0] += 1
                case ..<22: intervalBuckets[1] += 1
                case ..<91: intervalBuckets[2] += 1
                case ..<366: intervalBuckets[3] += 1
                default: intervalBuckets[4] += 1
                }
                switch stability {
                case ..<10: stabilityBuckets[0] += 1
                case ..<30: stabilityBuckets[1] += 1
                case ..<100: stabilityBuckets[2] += 1
                default: stabilityBuckets[3] += 1
                }
                let difficulty = card.card.scheduling.difficulty ?? 5
                if difficulty < 4 { difficultyBuckets[0] += 1 }
                else if difficulty < 7 { difficultyBuckets[1] += 1 }
                else { difficultyBuckets[2] += 1 }
                let recall = scheduler.retrievability(of: card.card.scheduling.memoryState, now: now)
                if recall >= 0.9 { recallBuckets[0] += 1 }
                else if recall >= 0.8 { recallBuckets[1] += 1 }
                else if recall >= 0.7 { recallBuckets[2] += 1 }
                else { recallBuckets[3] += 1 }
            }
        }
        graphs.cardTypes = [
            Bucket(id: "new", label: "New", value: newCards),
            Bucket(id: "learn", label: "Learning", value: learning),
            Bucket(id: "young", label: "Young", value: young),
            Bucket(id: "mature", label: "Mature", value: mature),
            Bucket(id: "suspended", label: "Suspended", value: suspended),
        ]
        graphs.intervals = zip(["< 8d", "8–21d", "22–90d", "3–12mo", "1y+"], intervalBuckets).map {
            Bucket(id: $0.0, label: $0.0, value: $0.1)
        }
        graphs.stability = zip(["< 10d", "10–30d", "1–3mo", "3mo+"], stabilityBuckets).map {
            Bucket(id: "s\($0.0)", label: $0.0, value: $0.1)
        }
        graphs.difficulty = zip(["Easy 1–4", "Mid 4–7", "Hard 7–10"], difficultyBuckets).map {
            Bucket(id: "d\($0.0)", label: $0.0, value: $0.1)
        }
        graphs.retrievability = zip(["≥ 90%", "80–90%", "70–80%", "< 70%"], recallBuckets).map {
            Bucket(id: "r\($0.0)", label: $0.0, value: $0.1)
        }
        return graphs
    }
}
