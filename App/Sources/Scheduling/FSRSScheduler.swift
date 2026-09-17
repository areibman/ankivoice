import Foundation

/// Faithful Swift port of the FSRS-6 scheduler (open-spaced-repetition py-fsrs 6.3.2).
///
/// Scheduling semantics follow the reference implementation exactly:
/// - 21 default parameters (w0…w20), with w20 controlling forgetting-curve decay.
/// - Learning/relearning steps at minute granularity; review intervals at day granularity.
/// - Short-term (same-day) stability updates via w17…w19.
/// - Interval fuzzing with the reference FUZZ_RANGES (deterministic when disabled).
///
/// All timestamps are UTC. `Double` rounding uses banker's rounding to match Python's `round()`.
public struct FSRSScheduler: Sendable {
    // MARK: Reference constants (py-fsrs 6.3.2)

    public static let defaultDecayWeight = 0.1542
    public static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
        1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
        1.8729, 0.5425, 0.0912, 0.0658, defaultDecayWeight,
    ]

    public static let stabilityMin = 0.001
    public static let minDifficulty = 1.0
    public static let maxDifficulty = 10.0

    public struct FuzzRange: Sendable {
        let start: Double
        let end: Double
        let factor: Double
    }

    public static let fuzzRanges: [FuzzRange] = [
        FuzzRange(start: 2.5, end: 7.0, factor: 0.15),
        FuzzRange(start: 7.0, end: 20.0, factor: 0.10),
        FuzzRange(start: 20.0, end: .infinity, factor: 0.05),
    ]

    // MARK: Configuration

    public var parameters: [Double]
    public var desiredRetention: Double
    /// Learning steps in seconds (default: 1 min, 10 min).
    public var learningSteps: [TimeInterval]
    /// Relearning steps in seconds (default: 10 min).
    public var relearningSteps: [TimeInterval]
    public var maximumInterval: Int
    public var enableFuzzing: Bool
    /// Uniform [0, 1) source for interval fuzzing. Injectable for deterministic tests.
    public var random: @Sendable () -> Double

    // Derived
    private let decay: Double   // -w20
    private let factor: Double  // 0.9^(1/decay) - 1

    public init(
        parameters: [Double] = FSRSScheduler.defaultParameters,
        desiredRetention: Double = 0.9,
        learningSteps: [TimeInterval] = [60, 600],
        relearningSteps: [TimeInterval] = [600],
        maximumInterval: Int = 36_500,
        enableFuzzing: Bool = false,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        precondition(parameters.count == 21, "FSRS-6 requires 21 parameters")
        self.parameters = parameters
        self.desiredRetention = desiredRetention
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
        self.maximumInterval = maximumInterval
        self.enableFuzzing = enableFuzzing
        self.random = random
        let decay = -parameters[20]
        self.decay = decay
        self.factor = pow(0.9, 1.0 / decay) - 1
    }

    // MARK: Retrievability

    /// Predicted recall probability at `now` given the last review and stability.
    /// Uses whole elapsed days, matching the reference implementation.
    public func retrievability(of card: FSRSMemoryState, now: Date = Date()) -> Double {
        guard let lastReview = card.lastReview, let stability = card.stability else { return 0 }
        let elapsedDays = max(0, floorDays(now.timeIntervalSince(lastReview)))
        return pow(1 + factor * Double(elapsedDays) / stability, decay)
    }

    // MARK: Review

    /// Applies a rating to a card, returning the next scheduling state and the interval applied.
    ///
    /// `state.new` behaves like the reference's fresh Learning card (step 0, no memory);
    /// after the first rating the card carries FSRS memory state.
    public func review(
        _ input: FSRSMemoryState, rating: Rating, at reviewDate: Date = Date()
    ) -> (state: FSRSMemoryState, interval: TimeInterval) {
        var card = input

        let daysSinceLastReview: Int? = card.lastReview.map {
            floorDays(reviewDate.timeIntervalSince($0))
        }

        var memoryPresent = card.stability != nil && card.difficulty != nil

        switch card.state {
        case .new:
            // First review: create initial memory state.
            card.stability = initialStability(rating: rating)
            card.difficulty = initialDifficulty(rating: rating, clamp: true)
            memoryPresent = true
            card.state = .learning
            card.step = 0

        case .learning, .relearning:
            let steps = card.state == .learning ? learningSteps : relearningSteps
            if !memoryPresent {
                card.stability = initialStability(rating: rating)
                card.difficulty = initialDifficulty(rating: rating, clamp: true)
                memoryPresent = true
            } else if let days = daysSinceLastReview, days < 1 {
                card.stability = shortTermStability(stability: card.stability!, rating: rating)
                card.difficulty = nextDifficulty(difficulty: card.difficulty!, rating: rating)
            } else {
                card.stability = nextStability(
                    difficulty: card.difficulty!,
                    stability: card.stability!,
                    retrievability: retrievability(of: card, now: reviewDate),
                    rating: rating
                )
                card.difficulty = nextDifficulty(difficulty: card.difficulty!, rating: rating)
            }
            let interval = advanceSteps(
                state: &card, steps: steps, rating: rating, memoryPresent: memoryPresent
            )
            card.reps += 1
            card.lastReview = reviewDate
            card.due = reviewDate.addingTimeInterval(interval)
            return (card, interval)

        case .review:
            precondition(memoryPresent, "review-state card must carry FSRS memory")
            if let days = daysSinceLastReview, days < 1 {
                card.stability = shortTermStability(stability: card.stability!, rating: rating)
            } else {
                card.stability = nextStability(
                    difficulty: card.difficulty!,
                    stability: card.stability!,
                    retrievability: retrievability(of: card, now: reviewDate),
                    rating: rating
                )
            }
            card.difficulty = nextDifficulty(difficulty: card.difficulty!, rating: rating)

            let interval: TimeInterval
            if rating == .again && !relearningSteps.isEmpty {
                card.state = .relearning
                card.step = 0
                interval = relearningSteps[0]
                card.lapses += 1
            } else {
                interval = TimeInterval(nextInterval(stability: card.stability!)) * 86_400
            }
            card.reps += 1
            card.lastReview = reviewDate
            card.due = reviewDate.addingTimeInterval(interval)
            return (card, interval)
        }

        // First-ever review path (was .new): apply learning steps.
        let interval = advanceSteps(state: &card, steps: learningSteps, rating: rating, memoryPresent: memoryPresent)
        card.reps += 1
        card.lastReview = reviewDate
        card.due = reviewDate.addingTimeInterval(interval)
        return (card, interval)
    }

    /// Advances learning/relearning step state after memory update.
    /// Mirrors the reference scheduler's interval selection.
    private func advanceSteps(
        state: inout FSRSMemoryState, steps: [TimeInterval], rating: Rating, memoryPresent: Bool
    ) -> TimeInterval {
        let step = state.step ?? 0

        // Edge case: card scheduled by a scheduler with more steps than the current one.
        if steps.isEmpty || (step >= steps.count && rating != .again) {
            state.state = .review
            state.step = nil
            let days = nextInterval(stability: state.stability ?? initialStability(rating: .good))
            return TimeInterval(days) * 86_400
        }

        switch rating {
        case .again:
            state.step = 0
            return steps[0]

        case .hard:
            // Step stays the same.
            let interval: TimeInterval
            if step == 0 && steps.count == 1 {
                interval = steps[0] * 1.5
            } else if step == 0 && steps.count >= 2 {
                interval = (steps[0] + steps[1]) / 2.0
            } else {
                interval = steps[min(step, steps.count - 1)]
            }
            return interval

        case .good:
            if step + 1 == steps.count {
                state.state = .review
                state.step = nil
                let days = nextInterval(stability: state.stability ?? initialStability(rating: .good))
                return TimeInterval(days) * 86_400
            } else {
                state.step = step + 1
                return steps[step + 1]
            }

        case .easy:
            state.state = .review
            state.step = nil
            let days = nextInterval(stability: state.stability ?? initialStability(rating: .easy))
            return TimeInterval(days) * 86_400
        }
    }

    // MARK: Rescheduling from history

    /// Replays review history through this scheduler, producing the resulting memory state.
    /// Used by Anki import to rebuild FSRS state from a revlog.
    public func reschedule(ratings: [(rating: Rating, at: Date)]) -> FSRSMemoryState {
        var card = FSRSMemoryState()
        for entry in ratings {
            let (next, _) = review(card, rating: entry.rating, at: entry.at)
            card = next
        }
        return card
    }

    // MARK: Core math (exact ports)

    private func initialStability(rating: Rating) -> Double {
        max(Double(parameters[rating.rawValue - 1]), Self.stabilityMin)
    }

    private func initialDifficulty(rating: Rating, clamp: Bool) -> Double {
        var d = parameters[4] - exp(parameters[5] * Double(rating.rawValue - 1)) + 1
        if clamp {
            d = min(max(d, Self.minDifficulty), Self.maxDifficulty)
        }
        return d
    }

    public func nextInterval(stability: Double) -> Int {
        var interval = (stability / factor) * (pow(desiredRetention, 1.0 / decay) - 1)
        interval = interval.rounded(.toNearestOrEven)  // Python round(): banker's rounding
        interval = max(interval, 1)
        interval = min(interval, Double(maximumInterval))
        return Int(interval)
    }

    private func shortTermStability(stability: Double, rating: Rating) -> Double {
        var increase = exp(parameters[17] * (Double(rating.rawValue) - 3 + parameters[18]))
            * pow(stability, -parameters[19])
        if rating != .again {
            increase = max(increase, 1.0)
        }
        return max(stability * increase, Self.stabilityMin)
    }

    private func nextDifficulty(difficulty: Double, rating: Rating) -> Double {
        func linearDamping(_ deltaD: Double, _ difficulty: Double) -> Double {
            (10.0 - difficulty) * deltaD / 9.0
        }
        func meanReversion(_ a1: Double, _ a2: Double) -> Double {
            parameters[7] * a1 + (1 - parameters[7]) * a2
        }
        let arg1 = initialDifficulty(rating: .easy, clamp: false)
        let deltaD = -(parameters[6] * Double(rating.rawValue - 3))
        let arg2 = difficulty + linearDamping(deltaD, difficulty)
        return min(max(meanReversion(arg1, arg2), Self.minDifficulty), Self.maxDifficulty)
    }

    private func nextStability(
        difficulty: Double, stability: Double, retrievability: Double, rating: Rating
    ) -> Double {
        let next: Double
        if rating == .again {
            next = nextForgetStability(
                difficulty: difficulty, stability: stability, retrievability: retrievability
            )
        } else {
            next = nextRecallStability(
                difficulty: difficulty, stability: stability,
                retrievability: retrievability, rating: rating
            )
        }
        return max(next, Self.stabilityMin)
    }

    private func nextForgetStability(difficulty: Double, stability: Double, retrievability: Double) -> Double {
        let longTerm =
            parameters[11]
            * pow(difficulty, -parameters[12])
            * (pow(stability + 1, parameters[13]) - 1)
            * exp((1 - retrievability) * parameters[14])
        let shortTerm = stability / exp(parameters[17] * parameters[18])
        return min(longTerm, shortTerm)
    }

    private func nextRecallStability(
        difficulty: Double, stability: Double, retrievability: Double, rating: Rating
    ) -> Double {
        let hardPenalty = rating == .hard ? parameters[15] : 1
        let easyBonus = rating == .easy ? parameters[16] : 1
        return stability
            * (1
                + exp(parameters[8])
                * (11 - difficulty)
                * pow(stability, -parameters[9])
                * (exp((1 - retrievability) * parameters[10]) - 1)
                * hardPenalty
                * easyBonus)
    }

    // MARK: Fuzzing

    private func fuzzedInterval(days: Int) -> Int {
        guard days >= 3 else { return days }  // reference: intervals below 2.5 days are not fuzzed

        var delta = 1.0
        for range in Self.fuzzRanges {
            delta += range.factor
                * max(min(Double(days), range.end) - range.start, 0.0)
        }
        var minIvl = Int((Double(days) - delta).rounded())
        var maxIvl = Int((Double(days) + delta).rounded())
        minIvl = max(2, minIvl)
        maxIvl = min(maxIvl, maximumInterval)
        minIvl = min(minIvl, maxIvl)

        let span = Double(maxIvl - minIvl + 1)
        let fuzzed = Int((random() * span + Double(minIvl)).rounded(.toNearestOrEven))
        return min(fuzzed, maximumInterval)
    }

    /// Applies fuzzing to a computed day interval (no-op unless `enableFuzzing`).
    public func applyFuzz(toIntervalDays days: Int) -> Int {
        guard enableFuzzing else { return days }
        return fuzzedInterval(days: days)
    }
}

