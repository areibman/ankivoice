import Foundation

/// Anki's FSRS load balancer (`rslib/src/scheduler/states/load_balancer.rs`).
///
/// Inside the fuzz window it picks a day by weighted random. Weight falls with
/// the square of how many reviews are already due, prefers slightly shorter
/// intervals, avoids sibling days, and honours easy-day modifiers.
public enum FSRSLoadBalancer {
    public static let maxInterval = 90

    /// Monday = 0 … Sunday = 6. 1 normal, 0.5 reduced, 0 minimum.
    public static func select(
        intervalDays: Int,
        minimumDays: Int = 1,
        maximumDays: Int,
        dueCounts: [Int],
        easyDays: [Double],
        siblingDayOffsets: [Int],
        seed: UInt64,
        now: Date = Date()
    ) -> Int? {
        if intervalDays > maxInterval || minimumDays > maxInterval { return nil }
        let bounds = fuzzBounds(intervalDays: intervalDays, minimum: minimumDays, maximum: maximumDays)
        guard bounds.upper >= bounds.lower else { return nil }

        var reviewCounts: [Int] = []
        var weekdays: [Int] = []
        let start = ReviewRepository.startOfStudyDay(now)
        let calendar = Calendar.current
        for day in bounds.lower...bounds.upper {
            reviewCounts.append(day < dueCounts.count ? dueCounts[day] : 0)
            let date = calendar.date(byAdding: .day, value: day, to: start) ?? start
            // Apple weekday is Sunday = 1. Anki's easy-days array is Monday-first.
            let apple = calendar.component(.weekday, from: date)
            weekdays.append((apple + 5) % 7)
        }

        let easy = easyDayModifiers(easyDays: easyDays, weekdays: weekdays, reviewCounts: reviewCounts)
        let siblings = siblingModifiers(
            lower: bounds.lower, upper: bounds.upper, siblingDays: siblingDayOffsets
        )

        var weighted: [(interval: Int, weight: Double)] = []
        for (index, day) in (bounds.lower...bounds.upper).enumerated() {
            let count = reviewCounts[index]
            let weight: Double
            if count == 0 {
                weight = 1
            } else {
                let countWeight = pow(1.0 / Double(count), 2.15)
                let intervalWeight = pow(1.0 / Double(max(day, 1)), 3)
                weight = countWeight * intervalWeight * siblings[index] * easy[index]
            }
            weighted.append((day, max(weight, 0)))
        }
        return weightedPick(weighted, seed: seed)
    }

    /// Same window Anki's `constrained_fuzz_bounds` uses before weighting.
    static func fuzzBounds(intervalDays: Int, minimum: Int, maximum: Int) -> (lower: Int, upper: Int) {
        guard intervalDays >= 3 else {
            let day = min(max(intervalDays, minimum), maximum)
            return (day, day)
        }
        var delta = 1.0
        for range in FSRSScheduler.fuzzRanges {
            delta += range.factor * max(min(Double(intervalDays), range.end) - range.start, 0)
        }
        var lower = max(2, Int((Double(intervalDays) - delta).rounded()))
        var upper = Int((Double(intervalDays) + delta).rounded())
        lower = max(lower, minimum)
        upper = min(upper, maximum)
        if lower > upper { lower = upper }
        return (lower, upper)
    }

    private static let siblingSteps = [-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5]
    private static let siblingRange = [1.0, 0.8, 0.6, 0.4, 0.2, 0.000001, 0.2, 0.4, 0.6, 0.8, 1.0]

    private static func siblingModifiers(lower: Int, upper: Int, siblingDays: [Int]) -> [Double] {
        var modifiers = Array(repeating: 1.0, count: upper - lower + 1)
        for sibling in Set(siblingDays) {
            for (step, value) in zip(siblingSteps, siblingRange) {
                let index = sibling + step - lower
                if modifiers.indices.contains(index) {
                    modifiers[index] *= value
                }
            }
        }
        return modifiers
    }

    private static func easyDayModifiers(easyDays: [Double], weekdays: [Int], reviewCounts: [Int]) -> [Double] {
        let days = easyDays.count == 7 ? easyDays : Array(repeating: 1.0, count: 7)
        func modifier(_ value: Double) -> Double {
            if value >= 0.99 { return 1 }
            if value <= 0.001 { return 0.0001 }
            return 0.5
        }
        let totalReviews = reviewCounts.reduce(0, +)
        let totalPercents = weekdays.reduce(0.0) { $0 + modifier(days[$1]) }
        return zip(weekdays, reviewCounts).map { weekday, count in
            let raw = days[weekday]
            if raw >= 0.99 || raw <= 0.001 { return modifier(raw) }
            let otherReviews = Double(totalReviews - count)
            let otherPercents = totalPercents - 0.5
            guard otherPercents > 0 else { return 1 }
            let threshold = otherReviews / otherPercents
            let normalized = Double(count) / 0.5
            return normalized > threshold ? 0.0001 : 1
        }
    }

    private static func weightedPick(_ items: [(interval: Int, weight: Double)], seed: UInt64) -> Int? {
        let total = items.reduce(0.0) { $0 + $1.weight }
        guard total > 0, let first = items.first else { return nil }
        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        state &*= 6364136223846793005
        state &+= 1442695040888963407
        let unit = Double(state >> 11) / Double(UInt64(1) << 53)
        var cursor = unit * total
        for item in items {
            cursor -= item.weight
            if cursor <= 0 { return item.interval }
        }
        return first.interval
    }
}
