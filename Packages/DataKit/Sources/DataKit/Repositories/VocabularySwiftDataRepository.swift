import Foundation
import SwiftData
import Domain

@ModelActor
public actor VocabularySwiftDataRepository: VocabularyRepository {
    public func fetchEntries(for language: LanguagePair) async throws -> [VocabularyEntry] {
        let source = language.source
        let target = language.target
        let descriptor = FetchDescriptor<VocabularyEntryModel>(
            predicate: #Predicate {
                $0.sourceLanguage == source && $0.targetLanguage == target
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(VocabularyMapper.toEntity)
    }

    public func upsert(_ entry: VocabularyEntry) async throws {
        let entryID = entry.id
        var descriptor = FetchDescriptor<VocabularyEntryModel>(
            predicate: #Predicate { $0.id == entryID }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            VocabularyMapper.apply(entry, to: existing)
        } else {
            modelContext.insert(VocabularyMapper.makeModel(from: entry))
        }
        try modelContext.save()
    }

    public func delete(_ entryID: VocabularyEntry.ID) async throws {
        var descriptor = FetchDescriptor<VocabularyEntryModel>(
            predicate: #Predicate { $0.id == entryID }
        )
        descriptor.fetchLimit = 1
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    public func applyReview(_ entry: VocabularyEntry, result: ReviewResult) async throws {
        let vocabularyID = entry.id
        var descriptor = FetchDescriptor<VocabularyEntryModel>(
            predicate: #Predicate { $0.id == vocabularyID }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw DataPersistenceError.notFound
        }

        VocabularyMapper.apply(entry, to: model)

        let event = ReviewEventModel(
            id: UUID(),
            vocabularyID: result.vocabularyID,
            reviewedAt: result.reviewedAt,
            dateLocal: LocalDateFormatting.string(from: result.reviewedAt),
            grade: result.grade
        )
        modelContext.insert(event)
        try modelContext.save()
    }

    public func fetchReviewEvents(
        for vocabularyID: VocabularyEntry.ID,
        limit: Int
    ) async throws -> [ReviewResult] {
        var descriptor = FetchDescriptor<ReviewEventModel>(
            predicate: #Predicate { $0.vocabularyID == vocabularyID },
            sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try modelContext.fetch(descriptor).map {
            ReviewResult(vocabularyID: $0.vocabularyID, grade: $0.grade, reviewedAt: $0.reviewedAt)
        }
    }

    public func fetchPacks() async throws -> [WordPack] {
        let descriptor = FetchDescriptor<WordPackModel>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try modelContext.fetch(descriptor).map(WordPackMapper.toEntity)
    }

    public func upsertPack(_ pack: WordPack) async throws {
        let packID = pack.id
        var descriptor = FetchDescriptor<WordPackModel>(
            predicate: #Predicate { $0.id == packID }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            WordPackMapper.apply(pack, to: existing)
        } else {
            modelContext.insert(WordPackMapper.makeModel(from: pack))
        }
        try modelContext.save()
    }

    public func deletePack(_ packID: WordPack.ID) async throws {
        var descriptor = FetchDescriptor<WordPackModel>(
            predicate: #Predicate { $0.id == packID }
        )
        descriptor.fetchLimit = 1
        if let model = try modelContext.fetch(descriptor).first {
            modelContext.delete(model)
            try modelContext.save()
        }
    }

    public func deletePackRemovingCards(_ packID: WordPack.ID) async throws {
        let allEntries = try modelContext.fetch(FetchDescriptor<VocabularyEntryModel>())
        for model in allEntries {
            var ids = UUIDListCoder.decode(model.packIDsData)
            guard ids.contains(packID) else { continue }
            ids.removeAll { $0 == packID }
            // Delete card if it no longer belongs to any pack, or only had this learning pack.
            if ids.isEmpty {
                modelContext.delete(model)
            } else {
                model.packIDsData = UUIDListCoder.encode(ids)
                model.updatedAt = .now
            }
        }
        try await deletePack(packID)
    }
}
