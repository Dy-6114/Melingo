import Foundation

/// FSRS-6 long-term scheduler (day granularity).
///
/// Ported 1:1 from iOS `OKSRS` / desktop `fsrs.rs`; cross-platform contract:
/// `docs/specs/vocabulary-srs-spec.md`. Golden cases live in
/// `Tests/DomainEntityTests/Fixtures/fsrs_golden_v1.json`.
public enum FSRS {
    /// ts-fsrs 5.4.1 default_w (w0..w20)
    public static let defaultParams: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
        1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
        1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    public static let schedulerVersion = "fsrs6"
    public static let defaultDesiredRetention = 0.9
    private static let sMin = 0.001
    private static let maxInterval = 36500
    private static let sm2Retention = 0.9

    public enum Grade: Int, Sendable, CaseIterable {
        case again = 1
        case hard = 2
        case good = 3
        case easy = 4
    }

    public struct Update: Sendable, Equatable {
        public var stability: Double
        public var difficulty: Double
        public var intervalDays: Int
        public var state: SRSState
    }

    public enum EngineError: Error, Equatable {
        case invalidElapsedDays(Int)
        case invalidDesiredRetention(Double)
    }

    private static func round8(_ x: Double) -> Double {
        (x * 1e8).rounded() / 1e8
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }

    private static var decay: Double { -defaultParams[20] }

    private static var factor: Double { round8(pow(0.9, 1.0 / decay) - 1.0) }

    /// R(t, S). t = days since last review; t=0 → 1.
    public static func retrievability(stability: Double, elapsedDays: Double) -> Double {
        guard stability > 0 else { return 0 }
        return round8(pow(1.0 + factor * elapsedDays / stability, decay))
    }

    private static func intervalModifier(_ desiredRetention: Double) throws -> Double {
        guard desiredRetention > 0, desiredRetention <= 1 else {
            throw EngineError.invalidDesiredRetention(desiredRetention)
        }
        return round8((pow(desiredRetention, 1.0 / decay) - 1.0) / factor)
    }

    private static func nextInterval(stability: Double, modifier: Double) -> Int {
        let raw = max(1.0, (stability * modifier).rounded())
        return min(Int(raw), maxInterval)
    }

    private static func initStability(_ grade: Grade) -> Double {
        max(defaultParams[grade.rawValue - 1], 0.1)
    }

    private static func initDifficulty(_ grade: Grade) -> Double {
        let w = defaultParams
        return round8(w[4] - exp(Double(grade.rawValue - 1) * w[5]) + 1.0)
    }

    private static func linearDamping(deltaD: Double, oldD: Double) -> Double {
        round8(deltaD * (10.0 - oldD) / 9.0)
    }

    private static func meanReversion(initial: Double, current: Double) -> Double {
        let w = defaultParams
        return round8(w[7] * initial + (1.0 - w[7]) * current)
    }

    private static func nextDifficulty(_ difficulty: Double, _ grade: Grade) -> Double {
        let w = defaultParams
        let deltaD = -w[6] * (Double(grade.rawValue) - 3.0)
        let nextD = difficulty + linearDamping(deltaD: deltaD, oldD: difficulty)
        return clamp(meanReversion(initial: initDifficulty(.easy), current: nextD), 1.0, 10.0)
    }

    private static func nextRecallStability(
        _ difficulty: Double, _ stability: Double, _ r: Double, _ grade: Grade
    ) -> Double {
        let w = defaultParams
        let hardPenalty = grade == .hard ? w[15] : 1.0
        let easyBonus = grade == .easy ? w[16] : 1.0
        let grown =
            stability
            * (1.0
                + exp(w[8])
                    * (11.0 - difficulty)
                    * pow(stability, -w[9])
                    * (exp((1.0 - r) * w[10]) - 1.0)
                    * hardPenalty
                    * easyBonus)
        return round8(clamp(grown, sMin, Double(maxInterval)))
    }

    private static func nextForgetStability(
        _ difficulty: Double, _ stability: Double, _ r: Double
    ) -> Double {
        let w = defaultParams
        let forgotten =
            w[11]
            * pow(difficulty, -w[12])
            * (pow(stability + 1.0, w[13]) - 1.0)
            * exp((1.0 - r) * w[14])
        return round8(clamp(forgotten, sMin, Double(maxInterval)))
    }

    private static func nextMemoryState(
        stability: Double, difficulty: Double, elapsedDays: Int, grade: Grade
    ) -> (stability: Double, difficulty: Double) {
        if stability == 0, difficulty == 0 {
            return (initStability(grade), clamp(initDifficulty(grade), 1.0, 10.0))
        }
        let r = retrievability(stability: stability, elapsedDays: Double(elapsedDays))
        let newS: Double
        if grade == .again {
            newS = clamp(round8(stability), sMin, nextForgetStability(difficulty, stability, r))
        } else {
            newS = nextRecallStability(difficulty, stability, r, grade)
        }
        return (newS, nextDifficulty(difficulty, grade))
    }

    /// Computes four grades, applies interval ordering fix, returns the chosen grade.
    public static func nextReview(
        stability: Double,
        difficulty: Double,
        elapsedDays: Int,
        grade: Grade,
        desiredRetention: Double = FSRS.defaultDesiredRetention
    ) throws -> Update {
        guard elapsedDays >= 0 else { throw EngineError.invalidElapsedDays(elapsedDays) }
        let modifier = try intervalModifier(desiredRetention)

        var states: [(stability: Double, difficulty: Double)] = []
        var intervals: [Int] = []
        for g in Grade.allCases {
            let state = nextMemoryState(
                stability: stability, difficulty: difficulty, elapsedDays: elapsedDays, grade: g)
            states.append(state)
            intervals.append(nextInterval(stability: state.stability, modifier: modifier))
        }
        intervals[0] = min(intervals[0], intervals[1])
        intervals[1] = max(intervals[1], intervals[0] + 1)
        intervals[2] = max(intervals[2], intervals[1] + 1)
        intervals[3] = max(intervals[3], intervals[2] + 1)

        let index = grade.rawValue - 1
        return Update(
            stability: states[index].stability,
            difficulty: states[index].difficulty,
            intervalDays: intervals[index],
            state: grade == .again ? .learning : .review
        )
    }

    public static func seedFromSM2(
        intervalDays: Int, easeFactor: Double
    ) -> (stability: Double, difficulty: Double) {
        let w = defaultParams
        let stability = max(Double(intervalDays), 0.1) / (9.0 * (1.0 / sm2Retention - 1.0))
        let denominator =
            exp(w[8]) * pow(stability, -w[9]) * (exp((1.0 - sm2Retention) * w[10]) - 1.0)
        let difficulty = clamp(11.0 - (easeFactor - 1.0) / denominator, 1.0, 10.0)
        return (stability, difficulty)
    }
}
