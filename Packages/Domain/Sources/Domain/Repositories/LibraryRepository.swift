import Foundation

public protocol LibraryRepository: Sendable {
    func fetchDocuments() async throws -> [Document]
    func fetchDocument(id: Document.ID) async throws -> Document?
    func fetchSegments(for documentID: Document.ID) async throws -> [TextSegment]
    func save(document: Document, segments: [TextSegment]) async throws
    /// Patch a single segment row without rewriting the whole document.
    func updateSegment(_ segment: TextSegment) async throws
    func delete(_ documentID: Document.ID) async throws
}
