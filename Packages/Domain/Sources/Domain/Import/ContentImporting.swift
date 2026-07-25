import Foundation

public protocol ContentImporting: Sendable {
    func canHandle(_ source: ImportSource) -> Bool
    func importContent(from source: ImportSource) async throws -> ImportedContent
}

public enum ContentImportError: Error, Sendable, Equatable {
    case unsupportedSource
    case unreadableFile
    case emptyContent
    case networkFailed
    case parseFailed(String)
}
