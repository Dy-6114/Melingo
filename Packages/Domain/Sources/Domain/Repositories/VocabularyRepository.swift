import Foundation

public protocol VocabularyRepository: Sendable {
    func fetchEntries(for language: LanguagePair) async throws -> [VocabularyEntry]
    func upsert(_ entry: VocabularyEntry) async throws
    func delete(_ entryID: VocabularyEntry.ID) async throws
    /// Persists an already-scheduled card plus an immutable review event.
    func applyReview(_ entry: VocabularyEntry, result: ReviewResult) async throws
    /// Recent grade events for a card (newest first).
    func fetchReviewEvents(for vocabularyID: VocabularyEntry.ID, limit: Int) async throws -> [ReviewResult]
    func fetchPacks() async throws -> [WordPack]
    func upsertPack(_ pack: WordPack) async throws
    func deletePack(_ packID: WordPack.ID) async throws
    /// Deletes the pack and cards whose only learning-pack membership is this pack.
    func deletePackRemovingCards(_ packID: WordPack.ID) async throws
}
