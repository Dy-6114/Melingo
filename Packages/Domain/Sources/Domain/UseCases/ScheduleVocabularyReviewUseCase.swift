import Foundation

public struct ScheduleVocabularyReviewUseCase: Sendable {
    private let vocabulary: any VocabularyRepository
    private let desiredRetention: Double

    public init(
        vocabulary: any VocabularyRepository,
        desiredRetention: Double = FSRS.defaultDesiredRetention
    ) {
        self.vocabulary = vocabulary
        self.desiredRetention = desiredRetention
    }

    /// Applies FSRS-6, persists the updated card + immutable review event, returns the card.
    @discardableResult
    public func callAsFunction(
        _ entry: VocabularyEntry,
        grade: FSRS.Grade,
        now: Date = .now
    ) async throws -> VocabularyEntry {
        let elapsed = VocabularyScheduling.elapsedDays(for: entry, reviewDate: now)
        let update = try FSRS.nextReview(
            stability: entry.stability,
            difficulty: entry.difficulty,
            elapsedDays: elapsed,
            grade: grade,
            desiredRetention: desiredRetention
        )
        let scheduled = VocabularyScheduling.apply(update, to: entry, reviewedAt: now)
        let result = ReviewResult(vocabularyID: entry.id, grade: grade.rawValue, reviewedAt: now)
        try await vocabulary.applyReview(scheduled, result: result)
        return scheduled
    }
}
