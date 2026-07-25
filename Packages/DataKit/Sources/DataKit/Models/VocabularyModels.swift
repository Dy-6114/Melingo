import Foundation
import SwiftData
import Domain

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
    /// Shared id for forward/reverse twin cards created together.
    var pairID: UUID?
    /// `forward` (L2→L1 recognition) or `reverse` (L1→L2 production).
    var directionRaw: String?
    /// Lowercased/trimmed word for dedupe lookups.
    var normalizedWord: String?

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
        meaningEditedManually: Bool = false,
        pairID: UUID? = nil,
        directionRaw: String? = nil,
        normalizedWord: String? = nil
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
        self.pairID = pairID
        self.directionRaw = directionRaw
        self.normalizedWord = normalizedWord
    }
}

@Model
final class WordPackModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var packDescription: String?
    var sourceLanguage: String?
    var targetLanguage: String?
    var isSystem: Bool
    var kindRaw: String
    var coverRelativePath: String?
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        packDescription: String?,
        sourceLanguage: String?,
        targetLanguage: String?,
        isSystem: Bool,
        kindRaw: String = WordPackKind.learningPack.rawValue,
        coverRelativePath: String? = nil,
        isPinned: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.packDescription = packDescription
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.isSystem = isSystem
        self.kindRaw = kindRaw
        self.coverRelativePath = coverRelativePath
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ReviewEventModel {
    @Attribute(.unique) var id: UUID
    var vocabularyID: UUID
    var reviewedAt: Date
    var dateLocal: String
    var grade: Int

    init(
        id: UUID,
        vocabularyID: UUID,
        reviewedAt: Date,
        dateLocal: String,
        grade: Int
    ) {
        self.id = id
        self.vocabularyID = vocabularyID
        self.reviewedAt = reviewedAt
        self.dateLocal = dateLocal
        self.grade = grade
    }
}
