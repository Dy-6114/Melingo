import Foundation
import SwiftData

/// On-disk schema V1 (frozen). Nested vocab model matches the pre-pairID shape so
/// existing 1.3.0 stores keep a distinct checksum from V2.
enum MelingoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 3, 0)

    static var models: [any PersistentModel.Type] {
        [
            DocumentModel.self,
            TextSegmentModel.self,
            VocabularyEntryModel.self, // MelingoSchemaV1.VocabularyEntryModel (frozen)
            WordPackModel.self,
            ReviewEventModel.self,
            ReadingSessionModel.self,
            UserProfileModel.self,
            ExplanationCacheModel.self,
        ]
    }

    /// Frozen V1 vocabulary row (no twin / normalized fields).
    @Model
    final class VocabularyEntryModel {
        @Attribute(.unique) var id: UUID
        var word: String
        var meaning: String
        var usage: String?
        var explanation: String?
        var example: String?
        var reading: String?
        var sourceDocumentID: UUID?
        var sourceDocumentTitle: String?
        var sourceLanguage: String
        var targetLanguage: String
        var packIDsData: Data
        var srsStateRaw: String
        var stability: Double
        var difficulty: Double
        var schedulerVersion: String?
        var suspendedAt: Date?
        var dueDate: String
        var lastReviewedAt: Date?
        var reviewCount: Int
        var createdAt: Date
        var updatedAt: Date
        var audioRelativePath: String?
        var meaningEditedManually: Bool

        init(
            id: UUID,
            word: String,
            meaning: String,
            usage: String?,
            explanation: String?,
            example: String?,
            reading: String?,
            sourceDocumentID: UUID?,
            sourceDocumentTitle: String?,
            sourceLanguage: String,
            targetLanguage: String,
            packIDsData: Data,
            srsStateRaw: String,
            stability: Double,
            difficulty: Double,
            schedulerVersion: String?,
            suspendedAt: Date?,
            dueDate: String,
            lastReviewedAt: Date?,
            reviewCount: Int,
            createdAt: Date,
            updatedAt: Date,
            audioRelativePath: String? = nil,
            meaningEditedManually: Bool = false
        ) {
            self.id = id
            self.word = word
            self.meaning = meaning
            self.usage = usage
            self.explanation = explanation
            self.example = example
            self.reading = reading
            self.sourceDocumentID = sourceDocumentID
            self.sourceDocumentTitle = sourceDocumentTitle
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.packIDsData = packIDsData
            self.srsStateRaw = srsStateRaw
            self.stability = stability
            self.difficulty = difficulty
            self.schedulerVersion = schedulerVersion
            self.suspendedAt = suspendedAt
            self.dueDate = dueDate
            self.lastReviewedAt = lastReviewedAt
            self.reviewCount = reviewCount
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.audioRelativePath = audioRelativePath
            self.meaningEditedManually = meaningEditedManually
        }
    }
}

/// Current schema — includes twin-card linking fields on vocabulary.
enum MelingoSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 4, 0)

    static var models: [any PersistentModel.Type] {
        [
            DocumentModel.self,
            TextSegmentModel.self,
            VocabularyEntryModel.self,
            WordPackModel.self,
            ReviewEventModel.self,
            ReadingSessionModel.self,
            UserProfileModel.self,
            ExplanationCacheModel.self,
        ]
    }
}

enum MelingoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MelingoSchemaV1.self, MelingoSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: MelingoSchemaV1.self,
        toVersion: MelingoSchemaV2.self
    )
}
