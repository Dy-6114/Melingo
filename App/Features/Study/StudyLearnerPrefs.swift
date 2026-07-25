import Foundation
import Domain

/// Learner CEFR + study caches in UserDefaults (avoids SwiftData migration).
enum StudyLearnerPrefs {
    private static let cefrKey = "study.learnerCEFR"
    private static let contextsKey = "study.contextSentences"
    private static let ignoreAccentsKey = "study.ignoreAccents"
    private static let reviewContextKey = "study.reviewLastContext"
    private static let productionPassKey = "study.productionPassDays"
    private static let productionPassIDsKey = "study.productionPassCardIDs"

    static let cefrLevels = ["A1", "A2", "B1", "B2", "C1"]

    /// Default A2 — useful for most Melingo readers without onboarding friction.
    static var learnerCEFR: String {
        get {
            let raw = UserDefaults.standard.string(forKey: cefrKey) ?? "A2"
            return cefrLevels.contains(raw) ? raw : "A2"
        }
        set {
            let value = cefrLevels.contains(newValue) ? newValue : "A2"
            UserDefaults.standard.set(value, forKey: cefrKey)
        }
    }

    /// Opt-in: treat é≈e. Off by default so FR accents stay pedagogically meaningful.
    static var ignoreAccents: Bool {
        get { UserDefaults.standard.bool(forKey: ignoreAccentsKey) }
        set { UserDefaults.standard.set(newValue, forKey: ignoreAccentsKey) }
    }

    // MARK: - Review prompt direction (L2↔L1)

    enum ReviewDirection: String, CaseIterable, Identifiable {
        /// Front = study word, back = native meaning.
        case recognition
        /// Front = native meaning, back = study word.
        case production
        /// Mix both within a session (~45% production).
        case mix

        var id: String { rawValue }
    }

    private static let reviewDirectionKey = "study.reviewDirection"

    /// Default mix — recognition + production without twin cards at creation time.
    static var reviewDirection: ReviewDirection {
        get {
            let raw = UserDefaults.standard.string(forKey: reviewDirectionKey) ?? ReviewDirection.mix.rawValue
            return ReviewDirection(rawValue: raw) ?? .mix
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: reviewDirectionKey) }
    }

    /// Whether this due card should show L1→L2 (produce the study word).
    static func shouldPromptProduction(for cardID: UUID) -> Bool {
        switch reviewDirection {
        case .recognition: return false
        case .production: return true
        case .mix:
            var hasher = Hasher()
            hasher.combine(cardID)
            hasher.combine(LocalCalendarDate.string())
            // ~45% production so most cards stay recognition, but both appear often.
            return abs(hasher.finalize() % 100) < 45
        }
    }

    /// Prompt snippet injected into every study generation call.
    static var cefrPromptClause: String {
        let level = learnerCEFR
        switch level {
        case "A1":
            return """
            Learner CEFR: A1. Max 8–10 words per sentence. Present tense preferred. \
            No subjunctive, passé simple, or literary register. Everyday vocabulary only.
            """
        case "A2":
            return """
            Learner CEFR: A2. Max 12 words. Present / passé composé preferred. \
            No subjunctive / literary register.
            """
        case "B1":
            return """
            Learner CEFR: B1. Natural spoken register OK. Avoid rare idioms and literary tense.
            """
        case "B2":
            return """
            Learner CEFR: B2. Natural adult speech; mild idioms OK. Still prefer common collocations.
            """
        default:
            return "Learner CEFR: \(level). Prefer clear, attested, high-frequency language."
        }
    }

    /// Shared grammar-quality clause for generated L2 content.
    static var grammarGuardClause: String {
        """
        Generated text MUST be grammatically correct native \( "L2" ). \
        Double-check gender, number, articles, and verb agreement before answering. \
        Prefer high-frequency vocabulary. If unsure of a form, choose a simpler correct sentence.
        """
    }

    // MARK: - Rotating context sentences per card

    static func cachedContexts(for cardID: UUID) -> [String] {
        dictionary()[cardID.uuidString] ?? []
    }

    static func rememberContext(_ sentence: String, for cardID: UUID, limit: Int = 3) {
        var dict = dictionary()
        var list = dict[cardID.uuidString] ?? []
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        list.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
        list.insert(cleaned, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        dict[cardID.uuidString] = list
        UserDefaults.standard.set(dict, forKey: contextsKey)
    }

    /// Prefer a cached sentence that isn't the last one shown (rotation).
    static func pickRotatedContext(for cardID: UUID, excluding last: String?) -> String? {
        let list = cachedContexts(for: cardID)
        guard !list.isEmpty else { return nil }
        if list.count == 1 { return list[0] }
        if let last, let idx = list.firstIndex(where: { $0 == last }) {
            return list[(idx + 1) % list.count]
        }
        return list.randomElement()
    }

    static func lastReviewContext(for cardID: UUID) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: reviewContextKey) as? [String: String]
        return map?[cardID.uuidString]
    }

    static func setLastReviewContext(_ sentence: String, for cardID: UUID) {
        var map = (UserDefaults.standard.dictionary(forKey: reviewContextKey) as? [String: String]) ?? [:]
        map[cardID.uuidString] = sentence
        UserDefaults.standard.set(map, forKey: reviewContextKey)
    }

    // MARK: - Active production tracking (7-day window)

    static func recordProductionPass(cardID: UUID, on day: String = todayKey()) {
        var days = (UserDefaults.standard.dictionary(forKey: productionPassKey) as? [String: Int]) ?? [:]
        days[day, default: 0] += 1
        // Drop older than 14 days of keys.
        let keep = Set(lastNDays(7) + lastNDays(14))
        days = days.filter { keep.contains($0.key) }
        UserDefaults.standard.set(days, forKey: productionPassKey)

        var ids = (UserDefaults.standard.dictionary(forKey: productionPassIDsKey) as? [String: [String]]) ?? [:]
        var list = ids[day] ?? []
        let id = cardID.uuidString
        if !list.contains(id) { list.append(id) }
        ids[day] = list
        ids = ids.filter { keep.contains($0.key) }
        UserDefaults.standard.set(ids, forKey: productionPassIDsKey)
    }

    static func productionPassesLast7Days() -> Int {
        let days = lastNDays(7)
        let map = (UserDefaults.standard.dictionary(forKey: productionPassKey) as? [String: Int]) ?? [:]
        return days.reduce(0) { $0 + (map[$1] ?? 0) }
    }

    static func uniqueProductionCardsLast7Days() -> Int {
        let days = lastNDays(7)
        let map = (UserDefaults.standard.dictionary(forKey: productionPassIDsKey) as? [String: [String]]) ?? [:]
        var set = Set<String>()
        for d in days { set.formUnion(map[d] ?? []) }
        return set.count
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func lastNDays(_ n: Int) -> [String] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        return (0..<n).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return f.string(from: d)
        }
    }

    private static func dictionary() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: contextsKey) as? [String: [String]]) ?? [:]
    }
}
