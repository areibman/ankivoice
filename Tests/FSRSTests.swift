import XCTest
@testable import AnkiVoice

/// Deterministic verification of the FSRS-6 port against the py-fsrs 6.3.2
/// reference implementation's published test expectations.
final class FSRSTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 30) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        comps.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: comps)!
    }

    /// Reference: py-fsrs test_review_card — interval history for the
    /// Good×6, Again×2, Good×5 sequence.
    func testIntervalHistoryMatchesReference() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        var state = FSRSMemoryState()
        var reviewDate = utc(2022, 11, 29)

        let ratings: [Rating] = [.good, .good, .good, .good, .good, .good,
                                 .again, .again, .good, .good, .good, .good, .good]
        var intervals: [Int] = []

        for rating in ratings {
            let (next, interval) = scheduler.review(state, rating: rating, at: reviewDate)
            state = next
            intervals.append(floorDays(interval))
            reviewDate = state.due
        }

        XCTAssertEqual(intervals, [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21])
    }

    /// Reference: py-fsrs test_memo_state — stability/difficulty after
    /// Again, Good×5 with the given interval pattern.
    func testMemoryStateMatchesReference() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let ratings: [Rating] = [.again, .good, .good, .good, .good, .good]
        let intervals: [Int] = [0, 0, 1, 3, 8, 21]

        var state = FSRSMemoryState()
        var reviewDate = utc(2022, 11, 29)
        for (rating, interval) in zip(ratings, intervals) {
            reviewDate = reviewDate.addingTimeInterval(Double(interval) * 86_400)
            let (next, _) = scheduler.review(state, rating: rating, at: reviewDate)
            state = next
        }

        let stability = try XCTUnwrap(state.stability)
        let difficulty = try XCTUnwrap(state.difficulty)
        XCTAssertEqual(stability, 53.62691, accuracy: 1e-4)
        XCTAssertEqual(difficulty, 6.3574867, accuracy: 1e-4)
    }

    /// Reference: py-fsrs test_repeated_correct_reviews — difficulty saturates
    /// at the minimum after repeated Easy reviews on the same day.
    func testRepeatedEasySaturatesDifficulty() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        var state = FSRSMemoryState()
        for i in 0..<10 {
            let (next, _) = scheduler.review(state, rating: .easy, at: utc(2022, 11, 29, 12, 30 + i))
            state = next
        }
        XCTAssertEqual(state.difficulty ?? -1, 1.0, accuracy: 1e-9)
    }

    /// First review of a new card with Good follows the second learning step (10 minutes).
    func testFirstGoodReviewUsesLearningStep() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let (state, interval) = scheduler.review(FSRSMemoryState(), rating: .good, at: utc(2023, 1, 1))
        XCTAssertEqual(state.state, .learning)
        XCTAssertEqual(state.step, 1)
        XCTAssertEqual(interval, 600, accuracy: 0.001)
        XCTAssertEqual(state.due, utc(2023, 1, 1).addingTimeInterval(600))
        XCTAssertNotNil(state.stability)
        XCTAssertNotNil(state.difficulty)
    }

    /// First review with Easy graduates straight to review state with a >= 1 day interval.
    func testFirstEasyGraduatesToReview() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let (state, interval) = scheduler.review(FSRSMemoryState(), rating: .easy, at: utc(2023, 1, 1))
        XCTAssertEqual(state.state, .review)
        XCTAssertNil(state.step)
        XCTAssertGreaterThanOrEqual(floorDays(interval), 1)
    }

    /// Review card answered Again enters relearning at the first step and counts a lapse.
    func testReviewAgainEntersRelearning() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let (graduated, _) = scheduler.review(FSRSMemoryState(), rating: .easy, at: utc(2023, 1, 1))
        XCTAssertEqual(graduated.state, .review)
        let (failed, interval) = scheduler.review(graduated, rating: .again, at: utc(2023, 1, 11))
        XCTAssertEqual(failed.state, .relearning)
        XCTAssertEqual(failed.step, 0)
        XCTAssertEqual(interval, 600, accuracy: 0.001)
        XCTAssertEqual(failed.lapses, 1)
        XCTAssertLessThan(try XCTUnwrap(failed.stability), try XCTUnwrap(graduated.stability))
    }

    /// Retrievability decays with elapsed time and equals desired retention one interval after graduation.
    func testRetrievabilityCurve() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        let reviewAt = utc(2023, 1, 1)
        // Easy graduates immediately, producing a day-level interval.
        let (state, interval) = scheduler.review(FSRSMemoryState(), rating: .easy, at: reviewAt)
        XCTAssertEqual(state.state, .review)
        let days = floorDays(interval)
        XCTAssertGreaterThanOrEqual(days, 1)

        // At exactly one interval later, predicted recall equals desired retention.
        let now = state.due
        let r = scheduler.retrievability(of: state, now: now)
        XCTAssertEqual(r, scheduler.desiredRetention, accuracy: 0.02)

        // Further out, recall probability decays.
        let later = now.addingTimeInterval(Double(days) * 86_400)
        XCTAssertLessThan(scheduler.retrievability(of: state, now: later), r)
        XCTAssertGreaterThan(r, 0)
    }

    /// New cards report zero retrievability.
    func testNewCardRetrievabilityIsZero() {
        let scheduler = FSRSScheduler()
        XCTAssertEqual(scheduler.retrievability(of: FSRSMemoryState()), 0)
    }

    /// Higher desired retention produces shorter intervals at fixed stability.
    func testDesiredRetentionScalesIntervals() {
        let low = FSRSScheduler(desiredRetention: 0.8, enableFuzzing: false)
        let high = FSRSScheduler(desiredRetention: 0.95, enableFuzzing: false)

        let stability = 3.0
        let i1 = low.nextInterval(stability: stability)
        let i2 = high.nextInterval(stability: stability)
        XCTAssertGreaterThan(i1, i2)

        // At default retention the interval equals stability (factor identity).
        let mid = FSRSScheduler(enableFuzzing: false)
        XCTAssertEqual(mid.nextInterval(stability: 3.0), 3)
    }

    /// Fuzz stays within the reference bounds and never returns out-of-range values.
    func testFuzzBounds() {
        let scheduler = FSRSScheduler(enableFuzzing: true, random: { 0.0 })
        // delta = 1 + 0.15*(7-2.5) + 0.10*(20-7) + 0.05*(100-20) = 6.975
        XCTAssertEqual(scheduler.applyFuzz(toIntervalDays: 100), 93)
        let maxScheduler = FSRSScheduler(enableFuzzing: true, random: { 0.999999 })
        let fuzzed = maxScheduler.applyFuzz(toIntervalDays: 100)
        XCTAssertLessThanOrEqual(fuzzed, 108)
        XCTAssertGreaterThanOrEqual(fuzzed, 93)
        // Intervals below 2.5 days are never fuzzed.
        XCTAssertEqual(scheduler.applyFuzz(toIntervalDays: 1), 1)
        XCTAssertEqual(scheduler.applyFuzz(toIntervalDays: 2), 2)
    }

    /// Rescheduling from history reproduces the same state as live review.
    func testRescheduleMatchesLiveReviews() throws {
        let scheduler = FSRSScheduler(enableFuzzing: false)
        var state = FSRSMemoryState()
        var date = utc(2023, 1, 1)
        var history: [(Rating, Date)] = []
        for rating in [Rating.good, Rating.good, Rating.again, Rating.good, Rating.easy, Rating.good] {
            history.append((rating, date))
            let (next, _) = scheduler.review(state, rating: rating, at: date)
            state = next
            date = state.due.addingTimeInterval(86_400)
        }
        let replayed = scheduler.reschedule(ratings: history)
        XCTAssertEqual(replayed.stability ?? -1, state.stability ?? -2, accuracy: 1e-9)
        XCTAssertEqual(replayed.difficulty ?? -1, state.difficulty ?? -2, accuracy: 1e-9)
    }

    /// Bridging between persistence scheduling state and FSRS memory state round-trips.
    func testSchedulingStateBridge() {
        let memory = FSRSMemoryState(
            state: .review, step: nil, stability: 12.5, difficulty: 5.5,
            due: utc(2023, 5, 1), lastReview: utc(2023, 4, 1), reps: 7, lapses: 1
        )
        let scheduling = SchedulingState(memory: memory)
        let roundTrip = scheduling.memoryState
        XCTAssertEqual(roundTrip, memory)
    }
}
