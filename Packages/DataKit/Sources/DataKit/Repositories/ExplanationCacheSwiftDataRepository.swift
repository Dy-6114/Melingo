import Foundation
import SwiftData
import Domain

@ModelActor
public actor ExplanationCacheSwiftDataRepository: ExplanationCacheRepository {
    public func explanation(forKey key: ExplanationCacheKey) async throws -> AIExplanation? {
        let hash = key.sourceTextHash
        let language = key.targetLanguage
        let prompt = key.promptVersion
        let provider = key.providerID

        let rows: [ExplanationCacheModel]
        if let provider {
            rows = try modelContext.fetch(
                FetchDescriptor<ExplanationCacheModel>(
                    predicate: #Predicate {
                        $0.sourceTextHash == hash
                            && $0.targetLanguage == language
                            && $0.promptVersion == prompt
                            && $0.providerID == provider
                    }
                )
            )
        } else {
            rows = try modelContext.fetch(
                FetchDescriptor<ExplanationCacheModel>(
                    predicate: #Predicate {
                        $0.sourceTextHash == hash
                            && $0.targetLanguage == language
                            && $0.promptVersion == prompt
                            && $0.providerID == nil
                    }
                )
            )
        }

        guard let model = rows.first else { return nil }
        do {
            return try JSONDecoder().decode(AIExplanation.self, from: model.payloadJSON)
        } catch {
            throw DataPersistenceError.decodingFailed
        }
    }

    public func store(_ explanation: AIExplanation, forKey key: ExplanationCacheKey) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(explanation)
        } catch {
            throw DataPersistenceError.encodingFailed
        }

        let hash = key.sourceTextHash
        let language = key.targetLanguage
        let prompt = key.promptVersion
        let provider = key.providerID
        let existing: [ExplanationCacheModel]
        if let provider {
            existing = try modelContext.fetch(
                FetchDescriptor<ExplanationCacheModel>(
                    predicate: #Predicate {
                        $0.sourceTextHash == hash
                            && $0.targetLanguage == language
                            && $0.promptVersion == prompt
                            && $0.providerID == provider
                    }
                )
            )
        } else {
            existing = try modelContext.fetch(
                FetchDescriptor<ExplanationCacheModel>(
                    predicate: #Predicate {
                        $0.sourceTextHash == hash
                            && $0.targetLanguage == language
                            && $0.promptVersion == prompt
                            && $0.providerID == nil
                    }
                )
            )
        }
        for row in existing {
            modelContext.delete(row)
        }

        modelContext.insert(
            ExplanationCacheModel(
                sourceTextHash: key.sourceTextHash,
                targetLanguage: key.targetLanguage,
                promptVersion: key.promptVersion,
                providerID: key.providerID,
                payloadJSON: data
            )
        )
        try modelContext.save()
    }

    public func invalidate(matching sourceTextHash: String) async throws {
        let hash = sourceTextHash
        let rows = try modelContext.fetch(
            FetchDescriptor<ExplanationCacheModel>(
                predicate: #Predicate { $0.sourceTextHash == hash }
            )
        )
        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
