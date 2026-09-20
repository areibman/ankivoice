import Foundation

/// FSRS-6 parameter fit.
///
/// The loss is the same binary cross-entropy fsrs-rs trains (`BCELoss` on the
/// power forgetting curve), and weights are clipped with the FSRS-6 clamps
/// from `parameter_clipper_v6.rs`. The search is Adam with central-difference
/// gradients because Burn, the trainer Anki links, is not available on iOS.
/// The objective is the one Anki optimizes; the backend is not.
public struct FSRSOptimizer: Sendable {
    public struct Report: Sendable, Equatable {
        public var parameters: [Double]
        public var reviewCount: Int
        public var lossBefore: Double
        public var lossAfter: Double
    }

    public enum Failure: Error, Equatable {
        case notEnoughReviews(have: Int, need: Int)
    }

    public static let minimumReviews = 400

    private static let initStabilityMax = 100.0
    private static let stabilityMin = FSRSScheduler.stabilityMin

    public init() {}

    public func optimize(logs: [ReviewLog], steps: Int = 12) throws -> Report {
        let histories = Self.histories(from: logs)
        let reviewCount = histories.reduce(0) { $0 + $1.reviews.count }
        guard reviewCount >= Self.minimumReviews else {
            throw Failure.notEnoughReviews(have: reviewCount, need: Self.minimumReviews)
        }
        var parameters = FSRSScheduler.defaultParameters
        let before = loss(parameters, histories: histories)
        let used = Array(histories.suffix(800))
        var moment = Array(repeating: 0.0, count: 21)
        var velocity = Array(repeating: 0.0, count: 21)
        let rate = 0.02
        for step in 1...steps {
            let gradient = numericalGradient(parameters, histories: used)
            for index in 0..<21 {
                moment[index] = 0.9 * moment[index] + 0.1 * gradient[index]
                velocity[index] = 0.999 * velocity[index] + 0.001 * gradient[index] * gradient[index]
                let mHat = moment[index] / (1 - pow(0.9, Double(step)))
                let vHat = velocity[index] / (1 - pow(0.999, Double(step)))
                parameters[index] -= rate * mHat / (sqrt(vHat) + 1e-8)
            }
            parameters = Self.clip(parameters, relearningSteps: 1, shortTerm: true)
        }
        return Report(
            parameters: parameters,
            reviewCount: reviewCount,
            lossBefore: before,
            lossAfter: loss(parameters, histories: used)
        )
    }

    struct History: Sendable {
        var reviews: [(at: Date, rating: Rating)]
    }

    static func histories(from logs: [ReviewLog]) -> [History] {
        Dictionary(grouping: logs, by: \.cardID).values.map { entries in
            History(reviews: entries.sorted { $0.reviewedAt < $1.reviewedAt }.map { ($0.reviewedAt, $0.rating) })
        }
    }

    /// Replays each card with `parameters` so stability, not just the forgetting
    /// curve, moves during the fit. Loss is weighted BCE plus an L2 pull toward
    /// the published defaults, matching fsrs-rs.
    func loss(_ parameters: [Double], histories: [History]) -> Double {
        let scheduler = FSRSScheduler(parameters: parameters, enableFuzzing: false)
        let decay = -parameters[20]
        let factor = pow(0.9, 1.0 / decay) - 1
        var total = 0.0
        var weightSum = 0.0
        var counted = 0
        let now = Date()
        for history in histories {
            var memory = FSRSMemoryState()
            var previous: Date?
            for review in history.reviews {
                if let previous, let stability = memory.stability {
                    let elapsed = max(0, floorDays(review.at.timeIntervalSince(previous)))
                    if elapsed > 0 {
                        let r = pow(1 + factor * Double(elapsed) / max(stability, Self.stabilityMin), decay)
                        let clipped = min(max(r, 1e-6), 1 - 1e-6)
                        let label = review.rating == .again ? 0.0 : 1.0
                        let age = max(0, now.timeIntervalSince(review.at) / 86_400)
                        let weight = exp(-age / 365.0)
                        total += -(label * log(clipped) + (1 - label) * log(1 - clipped)) * weight
                        weightSum += weight
                        counted += 1
                    }
                }
                memory = scheduler.review(memory, rating: review.rating, at: review.at).state
                previous = review.at
            }
        }
        let std: [Double] = [
            6.43, 9.66, 17.58, 27.85, 0.57, 0.28, 0.6, 0.12, 0.39, 0.18, 0.33,
            0.3, 0.09, 0.16, 0.57, 0.25, 1.03, 0.31, 0.32, 0.14, 0.27,
        ]
        let defaults = FSRSScheduler.defaultParameters
        var penalty = 0.0
        for index in 0..<21 {
            let delta = parameters[index] - defaults[index]
            penalty += (delta * delta) / (std[index] * std[index])
        }
        let mean = weightSum > 0 ? total / weightSum : 0
        return mean + 0.05 * penalty / Double(max(counted, 1))
    }

    private func numericalGradient(_ parameters: [Double], histories: [History]) -> [Double] {
        var gradient = Array(repeating: 0.0, count: 21)
        let epsilon = 1e-3
        for index in 0..<21 {
            var up = parameters
            var down = parameters
            up[index] += epsilon
            down[index] -= epsilon
            up = Self.clip(up, relearningSteps: 1, shortTerm: true)
            down = Self.clip(down, relearningSteps: 1, shortTerm: true)
            gradient[index] = (loss(up, histories: histories) - loss(down, histories: histories)) / (2 * epsilon)
        }
        return gradient
    }

    /// `parameter_clipper_v6.rs`, with one relearning step and short-term stability on.
    static func clip(_ parameters: [Double], relearningSteps: Int, shortTerm: Bool) -> [Double] {
        var w = parameters
        guard w.count == 21 else { return FSRSScheduler.defaultParameters }
        let w17Ceiling: Double
        if relearningSteps > 1 {
            let inside = -(log(max(w[11], 1e-6)) + log(max(pow(2, w[13]) - 1, 1e-6)) + w[14] * 0.3)
            w17Ceiling = min(2, max(0.01, sqrt(max(inside / Double(relearningSteps), 0))))
        } else {
            w17Ceiling = 2
        }
        let w19Floor = shortTerm ? 0.01 : 0.0
        let clamps: [(Double, Double)] = [
            (stabilityMin, initStabilityMax),
            (stabilityMin, initStabilityMax),
            (stabilityMin, initStabilityMax),
            (stabilityMin, initStabilityMax),
            (1, 10),
            (0.001, 4),
            (0.001, 4),
            (0.001, 0.75),
            (0, 4.5),
            (0, 0.8),
            (0.001, 3.5),
            (0.001, 5),
            (0.001, 0.25),
            (0.001, 0.9),
            (0, 4),
            (0, 1),
            (1, 6),
            (0, w17Ceiling),
            (0, w17Ceiling),
            (w19Floor, 0.8),
            (0.1, 0.8),
        ]
        for index in 0..<21 {
            w[index] = min(max(w[index], clamps[index].0), clamps[index].1)
            if !w[index].isFinite { w[index] = FSRSScheduler.defaultParameters[index] }
        }
        return w
    }
}
