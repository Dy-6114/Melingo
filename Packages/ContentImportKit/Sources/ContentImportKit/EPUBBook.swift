import Foundation
import Domain

/// Parsed EPUB package for desktop-style layout reading (TOC + chapters).
/// Built by `ReadiumAdapter` from the same ZIP/OPF pipeline used for sentence import.
public struct EPUBBook: Sendable, Equatable {
    public struct Chapter: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var html: String
        public var plainText: String

        public init(id: String, title: String, html: String, plainText: String) {
            self.id = id
            self.title = title
            self.html = html
            self.plainText = plainText
        }
    }

    public var title: String
    public var chapters: [Chapter]

    public init(title: String, chapters: [Chapter]) {
        self.title = title
        self.chapters = chapters
    }
}

extension ReadiumAdapter {
    /// Open a full EPUB for the paginated book reader (desktop EpubReader parity).
    public static func openBook(from archive: Data) throws -> EPUBBook {
        let containerXML = try ZipArchive.entryData(named: "META-INF/container.xml", in: archive)
        guard let container = String(data: containerXML, encoding: .utf8) else {
            throw ContentImportError.parseFailed("Invalid EPUB container encoding.")
        }
        guard let opfPath = firstMatchPublic(
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
        let bookTitle = firstMatchPublic(in: opf, pattern: #"<dc:title[^>]*>([^<]+)</dc:title>"#)
            ?? firstMatchPublic(in: opf, pattern: #"<title[^>]*>([^<]+)</title>"#)
            ?? "EPUB"

        let manifest = parseManifestPublic(opf)
        let spineIDs = parseSpinePublic(opf)
        guard !spineIDs.isEmpty else {
            throw ContentImportError.parseFailed("EPUB spine is empty.")
        }

        var chapters: [EPUBBook.Chapter] = []
        for (index, id) in spineIDs.enumerated() {
            guard let href = manifest[id] else { continue }
            let entryPath = joinPathPublic(opfDirectory, href)
            guard let itemData = try? ZipArchive.entryData(named: entryPath, in: archive),
                  let html = String(data: itemData, encoding: .utf8)
                    ?? String(data: itemData, encoding: .utf16)
            else { continue }
            let plain = htmlToPlainText(html)
            guard !plain.isEmpty else { continue }
            let chapterTitle = firstMatchPublic(in: html, pattern: #"<h1[^>]*>([^<]+)</h1>"#)
                ?? firstMatchPublic(in: html, pattern: #"<title[^>]*>([^<]+)</title>"#)
                ?? "Chapter \(index + 1)"
            let wrapped = Self.wrapChapterHTML(html, title: chapterTitle)
            chapters.append(
                EPUBBook.Chapter(
                    id: id,
                    title: chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    html: wrapped,
                    plainText: plain
                )
            )
        }

        guard !chapters.isEmpty else {
            throw ContentImportError.emptyContent
        }
        return EPUBBook(
            title: bookTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapters
        )
    }

    public static func openBook(at url: URL) throws -> EPUBBook {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try openBook(from: data)
    }

    private static func wrapChapterHTML(_ raw: String, title: String) -> String {
        // If already a full document, inject readable CSS; else wrap fragment.
        let css = """
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",serif;line-height:1.65;\
        padding:24px 32px;max-width:42rem;margin:0 auto;color:#1c1c1e;background:#fafafa;}\
        @media (prefers-color-scheme:dark){body{color:#f5f5f7;background:#1c1c1e;}}\
        img{max-width:100%;height:auto;} h1,h2,h3{line-height:1.25;}
        """
        if raw.localizedCaseInsensitiveContains("<html") {
            if raw.localizedCaseInsensitiveContains("</head>") {
                return raw.replacingOccurrences(
                    of: "</head>",
                    with: "<style>\(css)</style></head>",
                    options: .caseInsensitive
                )
            }
            return raw
        }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <title>\(title)</title><style>\(css)</style></head>\
        <body>\(raw)</body></html>
        """
    }

    // Expose private helpers used by openBook without duplicating all parse logic.
    fileprivate static func firstMatchPublic(in text: String, pattern: String) -> String? {
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

    fileprivate static func parseManifestPublic(_ opf: String) -> [String: String] {
        var map: [String: String] = [:]
        let pattern = #"<item\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return map }
        let range = NSRange(opf.startIndex..<opf.endIndex, in: opf)
        for match in regex.matches(in: opf, range: range) {
            guard let full = Range(match.range, in: opf) else { continue }
            let tag = String(opf[full])
            guard let id = attributePublic(tag, name: "id"),
                  let href = attributePublic(tag, name: "href")
            else { continue }
            map[id] = href.removingPercentEncoding ?? href
        }
        return map
    }

    fileprivate static func parseSpinePublic(_ opf: String) -> [String] {
        var ids: [String] = []
        let pattern = #"<itemref\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return ids }
        let range = NSRange(opf.startIndex..<opf.endIndex, in: opf)
        for match in regex.matches(in: opf, range: range) {
            guard let full = Range(match.range, in: opf) else { continue }
            let tag = String(opf[full])
            if let idref = attributePublic(tag, name: "idref") {
                ids.append(idref)
            }
        }
        return ids
    }

    fileprivate static func attributePublic(_ tag: String, name: String) -> String? {
        firstMatchPublic(in: tag, pattern: #"\#(name)\s*=\s*"([^"]+)""#)
            ?? firstMatchPublic(in: tag, pattern: #"\#(name)\s*=\s*'([^']+)'"#)
    }

    fileprivate static func joinPathPublic(_ directory: String, _ href: String) -> String {
        if href.hasPrefix("/") { return String(href.dropFirst()) }
        if directory.isEmpty || directory == "." { return href }
        return (directory as NSString).appendingPathComponent(href)
    }
}
