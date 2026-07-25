import Foundation
import Domain

/// Desktop-parity URL body extraction: readability-style main content, CSS-selector
/// fallback for hard sites (lyrics, etc.), then layout-preserving HTML→text.
public enum ReadableHTMLExtractor: Sendable {

    public struct Result: Sendable, Equatable {
        public var title: String
        public var content: String
        public var usedFallback: Bool
        /// In-article images (absolute URLs) with optional alt captions.
        public var illustrations: [ArticleIllustration]

        public init(
            title: String,
            content: String,
            usedFallback: Bool = false,
            illustrations: [ArticleIllustration] = []
        ) {
            self.title = title
            self.content = content
            self.usedFallback = usedFallback
            self.illustrations = illustrations
        }
    }

    /// Extract title + main text from raw HTML (same strategy as Tauri `fetch_url_content`).
    public static func extract(html: String, pageURL: URL) -> Result {
        var title = extractTitle(from: html) ?? ""
        var content = ""
        var usedFallback = false
        var mainHTML: String?

        // 1) Prefer a readability-like main block.
        if let block = extractMainContentHTML(from: html) {
            mainHTML = block
            content = htmlToTextPreservingLayout(block)
        }

        // 2) If too short, try CSS selectors (Uta-net / lyrics / article shells).
        if content.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 {
            if let fallbackHTML = tryFallbackExtraction(html) {
                let fallbackText = htmlToTextPreservingLayout(fallbackHTML)
                if fallbackText.count > content.count {
                    content = fallbackText
                    mainHTML = fallbackHTML
                    usedFallback = true
                    if title.isEmpty {
                        title = extractTitle(from: html) ?? pageURL.host ?? "Web"
                    }
                }
            }
        }

        // 3) Last resort: whole-document strip (minus chrome).
        if content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
            let strippedBlock = stripChrome(html)
            let stripped = htmlToTextPreservingLayout(strippedBlock)
            if stripped.count > content.count {
                content = stripped
                mainHTML = strippedBlock
            }
        }

        if title.isEmpty {
            title = extractTitle(from: html) ?? pageURL.host ?? "Web"
        }

        let scenes = extractIllustrations(from: mainHTML ?? html, pageURL: pageURL)
        // If body had no usable images, fall back to Open Graph cover as hero.
        let withOG: [ArticleIllustration]
        if scenes.isEmpty, let og = extractOpenGraphImage(from: html, pageURL: pageURL) {
            withOG = [ArticleIllustration(remoteURL: og.absoluteString, afterParagraphIndex: -1)]
        } else {
            withOG = scenes
        }

