import Foundation
import SwiftData
import Domain

@ModelActor
public actor LibrarySwiftDataRepository: LibraryRepository {
    public func fetchDocuments() async throws -> [Document] {
        let descriptor = FetchDescriptor<DocumentModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(DocumentMapper.toEntity)
    }

    public func fetchDocument(id: Document.ID) async throws -> Document? {
        var descriptor = FetchDescriptor<DocumentModel>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(DocumentMapper.toEntity)
    }

    public func fetchSegments(for documentID: Document.ID) async throws -> [TextSegment] {
        var descriptor = FetchDescriptor<DocumentModel>(
            predicate: #Predicate { $0.id == documentID }
        )
        descriptor.fetchLimit = 1
        guard let document = try modelContext.fetch(descriptor).first else { return [] }
        return document.segments
            .sorted { $0.order < $1.order }
            .map { TextSegmentMapper.toEntity($0, documentID: documentID) }
    }

    public func save(document: Document, segments: [TextSegment]) async throws {
        let documentID = document.id
        var descriptor = FetchDescriptor<DocumentModel>(
            predicate: #Predicate { $0.id == documentID }
        )
        descriptor.fetchLimit = 1

        let model: DocumentModel
        if let existing = try modelContext.fetch(descriptor).first {
            DocumentMapper.apply(document, to: existing)
            for segment in existing.segments {
                modelContext.delete(segment)
            }
            existing.segments.removeAll()
            model = existing
        } else {
            model = DocumentMapper.makeModel(from: document)
            modelContext.insert(model)
        }

        for segment in segments.sorted(by: { $0.order < $1.order }) {
            let segmentModel = TextSegmentMapper.makeModel(from: segment, document: model)
            modelContext.insert(segmentModel)
            model.segments.append(segmentModel)
        }

        try modelContext.save()
    }

    public func updateSegment(_ segment: TextSegment) async throws {
        let segmentID = segment.id
        var descriptor = FetchDescriptor<TextSegmentModel>(
            predicate: #Predicate { $0.id == segmentID }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw DataPersistenceError.notFound
        }
        TextSegmentMapper.apply(segment, to: model)
        try modelContext.save()
    }

    public func delete(_ documentID: Document.ID) async throws {
        var descriptor = FetchDescriptor<DocumentModel>(
            predicate: #Predicate { $0.id == documentID }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }
}

/// Deletes SwiftData rows and associated on-disk binaries under Documents/Melingo.
public struct LibraryRepositoryWithFiles: LibraryRepository {
    private let repository: LibrarySwiftDataRepository
    private let fileStore: DocumentFileStore

    public init(repository: LibrarySwiftDataRepository, fileStore: DocumentFileStore) {
        self.repository = repository
        self.fileStore = fileStore
    }

    public func fetchDocuments() async throws -> [Document] {
        try await repository.fetchDocuments()
    }

    public func fetchDocument(id: Document.ID) async throws -> Document? {
        try await repository.fetchDocument(id: id)
    }

    public func fetchSegments(for documentID: Document.ID) async throws -> [TextSegment] {
        try await repository.fetchSegments(for: documentID)
    }

    public func save(document: Document, segments: [TextSegment]) async throws {
        try await repository.save(document: document, segments: segments)
    }

    public func updateSegment(_ segment: TextSegment) async throws {
        try await repository.updateSegment(segment)
    }

    public func delete(_ documentID: Document.ID) async throws {
        try await repository.delete(documentID)
        try fileStore.deleteAll(for: documentID)
    }
}
