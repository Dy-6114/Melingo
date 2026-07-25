import Foundation
import SwiftData

@Model
final class DocumentModel {
    @Attribute(.unique) var id: UUID
    var title: String
    var sourceKindRaw: String
    var sourceURL: String?
    var storedFileRelativePath: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TextSegmentModel.document)
    var segments: [TextSegmentModel]

    init(
        id: UUID,
        title: String,
        sourceKindRaw: String,
        sourceURL: String?,
        storedFileRelativePath: String?,
        createdAt: Date,
        updatedAt: Date,
        segments: [TextSegmentModel] = []
    ) {
        self.id = id
        self.title = title
        self.sourceKindRaw = sourceKindRaw
        self.sourceURL = sourceURL
        self.storedFileRelativePath = storedFileRelativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.segments = segments
    }
}

@Model
final class TextSegmentModel {
    @Attribute(.unique) var id: UUID
    var order: Int
    var text: String
    var readingText: String?
    var translation: String?
    var explanation: String?
    var isNewParagraph: Bool
    var createdAt: Date
    var document: DocumentModel?

    init(
        id: UUID,
        order: Int,
        text: String,
        readingText: String?,
        translation: String?,
        explanation: String? = nil,
        isNewParagraph: Bool,
        createdAt: Date,
        document: DocumentModel? = nil
    ) {
        self.id = id
        self.order = order
        self.text = text
        self.readingText = readingText
        self.translation = translation
        self.explanation = explanation
        self.isNewParagraph = isNewParagraph
        self.createdAt = createdAt
        self.document = document
    }
}
