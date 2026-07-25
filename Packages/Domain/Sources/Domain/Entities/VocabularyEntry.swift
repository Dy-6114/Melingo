import Foundation

public enum SRSState: String, Codable, Sendable {
    case new
    case learning
    case review
}

/// Recognition (L2→L1) vs production (L1→L2) for twin cards sharing a `pairID`.
public enum CardDirection: String, Codable, Sendable, Hashable {
    case forward
    case reverse
}

/// Saved vocabulary card with FSRS scheduling fields (aligned with iOS/desktop SRS).
public struct VocabularyEntry: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var word: String
    public var meaning: String
    public var usage: String?
    public var explanation: String?
    public var example: String?
    public var reading: String?
    public var sourceDocumentID: Document.ID?
    public var sourceDocumentTitle: String?
    public var languagePair: LanguagePair
    public var packIDs: [UUID]
    public var srsState: SRSState
    public var stability: Double
    public var difficulty: Double
    public var schedulerVersion: String?
    public var suspendedAt: Date?
    /// Local calendar date "YYYY-MM-DD".
    public var dueDate: String
    public var lastReviewedAt: Date?
    public var reviewCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Relative path under `~/Documents/Melingo` for user-recorded pronunciation.
    public var audioRelativePath: String?
    /// When true, auto-translate must not overwrite `meaning`.
    public var meaningEditedManually: Bool
    /// Shared by forward/reverse twins created together (`alsoCreateReverse`).
    public var pairID: UUID?
    public var direction: CardDirection?
    /// Lowercased/trimmed `word` for dedupe; maintained on upsert.
    public var normalizedWord: String?

    public init(
        id: UUID = UUID(),
        word: String,
        meaning: String,
        usage: String? = nil,
        explanation: String? = nil,
        example: String? = nil,
        reading: String? = nil,
        sourceDocumentID: Document.ID? = nil,
        sourceDocumentTitle: String? = nil,
        languagePair: LanguagePair,
        packIDs: [UUID] = [],
        srsState: SRSState = .new,
        stability: Double = 0,
        difficulty: Double = 0,
        schedulerVersion: String? = "fsrs6",
        suspendedAt: Date? = nil,
        dueDate: String = "",
        lastReviewedAt: Date? = nil,
        reviewCount: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        audioRelativePath: String? = nil,
        meaningEditedManually: Bool = false,
        pairID: UUID? = nil,
        direction: CardDirection? = nil,
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
        self.languagePair = languagePair
        self.packIDs = packIDs
        self.srsState = srsState
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
        self.direction = direction
        self.normalizedWord = normalizedWord ?? Self.normalizeWord(word)
    }

    public static func normalizeWord(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum WordPackKind: String, Codable, Sendable, Hashable {
    case tag
    case learningPack
}

public struct WordPack: Codable, Identifiable, Sendable, Hashable {
    public static let systemUngroupedID = UUID(uuidString: "00000000-0000-4000-8000-0000756E6772")!

    public var id: UUID
    public var name: String
    public var packDescription: String?
    public var languagePair: LanguagePair?
    public var isSystem: Bool
    public var kind: WordPackKind
    public var coverRelativePath: String?
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        packDescription: String? = nil,
        languagePair: LanguagePair? = nil,
        isSystem: Bool = false,
        kind: WordPackKind = .learningPack,
        coverRelativePath: String? = nil,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.packDescription = packDescription
        self.languagePair = languagePair
        self.isSystem = isSystem
        self.kind = kind
        self.coverRelativePath = coverRelativePath
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Review grade: 1=Again, 2=Hard, 3=Good, 4=Easy.
public struct ReviewResult: Codable, Sendable, Hashable {
    public var vocabularyID: VocabularyEntry.ID
    public var grade: Int
    public var reviewedAt: Date

    public init(vocabularyID: VocabularyEntry.ID, grade: Int, reviewedAt: Date = .now) {
        self.vocabularyID = vocabularyID
        self.grade = grade
        self.reviewedAt = reviewedAt
    }
}

/// Draft card used by AI pack generate / JSON import before persistence.
public struct PackCardDraft: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var term: String
    public var translation: String
    public var context: String?

    public init(
        id: UUID = UUID(),
        term: String,
        translation: String,
        context: String? = nil
    ) {
        self.id = id
        self.term = term
        self.translation = translation
        self.context = context
    }
}

public struct PackImportDraft: Codable, Sendable, Hashable {
    public var title: String
    public var description: String
    public var cards: [PackCardDraft]

    public init(title: String, description: String = "", cards: [PackCardDraft]) {
        self.title = title
        self.description = description
        self.cards = cards
    }
}
