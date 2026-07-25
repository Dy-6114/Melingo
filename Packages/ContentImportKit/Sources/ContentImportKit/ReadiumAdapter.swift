import Foundation
import Domain
import UniformTypeIdentifiers

/// Imports EPUB publications by reading the ZIP package (container → OPF → spine XHTML).
///
/// Named for the TZ adapter slot. Acts as Melingo’s EPUB toolkit (desktop uses epub.js;
/// here ZIP/OPF + chapter HTML feeds both sentence study and the layout book reader).
public struct ReadiumAdapter: ContentImporting, Sendable {
    private let segmenter: SentenceSegmenter

    public init(segmenter: SentenceSegmenter = SentenceSegmenter()) {
        self.segmenter = segmenter
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        guard case .file(let url) = source else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "epub" { return true }
        return UTType(filenameExtension: ext)?.identifier == "org.idpf.epub-container"
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

        let extracted: ExtractedEPUB
        do {
            extracted = try Self.extract(from: archive)
        } catch let error as ContentImportError {
            throw error
        } catch {
            throw ContentImportError.parseFailed(error.localizedDescription)
        }

        let trimmed = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContentImportError.emptyContent }

        let title = extracted.title
            ?? url.deletingPathExtension().lastPathComponent
        let document = Document(
            title: title.isEmpty ? "EPUB" : title,
            sourceKind: .epub,
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

    // MARK: - Package parse

    private struct ExtractedEPUB: Sendable {
        var title: String?
        var body: String
    }

    private static func extract(from archive: Data) throws -> ExtractedEPUB {
        let containerXML = try ZipArchive.entryData(named: "META-INF/container.xml", in: archive)
        guard let container = String(data: containerXML, encoding: .utf8) else {
            throw ContentImportError.parseFailed("Invalid EPUB container encoding.")
        }
        guard let opfPath = firstMatch(
            in: container,
            pattern: #"full-path\s*=\s*"([^"]+)""#
        ) else {
            throw ContentImportError.parseFailed("EPUB container.xml missing rootfile.")
        }

        let opfData = try ZipArchive.entryData(named: opfPath, in: archive)
        guard let opf = String(data: opfData, encoding: .utf8) else {
            throw ContentImportError.parseFailed("Invalid OPF encoding.")
        }

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let title = firstMatch(in: opf, pattern: #"<dc:title[^>]*>([^<]+)</dc:title>"#)
            ?? firstMatch(in: opf, pattern: #"<title[^>]*>([^<]+)</title>"#)

        let manifest = parseManifest(opf)
        let spineIDs = parseSpine(opf)
        guard !spineIDs.isEmpty else {
            throw ContentImportError.parseFailed("EPUB spine is empty.")
        }

        var chapterTexts: [String] = []
        for id in spineIDs {
            guard let href = manifest[id] else { continue }
            let entryPath = joinPath(opfDirectory, href)
            guard let itemData = try? ZipArchive.entryData(named: entryPath, in: archive),
                  let html = String(data: itemData, encoding: .utf8)
                    ?? String(data: itemData, encoding: .utf16)
            else { continue }
            let plain = htmlToPlainText(html)
            if !plain.isEmpty { chapterTexts.append(plain) }
        }

        return ExtractedEPUB(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            body: chapterTexts.joined(separator: "\n\n")
        )
    }

    private static func parseManifest(_ opf: String) -> [String: String] {
        var map: [String: String] = [:]
        let pattern = #"<item\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return map }
        let range = NSRange(opf.startIndex..<opf.endIndex, in: opf)
        for match in regex.matches(in: opf, range: range) {
            guard let full = Range(match.range, in: opf) else { continue }
            let tag = String(opf[full])
            guard let id = attribute(tag, name: "id"),
                  let href = attribute(tag, name: "href")
            else { continue }
            map[id] = href.removingPercentEncoding ?? href
        }
        return map
    }

    private static func parseSpine(_ opf: String) -> [String] {
        var ids: [String] = []
        let pattern = #"<itemref\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return ids }
        let range = NSRange(opf.startIndex..<opf.endIndex, in: opf)
        for match in regex.matches(in: opf, range: range) {
            guard let full = Range(match.range, in: opf) else { continue }
            let tag = String(opf[full])
            if let idref = attribute(tag, name: "idref") {
                ids.append(idref)
            }
        }
        return ids
    }

    private static func attribute(_ tag: String, name: String) -> String? {
        firstMatch(in: tag, pattern: #"\#(name)\s*=\s*"([^"]+)""#)
            ?? firstMatch(in: tag, pattern: #"\#(name)\s*=\s*'([^']+)'"#)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func joinPath(_ directory: String, _ href: String) -> String {
        if href.hasPrefix("/") { return String(href.dropFirst()) }
        if directory.isEmpty || directory == "." { return href }
        return (directory as NSString).appendingPathComponent(href)
    }

    static func htmlToPlainText(_ html: String) -> String {
        var text = html
        for pattern in [
            #"<script[\s\S]*?</script>"#,
            #"<style[\s\S]*?</style>"#,
            #"<nav[\s\S]*?</nav>"#,
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: #"</(p|div|h[1-6]|li|tr|br|blockquote)\s*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\n[ \\t]*\\n[\\s\\n]*", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
