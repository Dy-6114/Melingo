import Foundation
import Domain
import UniformTypeIdentifiers

/// Imports DOCX (Office Open XML) by reading `word/document.xml` from the ZIP package.
public struct DocxImportAdapter: ContentImporting, Sendable {
    private let segmenter: SentenceSegmenter

    public init(segmenter: SentenceSegmenter = SentenceSegmenter()) {
        self.segmenter = segmenter
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        guard case .file(let url) = source else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "docx" { return true }
        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .docx)
                || type.identifier == "org.openxmlformats.wordprocessingml.document"
        }
        return false
    }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        guard case .file(let url) = source else {
            throw ContentImportError.unsupportedSource
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let archive: Data
        do {
            archive = try Data(contentsOf: url)
        } catch {
            throw ContentImportError.unreadableFile
        }

        let body: String
        do {
            body = try Self.extractText(from: archive)
        } catch let error as ContentImportError {
            throw error
        } catch {
            throw ContentImportError.parseFailed(error.localizedDescription)
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContentImportError.emptyContent }

        let title = url.deletingPathExtension().lastPathComponent
        let document = Document(
            title: title.isEmpty ? "Document" : title,
            sourceKind: .docx,
            sourceURL: url.absoluteString
        )
        let drafts = segmenter.segment(trimmed)
        let segments = drafts.enumerated().map { index, draft in
            TextSegment(
                documentID: document.id,
                order: index,
                text: draft.text,
                isNewParagraph: draft.isNewParagraph
            )
        }
        return ImportedContent(
            document: document,
            segments: segments,
            stagingFileURL: url
        )
    }

    static func extractText(from archive: Data) throws -> String {
        let xmlData: Data
        do {
            xmlData = try ZipArchive.entryData(named: "word/document.xml", in: archive)
        } catch {
            throw ContentImportError.parseFailed("Not a valid DOCX (missing word/document.xml).")
        }
        guard let xml = String(data: xmlData, encoding: .utf8) else {
            throw ContentImportError.parseFailed("Invalid DOCX XML encoding.")
        }
        return paragraphs(from: xml).joined(separator: "\n\n")
    }

    /// Collects paragraph text from `w:t` runs, preserving `w:p` boundaries.
    static func paragraphs(from xml: String) -> [String] {
        var paragraphs: [String] = []
        let paragraphPattern = #"<w:p[\s>][\s\S]*?</w:p>"#
        guard let paragraphRegex = try? NSRegularExpression(
            pattern: paragraphPattern, options: []
        ) else { return [] }

        let full = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let textRegex = try? NSRegularExpression(pattern: #"<w:t(?:\s[^>]*)?>([^<]*)</w:t>"#)

        for match in paragraphRegex.matches(in: xml, range: full) {
            guard let range = Range(match.range, in: xml) else { continue }
            let paragraphXML = String(xml[range])
            var parts: [String] = []
            if let textRegex {
                let pRange = NSRange(paragraphXML.startIndex..<paragraphXML.endIndex, in: paragraphXML)
                for tMatch in textRegex.matches(in: paragraphXML, range: pRange) {
                    guard tMatch.numberOfRanges > 1,
                          let tRange = Range(tMatch.range(at: 1), in: paragraphXML)
                    else { continue }
                    parts.append(decodeEntities(String(paragraphXML[tRange])))
                }
            }
            let joined = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { paragraphs.append(joined) }
        }
        return paragraphs
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}

private extension UTType {
    static var docx: UTType {
        UTType(filenameExtension: "docx")
            ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    }
}