// MARK: - Memory state

/// Pure FSRS memory state decoupled from persistence.
public struct FSRSMemoryState: Codable, Sendable, Hashable {
    public var state: FSRSCardPhase
    public var step: Int?
    public var stability: Double?
    public var difficulty: Double?
    public var due: Date
    public var lastReview: Date?
    public var reps: Int
    public var lapses: Int

    public init(
        state: FSRSCardPhase = .new,
        step: Int? = nil,
        stability: Double? = nil,
        difficulty: Double? = nil,
        due: Date = Date(),
        lastReview: Date? = nil,
        reps: Int = 0,
        lapses: Int = 0
    ) {
        self.state = state
        self.step = step
        self.stability = stability
        self.difficulty = difficulty
        self.due = due
        self.lastReview = lastReview
        self.reps = reps
        self.lapses = lapses
    }
}

/// Scheduling phases used by the FSRS scheduler.
public enum FSRSCardPhase: Int, Codable, Sendable, Hashable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

// MARK: - Bridging

public extension SchedulingState {
    var memoryState: FSRSMemoryState {
        FSRSMemoryState(
            state: FSRSCardPhase(rawValue: kind.rawValue) ?? .new,
            step: step,
            stability: stability,
            difficulty: difficulty,
            due: due,
            lastReview: lastReview,
            reps: reps,
            lapses: lapses
        )
    }

    init(memory: FSRSMemoryState) {
        self.init(
            kind: CardStateKind(rawValue: memory.state.rawValue) ?? .new,
            step: memory.step,
            stability: memory.stability,
            difficulty: memory.difficulty,
            due: memory.due,
            lastReview: memory.lastReview,
            lapses: memory.lapses,
            reps: memory.reps
        )
    }
}

// MARK: - Helpers

/// Whole days from a duration, floored (matches Python's timedelta.days).
@inline(__always)
func floorDays(_ seconds: TimeInterval) -> Int {
    guard seconds >= 0 else { return 0 }
    return Int(seconds / 86_400)
}
