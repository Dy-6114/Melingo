import Foundation
import Domain

/// Lab SRS knobs (UserDefaults) — Revu-style retention / queue caps without schema migration.
enum SRSPrefs {
    private static let retentionKey = "srs.desiredRetention"
    private static let newLimitKey = "srs.dailyNewLimit"
    private static let reviewLimitKey = "srs.dailyReviewLimit"

    /// FSRS target retention 0.70…0.97 (default 0.90).
    static var desiredRetention: Double {
        get {
            let raw = UserDefaults.standard.object(forKey: retentionKey) as? Double
            let value = raw ?? FSRS.defaultDesiredRetention
            return min(0.97, max(0.70, value))
        }
        set {
            UserDefaults.standard.set(min(0.97, max(0.70, newValue)), forKey: retentionKey)
        }
    }

    static var dailyNewLimit: Int {
        get {
            let v = UserDefaults.standard.object(forKey: newLimitKey) as? Int
            return min(100, max(1, v ?? VocabularyScheduling.dailyNewLimit))
        }
        set {
            UserDefaults.standard.set(min(100, max(1, newValue)), forKey: newLimitKey)
        }
    }

    static var dailyReviewLimit: Int {
        get {
            let v = UserDefaults.standard.object(forKey: reviewLimitKey) as? Int
            return min(500, max(10, v ?? VocabularyScheduling.dailyReviewLimit))
        }
        set {
            UserDefaults.standard.set(min(500, max(10, newValue)), forKey: reviewLimitKey)
        }
    }
}
