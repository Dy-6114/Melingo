import Foundation
import Domain

public actor MockVocabularyRepository: VocabularyRepository {
    public var entries: [VocabularyEntry] = []
    public var packs: [WordPack] = []
    public var reviews: [ReviewResult] = []

    public init() {}

    public func fetchEntries(for language: LanguagePair) async throws -> [VocabularyEntry] {
        entries.filter { $0.languagePair == language }
    }

    public func upsert(_ entry: VocabularyEntry) async throws {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
    }

    public func delete(_ entryID: VocabularyEntry.ID) async throws {
        entries.removeAll { $0.id == entryID }
    }

    public func applyReview(_ entry: VocabularyEntry, result: ReviewResult) async throws {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        reviews.append(result)
    }

    public func fetchReviewEvents(
        for vocabularyID: VocabularyEntry.ID,
        limit: Int
    ) async throws -> [ReviewResult] {
        Array(
            reviews
                .filter { $0.vocabularyID == vocabularyID }
                .sorted { $0.reviewedAt > $1.reviewedAt }
                .prefix(max(1, limit))
        )
    }

    public func fetchPacks() async throws -> [WordPack] {
        packs
    }

    public func upsertPack(_ pack: WordPack) async throws {
        packs.removeAll { $0.id == pack.id }
        packs.append(pack)
    }

    public func deletePack(_ packID: WordPack.ID) async throws {
        packs.removeAll { $0.id == packID }
    }

    public func deletePackRemovingCards(_ packID: WordPack.ID) async throws {
        for i in entries.indices.reversed() {
            if entries[i].packIDs.contains(packID) {
                entries[i].packIDs.removeAll { $0 == packID }
                if entries[i].packIDs.isEmpty {
                    entries.remove(at: i)
                }
            }
        }
        packs.removeAll { $0.id == packID }
    }
}
