import Foundation
import Domain

enum UUIDListCoder {
    static func encode(_ ids: [UUID]) -> Data {
        (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [UUID] {
        (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }
}

enum LocalDateFormatting {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

enum DocumentMapper {
    static func toEntity(_ model: DocumentModel) -> Document {
        Document(
            id: model.id,
            title: model.title,
            sourceKind: DocumentSourceKind(rawValue: model.sourceKindRaw) ?? .plainText,
            sourceURL: model.sourceURL,
            storedFileRelativePath: model.storedFileRelativePath,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }

    static func apply(_ entity: Document, to model: DocumentModel) {
        model.title = entity.title
        model.sourceKindRaw = entity.sourceKind.rawValue
        model.sourceURL = entity.sourceURL
        model.storedFileRelativePath = entity.storedFileRelativePath
        model.createdAt = entity.createdAt
        model.updatedAt = entity.updatedAt
    }

    static func makeModel(from entity: Document) -> DocumentModel {
        DocumentModel(
            id: entity.id,
            title: entity.title,
            sourceKindRaw: entity.sourceKind.rawValue,
            sourceURL: entity.sourceURL,
            storedFileRelativePath: entity.storedFileRelativePath,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        )
    }
}

enum TextSegmentMapper {
    static func toEntity(_ model: TextSegmentModel, documentID: Document.ID) -> TextSegment {
        TextSegment(
            id: model.id,
            documentID: documentID,
            order: model.order,
            text: model.text,
            readingText: model.readingText,
            translation: model.translation,
            explanation: model.explanation,
            isNewParagraph: model.isNewParagraph,
            createdAt: model.createdAt
        )
    }

    static func makeModel(from entity: TextSegment, document: DocumentModel) -> TextSegmentModel {
        TextSegmentModel(
            id: entity.id,
            order: entity.order,
            text: entity.text,
            readingText: entity.readingText,
            translation: entity.translation,
            explanation: entity.explanation,
            isNewParagraph: entity.isNewParagraph,
            createdAt: entity.createdAt,
            document: document
        )
    }

    static func apply(_ entity: TextSegment, to model: TextSegmentModel) {
        model.order = entity.order
        model.text = entity.text
        model.readingText = entity.readingText
        model.translation = entity.translation
        model.explanation = entity.explanation
        model.isNewParagraph = entity.isNewParagraph
        model.createdAt = entity.createdAt
    }
}
