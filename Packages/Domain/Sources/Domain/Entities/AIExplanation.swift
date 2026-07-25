import Foundation

public struct VocabularyItem: Codable, Sendable, Hashable {
    public var word: String
    public var meaning: String
    public var usage: String?
    public var example: String?
    public var reading: String?

    public init(
        word: String,
        meaning: String,
        usage: String? = nil,
        example: String? = nil,
        reading: String? = nil
    ) {
        self.word = word
        self.meaning = meaning
        self.usage = usage
        self.example = example
        self.reading = reading
    }
}

public struct GrammarNote: Codable, Sendable, Hashable {
    public var point: String
    public var explanation: String
    public var example: String?

    public init(point: String, explanation: String, example: String? = nil) {
        self.point = point
        self.explanation = explanation
        self.example = example
    }
}

public struct GrammarBreakdown: Codable, Sendable, Hashable {
    public var translation: String
    public var summary: String
    /// Full-sentence reading line (furigana / kana / pinyin), shown above the original.
    public var readingText: String?
    public var notes: [GrammarNote]
    public var vocabulary: [VocabularyItem]
    public var culturalContext: String?
    public var difficultyLevel: String?
    public var learningTips: String?

    public init(
        translation: String,
        summary: String,
        readingText: String? = nil,
        notes: [GrammarNote] = [],
        vocabulary: [VocabularyItem] = [],
        culturalContext: String? = nil,
        difficultyLevel: String? = nil,
        learningTips: String? = nil
    ) {
        self.translation = translation
        self.summary = summary
        self.readingText = readingText
        self.notes = notes
        self.vocabulary = vocabulary
        self.culturalContext = culturalContext
        self.difficultyLevel = difficultyLevel
        self.learningTips = learningTips
    }
}

/// Provenance so cached explanations can be invalidated when inputs change.
public struct ExplanationMeta: Codable, Sendable, Hashable {
    public var targetLanguage: String
    public var providerID: String
    public var modelID: String
    public var promptVersion: String
    public var generatedAt: Date
    public var sourceTextHash: String

    public init(
        targetLanguage: String,
        providerID: String,
        modelID: String,
        promptVersion: String,
        generatedAt: Date,
        sourceTextHash: String
    ) {
        self.targetLanguage = targetLanguage
        self.providerID = providerID
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
        self.sourceTextHash = sourceTextHash
    }
}

public struct AIExplanation: Codable, Sendable, Hashable {
    public var breakdown: GrammarBreakdown
    public var meta: ExplanationMeta?

    public init(breakdown: GrammarBreakdown, meta: ExplanationMeta? = nil) {
        self.breakdown = breakdown
        self.meta = meta
    }
}

public struct AIAnswer: Codable, Sendable, Hashable {
    public var text: String
    public var meta: ExplanationMeta?

    public init(text: String, meta: ExplanationMeta? = nil) {
        self.text = text
        self.meta = meta
    }
}
