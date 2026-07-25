import Foundation

/// Domain-facing import orchestration: pick the first matching `ContentImporting` adapter
/// (strategy), persist segments via `LibraryRepository`. Composition roots that also stage
/// binaries (PDF originals / page previews) call `ContentImportRouter.importContent` first,
/// then persist files + `library.save`.
public struct ImportDocumentUseCase: Sendable {
    private let importers: [any ContentImporting]
    private let library: any LibraryRepository

    public init(importers: [any ContentImporting], library: any LibraryRepository) {
        self.importers = importers
        self.library = library
    }

    public func callAsFunction(_ source: ImportSource) async throws -> Document {
        guard let importer = importers.first(where: { $0.canHandle(source) }) else {
            throw ContentImportError.unsupportedSource
        }
        let imported = try await importer.importContent(from: source)
        try await library.save(document: imported.document, segments: imported.segments)
        return imported.document
    }
}
