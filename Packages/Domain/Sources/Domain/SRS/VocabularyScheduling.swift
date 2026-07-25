import Foundation

/// Shared calendar-date helpers for SRS due dates (`YYYY-MM-DD` local).
public enum LocalCalendarDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func string(from date: Date = .now) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

public enum VocabularyScheduling {
    public static let dailyNewLimit = 20
    public static let dailyReviewLimit = 200

    /// Days since last review (0 for brand-new cards with zero stability/difficulty).
    public static func elapsedDays(for entry: VocabularyEntry, reviewDate: Date = .now) -> Int {
        if entry.stability == 0, entry.difficulty == 0 { return 0 }
        guard let last = entry.lastReviewedAt else { return 0 }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: last)
        let to = calendar.startOfDay(for: reviewDate)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    public static func isDue(_ entry: VocabularyEntry, on date: Date = .now) -> Bool {
        guard entry.suspendedAt == nil else { return false }
        let today = LocalCalendarDate.string(from: date)
        if entry.dueDate.isEmpty { return entry.srsState == .new }
        return entry.dueDate <= today
    }

    /// New cards after overdue reviews: most overdue first, then oldest review, then new.
    public static func dueQueue(
        from entries: [VocabularyEntry],
        on date: Date = .now,
        newLimit: Int = dailyNewLimit,
        reviewLimit: Int = dailyReviewLimit
    ) -> [VocabularyEntry] {
        let due = entries.filter { isDue($0, on: date) }
        let reviews = due.filter { $0.srsState != .new }
            .sorted { lhs, rhs in
                // Most overdue first (earliest dueDate).
                if lhs.dueDate != rhs.dueDate { return lhs.dueDate < rhs.dueDate }
                // Then oldest review.
                let l = lhs.lastReviewedAt ?? .distantPast
                let r = rhs.lastReviewedAt ?? .distantPast
                return l < r
            }
            .prefix(reviewLimit)
        let news = due.filter { $0.srsState == .new }.prefix(newLimit)
        return Array(reviews) + Array(news)
    }

    public static func apply(
        _ update: FSRS.Update,
        to entry: VocabularyEntry,
        reviewedAt: Date = .now
    ) -> VocabularyEntry {
        var next = entry
        next.srsState = update.state
        next.stability = update.stability
        next.difficulty = update.difficulty
        next.schedulerVersion = FSRS.schedulerVersion
        let due = Calendar.current.date(byAdding: .day, value: update.intervalDays, to: reviewedAt)
            ?? reviewedAt
        next.dueDate = LocalCalendarDate.string(from: due)
        next.lastReviewedAt = reviewedAt
        next.reviewCount += 1
        next.updatedAt = reviewedAt
        return next
    }

    /// Approximate current retention for UI (memory-strength ring).
    public static func currentRetrievability(_ entry: VocabularyEntry, now: Date = .now) -> Double {
        if entry.stability <= 0 { return entry.srsState == .new ? 0 : 0.2 }
        let elapsed = Double(elapsedDays(for: entry, reviewDate: now))
        return FSRS.retrievability(stability: entry.stability, elapsedDays: elapsed)
    }
}
