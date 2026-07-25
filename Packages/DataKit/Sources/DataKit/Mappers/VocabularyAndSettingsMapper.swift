import Foundation
import Domain

enum VocabularyMapper {
    static func toEntity(_ model: VocabularyEntryModel) -> VocabularyEntry {
        VocabularyEntry(
            id: model.id,
            word: model.word,
            meaning: model.meaning,
            usage: model.usage,
            explanation: model.explanation,
            example: model.example,
            reading: model.reading,
            sourceDocumentID: model.sourceDocumentID,
            sourceDocumentTitle: model.sourceDocumentTitle,
            languagePair: LanguagePair(source: model.sourceLanguage, target: model.targetLanguage),
            packIDs: UUIDListCoder.decode(model.packIDsData),
            srsState: SRSState(rawValue: model.srsStateRaw) ?? .new,
            stability: model.stability,
            difficulty: model.difficulty,
            schedulerVersion: model.schedulerVersion,
            suspendedAt: model.suspendedAt,
            dueDate: model.dueDate,
            lastReviewedAt: model.lastReviewedAt,
            reviewCount: model.reviewCount,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt,
            audioRelativePath: model.audioRelativePath,
            meaningEditedManually: model.meaningEditedManually,
            pairID: model.pairID,
            direction: model.directionRaw.flatMap(CardDirection.init(rawValue:)),
            normalizedWord: model.normalizedWord
        )
    }

    static func makeModel(from entity: VocabularyEntry) -> VocabularyEntryModel {
        VocabularyEntryModel(
            id: entity.id,
            word: entity.word,
            meaning: entity.meaning,
            usage: entity.usage,
            explanation: entity.explanation,
            example: entity.example,
            reading: entity.reading,
            sourceDocumentID: entity.sourceDocumentID,
            sourceDocumentTitle: entity.sourceDocumentTitle,
            sourceLanguage: entity.languagePair.source,
            targetLanguage: entity.languagePair.target,
            packIDsData: UUIDListCoder.encode(entity.packIDs),
            srsStateRaw: entity.srsState.rawValue,
            stability: entity.stability,
            difficulty: entity.difficulty,
            schedulerVersion: entity.schedulerVersion,
            suspendedAt: entity.suspendedAt,
            dueDate: entity.dueDate,
            lastReviewedAt: entity.lastReviewedAt,
            reviewCount: entity.reviewCount,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            audioRelativePath: entity.audioRelativePath,
            meaningEditedManually: entity.meaningEditedManually,
            pairID: entity.pairID,
            directionRaw: entity.direction?.rawValue,
            normalizedWord: entity.normalizedWord ?? VocabularyEntry.normalizeWord(entity.word)
        )
    }

    static func apply(_ entity: VocabularyEntry, to model: VocabularyEntryModel) {
        model.word = entity.word
        model.meaning = entity.meaning
        model.usage = entity.usage
        model.explanation = entity.explanation
        model.example = entity.example
        model.reading = entity.reading
        model.sourceDocumentID = entity.sourceDocumentID
        model.sourceDocumentTitle = entity.sourceDocumentTitle
        model.sourceLanguage = entity.languagePair.source
        model.targetLanguage = entity.languagePair.target
        model.packIDsData = UUIDListCoder.encode(entity.packIDs)
        model.srsStateRaw = entity.srsState.rawValue
        model.stability = entity.stability
        model.difficulty = entity.difficulty
        model.schedulerVersion = entity.schedulerVersion
        model.suspendedAt = entity.suspendedAt
        model.dueDate = entity.dueDate
        model.lastReviewedAt = entity.lastReviewedAt
        model.reviewCount = entity.reviewCount
        model.createdAt = entity.createdAt
        model.updatedAt = entity.updatedAt
        model.audioRelativePath = entity.audioRelativePath
        model.meaningEditedManually = entity.meaningEditedManually
        model.pairID = entity.pairID
        model.directionRaw = entity.direction?.rawValue
        model.normalizedWord = entity.normalizedWord ?? VocabularyEntry.normalizeWord(entity.word)
    }
}

