import Foundation
import Domain

public actor MockLibraryRepository: LibraryRepository {
    public var documents: [Document] = []
    public var segmentsByDocument: [Document.ID: [TextSegment]] = [:]

    public init() {}

    public func fetchDocuments() async throws -> [Document] {
        documents.sorted { $0.createdAt > $1.createdAt }
    }

    public func fetchDocument(id: Document.ID) async throws -> Document? {
        documents.first { $0.id == id }
    }

    public func fetchSegments(for documentID: Document.ID) async throws -> [TextSegment] {
        segmentsByDocument[documentID] ?? []
    }

    public func save(document: Document, segments: [TextSegment]) async throws {
        documents.removeAll { $0.id == document.id }
        documents.append(document)
        segmentsByDocument[document.id] = segments
    }

    public func updateSegment(_ segment: TextSegment) async throws {
        var segments = segmentsByDocument[segment.documentID] ?? []
        guard let idx = segments.firstIndex(where: { $0.id == segment.id }) else {
            throw MockLibraryError.notFound
        }
        segments[idx] = segment
        segmentsByDocument[segment.documentID] = segments
    }

    public func delete(_ documentID: Document.ID) async throws {
        documents.removeAll { $0.id == documentID }
        segmentsByDocument[documentID] = nil
    }
}

private enum MockLibraryError: Error {
    case notFound
}
