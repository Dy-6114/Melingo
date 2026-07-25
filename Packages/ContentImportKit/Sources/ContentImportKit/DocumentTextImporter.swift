import CoreFoundation
import Foundation
import Domain
import UniformTypeIdentifiers

public struct DocumentTextImporter: ContentImporting, Sendable {
    private let segmenter: SentenceSegmenter

    public init(segmenter: SentenceSegmenter = SentenceSegmenter()) {
        self.segmenter = segmenter
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        switch source {
        case .plainText:
            return true
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            return ["txt", "md", "markdown", "text"].contains(ext)
                || UTType(filenameExtension: ext)?.conforms(to: .text) == true
        case .url, .image:
            return false
        }
    }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        let title: String
        let body: String
        let kind: DocumentSourceKind
        var staging: URL?

        switch source {
        case .plainText(let t, let b):
            title = (t?.isEmpty == false) ? t! : Self.guessTitle(from: b)
            body = b
            kind = .plainText
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            body = Self.decodeText(data)
            title = url.deletingPathExtension().lastPathComponent
            kind = ["md", "markdown"].contains(url.pathExtension.lowercased()) ? .markdown : .plainText
            staging = url
        case .url, .image:
            throw ContentImportError.unsupportedSource
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContentImportError.emptyContent }

        let document = Document(title: title, sourceKind: kind, sourceURL: staging?.absoluteString)
        let drafts = segmenter.segment(trimmed)
        let segments = drafts.enumerated().map { index, draft in
            TextSegment(
                documentID: document.id,
                order: index,
                text: draft.text,
                isNewParagraph: draft.isNewParagraph
            )
        }
        return ImportedContent(document: document, segments: segments, stagingFileURL: staging)
    }

    public static func guessTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.isEmpty { return "Untitled" }
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }

    public static func decodeText(_ data: Data) -> String {
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding: String.Encoding in [.utf8, .utf16, gb18030, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