        return Result(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            usedFallback: usedFallback,
            illustrations: withOG
        )
    }

    // MARK: - Illustrations (“Scene Moments”)

    /// Pull meaningful `<img>` tags from article HTML and place them as hero + mid-article scenes.
    public static func extractIllustrations(from html: String, pageURL: URL, limit: Int = 8) -> [ArticleIllustration] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\b([^>]*?)>"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var raw: [(url: URL, alt: String?, order: Int)] = []

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 2 else { continue }
            let attrs = ns.substring(with: match.range(at: 1))
            guard let src = attribute(named: "src", in: attrs)
                ?? attribute(named: "data-src", in: attrs)
                ?? attribute(named: "data-lazy-src", in: attrs)
            else { continue }

            let resolved = resolveURL(src, relativeTo: pageURL)
            guard let resolved else { continue }
            let key = resolved.absoluteString
            guard !seen.contains(key) else { continue }
            // Skip tracking pixels / icons.
            if let w = attribute(named: "width", in: attrs).flatMap(Int.init), w > 0, w < 48 { continue }
            if let h = attribute(named: "height", in: attrs).flatMap(Int.init), h > 0, h < 48 { continue }
            let lower = key.lowercased()
            if lower.contains("sprite") || lower.contains("icon") || lower.contains("logo")
                || lower.contains("emoji") || lower.contains("1x1") || lower.hasSuffix(".svg") {
                continue
            }
            seen.insert(key)
            let alt = attribute(named: "alt", in: attrs)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            raw.append((resolved, (alt?.isEmpty == false) ? alt : nil, index))
            if raw.count >= limit { break }
        }

        guard !raw.isEmpty else { return [] }

        // First image = hero; remaining spread through the article.
        let paragraphEstimate = max(2, htmlToTextPreservingLayout(html)
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count)
        var illustrations: [ArticleIllustration] = []
        for (i, item) in raw.enumerated() {
            let after: Int
            if i == 0 {
                after = -1
            } else {
                let step = max(1, paragraphEstimate / max(raw.count, 2))
                after = min(paragraphEstimate - 1, i * step)
            }
            illustrations.append(
                ArticleIllustration(
                    remoteURL: item.url.absoluteString,
                    altText: item.alt,
                    afterParagraphIndex: after
                )
            )
        }
        return illustrations
    }

    private static func extractOpenGraphImage(from html: String, pageURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            return resolveURL(String(html[range]), relativeTo: pageURL)
        }
        return nil
    }

    private static func attribute(named name: String, in attrs: String) -> String? {
        let pattern = #"\#(name)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: attrs)
        else { return nil }
        return String(attrs[range])
    }

    private static func resolveURL(_ raw: String, relativeTo page: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//"), let u = URL(string: "https:\(trimmed)") { return u }
        if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
        return URL(string: trimmed, relativeTo: page)?.absoluteURL
    }

    // MARK: - Title

    public static func extractTitle(from html: String) -> String? {
        guard let match = html.range(
            of: "<title[^>]*>([\\s\\S]*?)</title>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let inner = html[match]
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = decodeEntities(String(inner))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: - Main content (readability-lite)

    /// Pick the densest plausible article container after dropping chrome tags.
    static func extractMainContentHTML(from html: String) -> String? {
        let cleaned = stripChrome(html)
        let candidates = [
            firstElementHTML(in: cleaned, tag: "article"),
            firstElementHTML(in: cleaned, matchingID: "content"),
            firstElementHTML(in: cleaned, matchingID: "main"),
            firstElementHTML(in: cleaned, matchingID: "article"),
            firstElementHTML(in: cleaned, matchingClass: "post-content"),
            firstElementHTML(in: cleaned, matchingClass: "entry-content"),
            firstElementHTML(in: cleaned, matchingClass: "article-body"),
            firstElementHTML(in: cleaned, matchingClass: "markdown-body"),
            firstElementHTML(in: cleaned, tag: "main"),
            firstElementByRole(in: cleaned, role: "main"),
        ].compactMap { $0 }

        guard !candidates.isEmpty else { return nil }

        // Score: prefer longer plain text with reasonable tag density.
        let scored = candidates.map { candidate -> (String, Double) in
            let text = htmlToTextPreservingLayout(candidate)
            let textLen = Double(text.count)
            let tagCount = Double(candidate.components(separatedBy: "<").count - 1)
            let density = textLen / max(tagCount, 1)
            let score = textLen + density * 40
            return (candidate, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 80 else { return nil }
        return best.0
    }

    // MARK: - CSS selector fallback (desktop parity)

    static func tryFallbackExtraction(_ html: String) -> String? {
        let selectors: [(id: String?, className: String?, tag: String?, attr: (String, String)?)] = [
            (id: "kashi_area", className: nil, tag: nil, attr: nil),
            (id: nil, className: nil, tag: nil, attr: ("itemprop", "text")),
            (id: nil, className: "lyrics", tag: nil, attr: nil),
            (id: "lyrics", className: nil, tag: nil, attr: nil),
            (id: nil, className: "lyrics_box", tag: nil, attr: nil),
            (id: nil, className: "post-content", tag: nil, attr: nil),
            (id: nil, className: nil, tag: "article", attr: nil),
            (id: nil, className: nil, tag: "main", attr: nil),
        ]

        for sel in selectors {
            let found: String?
            if let id = sel.id {
                found = firstElementHTML(in: html, matchingID: id)
            } else if let className = sel.className {
                found = firstElementHTML(in: html, matchingClass: className)
            } else if let tag = sel.tag {
                found = firstElementHTML(in: html, tag: tag)
            } else if let attr = sel.attr {
                found = firstElementHTML(in: html, attribute: attr.0, value: attr.1)
            } else {
                found = nil
            }
            if let found, found.count > 100 {
                return found
            }
        }
        return nil
    }

    // MARK: - HTML → text (layout-preserving)

    /// Convert HTML to text keeping paragraph / line breaks (lyrics, poems, articles).
    public static func htmlToTextPreservingLayout(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<noscript[\\s\\S]*?</noscript>"] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }

        text = text.replacingOccurrences(
            of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)<(p|div|h[1-6]|li|blockquote|pre|tr|section|header|footer)[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)</(p|div|h[1-6]|li|blockquote|pre|tr|section|header|footer)>"#,
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)

        let lines = text.components(separatedBy: .newlines)
        var clean: [String] = []
        var emptyCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                emptyCount += 1
                if emptyCount <= 2 { clean.append("") }
            } else {
                emptyCount = 0
                clean.append(trimmed)
            }
        }
        return clean.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    static func stripChrome(_ html: String) -> String {
        var text = html
        for pattern in [
            "<script[\\s\\S]*?</script>",
            "<style[\\s\\S]*?</style>",
            "<noscript[\\s\\S]*?</noscript>",
            "<nav[\\s\\S]*?</nav>",
            "<footer[\\s\\S]*?</footer>",
            "<aside[\\s\\S]*?</aside>",
            "<header[\\s\\S]*?</header>",
            "<!--[\\s\\S]*?-->",
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return text
    }

    static func firstElementHTML(in html: String, tag: String) -> String? {
        let pattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>"
        return firstMatch(in: html, pattern: pattern)
    }

    static func firstElementHTML(in html: String, matchingID id: String) -> String? {
        let pattern = "<([a-zA-Z0-9]+)([^>]*\\bid=[\"']\(NSRegularExpression.escapedPattern(for: id))[\"'][^>]*)>([\\s\\S]*?)</\\1>"
        return firstMatch(in: html, pattern: pattern)
    }

    static func firstElementHTML(in html: String, matchingClass className: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: className)
        let pattern =
            "<([a-zA-Z0-9]+)([^>]*\\bclass=[\"'][^\"']*\\b\(escaped)\\b[^\"']*[\"'][^>]*)>([\\s\\S]*?)</\\1>"
        return firstMatch(in: html, pattern: pattern)
    }

    static func firstElementHTML(in html: String, attribute: String, value: String) -> String? {
        let pattern =
            "<([a-zA-Z0-9]+)([^>]*\\b\(attribute)=[\"']\(NSRegularExpression.escapedPattern(for: value))[\"'][^>]*)>([\\s\\S]*?)</\\1>"
        return firstMatch(in: html, pattern: pattern)
    }

    static func firstElementByRole(in html: String, role: String) -> String? {
        firstElementHTML(in: html, attribute: "role", value: role)
    }

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let swiftRange = Range(match.range, in: html)
        else { return nil }
        return String(html[swiftRange])
    }

    public static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ]
        for (entity, char) in named {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // Numeric entities &#123; / &#x1F;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let raw = ns.substring(with: match.range(at: 1))
                let value: UInt32?
                if raw.lowercased().hasPrefix("x") {
                    value = UInt32(raw.dropFirst(), radix: 16)
                } else {
                    value = UInt32(raw)
                }
                if let value, let scalar = UnicodeScalar(value) {
                    let replacement = String(Character(scalar))
                    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }
        }
        return result
    }
}
