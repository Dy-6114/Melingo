import Foundation
import Domain

public struct MockContentImporter: ContentImporting {
    public var handledKinds: Set<DocumentSourceKind>
    public var result: ImportedContent?

    public init(
        handledKinds: Set<DocumentSourceKind> = [.plainText, .markdown, .web],
        result: ImportedContent? = nil
    ) {
        self.handledKinds = handledKinds
        self.result = result
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        switch source {
        case .plainText:
            return handledKinds.contains(.plainText)
        case .url:
            return handledKinds.contains(.web)
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" { return handledKinds.contains(.markdown) }
            if ext == "txt" { return handledKinds.contains(.plainText) }
            if ext == "pdf" { return handledKinds.contains(.pdf) }
            if ext == "epub" { return handledKinds.contains(.epub) }
            if ext == "docx" { return handledKinds.contains(.docx) }
            return false
        case .image:
            return handledKinds.contains(.imageOCR)
        }
    }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        if let result {
            return result
        }

        let title: String
        let body: String
        let kind: DocumentSourceKind

        switch source {
        case .plainText(let t, let b):
            title = t ?? "Untitled"
            body = b
            kind = .plainText
        case .url:
            // No fabricated web body — tests must supply `result`.
            throw ContentImportError.unsupportedSource
        case .file(let url):
            title = url.deletingPathExtension().lastPathComponent
            guard let fileBody = try? String(contentsOf: url, encoding: .utf8),
                  !fileBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ContentImportError.unreadableFile }
            body = fileBody
            kind = .plainText
        case .image:
            throw ContentImportError.unsupportedSource
        }

        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContentImportError.emptyContent
        }

        let document = Document(title: title, sourceKind: kind)
        let segment = TextSegment(documentID: document.id, order: 0, text: body)
        return ImportedContent(document: document, segments: [segment])
    }
}