enum WordPackMapper {
    static func toEntity(_ model: WordPackModel) -> WordPack {
        let pair: LanguagePair? = {
            guard let s = model.sourceLanguage, let t = model.targetLanguage else { return nil }
            return LanguagePair(source: s, target: t)
        }()
        return WordPack(
            id: model.id,
            name: model.name,
            packDescription: model.packDescription,
            languagePair: pair,
            isSystem: model.isSystem,
            kind: WordPackKind(rawValue: model.kindRaw) ?? .learningPack,
            coverRelativePath: model.coverRelativePath,
            isPinned: model.isPinned,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }

    static func makeModel(from entity: WordPack) -> WordPackModel {
        WordPackModel(
            id: entity.id,
            name: entity.name,
            packDescription: entity.packDescription,
            sourceLanguage: entity.languagePair?.source,
            targetLanguage: entity.languagePair?.target,
            isSystem: entity.isSystem,
            kindRaw: entity.kind.rawValue,
            coverRelativePath: entity.coverRelativePath,
            isPinned: entity.isPinned,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        )
    }

    static func apply(_ entity: WordPack, to model: WordPackModel) {
        model.name = entity.name
        model.packDescription = entity.packDescription
        model.sourceLanguage = entity.languagePair?.source
        model.targetLanguage = entity.languagePair?.target
        model.isSystem = entity.isSystem
        model.kindRaw = entity.kind.rawValue
        model.coverRelativePath = entity.coverRelativePath
        model.isPinned = entity.isPinned
        model.updatedAt = entity.updatedAt
    }
}

enum ReadingSessionMapper {
    static func toEntity(_ model: ReadingSessionModel) -> ReadingSession {
        ReadingSession(
            id: model.id,
            documentID: model.documentID,
            dateLocal: model.dateLocal,
            startedAt: model.startedAt,
            seconds: model.seconds
        )
    }

    static func makeModel(from entity: ReadingSession) -> ReadingSessionModel {
        ReadingSessionModel(
            id: entity.id,
            documentID: entity.documentID,
            dateLocal: entity.dateLocal,
            startedAt: entity.startedAt,
            seconds: entity.seconds
        )
    }
}

enum UserProfileMapper {
    static func toEntity(_ model: UserProfileModel) -> UserProfile {
        UserProfile(
            preferredLanguagePair: LanguagePair(
                source: model.sourceLanguage,
                target: model.targetLanguage
            ),
            uiLocale: model.uiLocale,
            remoteAIEnabled: model.remoteAIEnabled,
            activeAIProviderID: model.activeAIProviderID,
            aiFallbackMode: AIFallbackMode(rawValue: model.aiFallbackModeRaw) ?? .offlineOnly,
            hasCompletedOnboarding: model.hasCompletedOnboarding,
            displayName: model.displayName,
            avatarRelativePath: model.avatarRelativePath
        )
    }

    static func apply(_ entity: UserProfile, to model: UserProfileModel) {
        model.sourceLanguage = entity.preferredLanguagePair.source
        model.targetLanguage = entity.preferredLanguagePair.target
        model.uiLocale = entity.uiLocale
        model.remoteAIEnabled = entity.remoteAIEnabled
        model.activeAIProviderID = entity.activeAIProviderID
        model.aiFallbackModeRaw = entity.aiFallbackMode.rawValue
        model.hasCompletedOnboarding = entity.hasCompletedOnboarding
        model.displayName = entity.displayName
        model.avatarRelativePath = entity.avatarRelativePath
    }

    static func makeModel(from entity: UserProfile) -> UserProfileModel {
        UserProfileModel(
            sourceLanguage: entity.preferredLanguagePair.source,
            targetLanguage: entity.preferredLanguagePair.target,
            uiLocale: entity.uiLocale,
            remoteAIEnabled: entity.remoteAIEnabled,
            activeAIProviderID: entity.activeAIProviderID,
            aiFallbackModeRaw: entity.aiFallbackMode.rawValue,
            hasCompletedOnboarding: entity.hasCompletedOnboarding,
            displayName: entity.displayName,
            avatarRelativePath: entity.avatarRelativePath
        )
    }
}
