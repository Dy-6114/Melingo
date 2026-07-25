import Foundation

/// Ordered sentence/paragraph unit within a document.
public struct TextSegment: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var documentID: Document.ID
    public var order: Int
    public var text: String
    /// Furigana / reading line (displayed separately, not ruby markup).
    public var readingText: String?
    public var translation: String?
    /// Grammar / explain summary from AI (presence marks the segment as explained).
    public var explanation: String?
    public var isNewParagraph: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        documentID: Document.ID,
        order: Int,
        text: String,
        readingText: String? = nil,
        translation: String? = nil,
        explanation: String? = nil,
        isNewParagraph: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.documentID = documentID
        self.order = order
        self.text = text
        self.readingText = readingText
        self.translation = translation
        self.explanation = explanation
        self.isNewParagraph = isNewParagraph
        self.createdAt = createdAt
    }
}

/// Context passed to AI when explaining a word or answering about selection.
public struct TextContext: Codable, Sendable, Hashable {
    public var segment: TextSegment
    public var documentTitle: String?
    public var languagePair: LanguagePair
    public var surroundingText: String?

    public init(
        segment: TextSegment,
        documentTitle: String? = nil,
        languagePair: LanguagePair,
        surroundingText: String? = nil
    ) {
        self.segment = segment
        self.documentTitle = documentTitle
        self.languagePair = languagePair
        self.surroundingText = surroundingText
    }
}
