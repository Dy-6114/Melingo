import Foundation
import Testing
import Domain

@Suite("FSRS golden")
struct FSRSGoldenTests {
    struct Review: Decodable {
        let dayOffset: Int
        let grade: String
        enum CodingKeys: String, CodingKey {
            case dayOffset = "day_offset"
            case grade
        }
    }

    struct Expected: Decodable {
        let stability: Double
        let difficulty: Double
        let intervalDays: Int
        let state: String
        enum CodingKeys: String, CodingKey {
            case stability, difficulty, state
            case intervalDays = "interval_days"
        }
    }

    struct RetrievabilityCheck: Decodable {
        let afterStep: Int
        let elapsedDays: Double
        let expected: Double
        enum CodingKeys: String, CodingKey {
            case afterStep = "after_step"
            case elapsedDays = "elapsed_days"
            case expected
        }
    }

    struct GoldenCase: Decodable {
        let name: String
        let desiredRetention: Double
        let reviews: [Review]
        let expected: [Expected]
        let retrievabilityChecks: [RetrievabilityCheck]?
        enum CodingKeys: String, CodingKey {
            case name, reviews, expected
            case desiredRetention = "desired_retention"
            case retrievabilityChecks = "retrievability_checks"
        }
    }

    struct SeedCase: Decodable {
        let intervalDays: Int
        let easeFactor: Double
        let expectedStability: Double
        let expectedDifficulty: Double
        enum CodingKeys: String, CodingKey {
            case intervalDays = "interval_days"
            case easeFactor = "ease_factor"
            case expectedStability = "expected_stability"
            case expectedDifficulty = "expected_difficulty"
        }
    }

    struct GoldenFile: Decodable {
        let schema: String
        let scheduler: String
        let params: [Double]
        let cases: [GoldenCase]
        let sm2SeedCases: [SeedCase]
        enum CodingKeys: String, CodingKey {
            case schema, scheduler, params, cases
            case sm2SeedCases = "sm2_seed_cases"
        }
    }

    static let tolerance = 1e-6

    static func loadGolden() throws -> GoldenFile {
        let url = try #require(
            Bundle.module.url(forResource: "fsrs_golden_v1", withExtension: "json"),
            "Missing FSRS golden fixture"
        )
        return try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
    }

    static func grade(_ name: String) throws -> FSRS.Grade {
        switch name {
        case "again": return .again
        case "hard": return .hard
        case "good": return .good
        case "easy": return .easy
        default: throw NSError(domain: "unknown grade \(name)", code: 1)
        }
    }

    @Test func fixtureMatchesEngineConstants() throws {
        let golden = try Self.loadGolden()
        #expect(golden.schema == "melingo-fsrs-golden-v1")
        #expect(golden.scheduler == FSRS.schedulerVersion)
        #expect(golden.params == FSRS.defaultParams)
    }

    @Test func goldenCasesPass() throws {
        let golden = try Self.loadGolden()
        #expect(!golden.cases.isEmpty)

        for testCase in golden.cases {
            var stability = 0.0
            var difficulty = 0.0
            var lastOffset: Int?
            var stepStabilities: [Double] = []

            for (step, (review, expected)) in zip(testCase.reviews, testCase.expected).enumerated() {
                let elapsed = lastOffset.map { review.dayOffset - $0 } ?? 0
                let update = try FSRS.nextReview(
                    stability: stability,
                    difficulty: difficulty,
                    elapsedDays: elapsed,
                    grade: Self.grade(review.grade),
                    desiredRetention: testCase.desiredRetention
                )
                let ctx = "case '\(testCase.name)' step \(step)"
                #expect(abs(update.stability - expected.stability) < Self.tolerance, "\(ctx): S")
                #expect(abs(update.difficulty - expected.difficulty) < Self.tolerance, "\(ctx): D")
                #expect(update.intervalDays == expected.intervalDays, "\(ctx): interval")
                #expect(update.state.rawValue == expected.state, "\(ctx): state")

                stability = update.stability
                difficulty = update.difficulty
                lastOffset = review.dayOffset
                stepStabilities.append(stability)
            }

            for check in testCase.retrievabilityChecks ?? [] {
                let r = FSRS.retrievability(
                    stability: stepStabilities[check.afterStep], elapsedDays: check.elapsedDays)
                #expect(abs(r - check.expected) < Self.tolerance)
            }
        }
    }

    @Test func sm2SeedCasesPass() throws {
        let golden = try Self.loadGolden()
        for seedCase in golden.sm2SeedCases {
            let seeded = FSRS.seedFromSM2(
                intervalDays: seedCase.intervalDays, easeFactor: seedCase.easeFactor)
            #expect(abs(seeded.stability - seedCase.expectedStability) < Self.tolerance)
            #expect(abs(seeded.difficulty - seedCase.expectedDifficulty) < Self.tolerance)
        }
    }

    @Test func retrievabilityBoundaries() {
        #expect(FSRS.retrievability(stability: 2.3065, elapsedDays: 0) == 1.0)
        #expect(FSRS.retrievability(stability: 0, elapsedDays: 5) == 0.0)
    }
}
