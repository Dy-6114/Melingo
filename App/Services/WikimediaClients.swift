import Foundation

/// Live Wiktionary + Wikimedia Commons clients (no fixtures).
enum WikimediaClients {}

// MARK: - Definitions (REST)

struct WiktionaryDefinition: Sendable, Hashable {
    var partOfSpeech: String
    var gloss: String
    var example: String?
}

enum WiktionaryRESTClient {
    /// `GET https://en.wiktionary.org/api/rest_v1/page/definition/{term}`
    /// Gloss text is English (en.wiktionary); prefer the **source-language** sense bucket
    /// so FR `pour` ≠ EN verb “to pour”.
    static func definitions(
        for term: String,
        languageHint: String? = nil
    ) async throws -> [WiktionaryDefinition] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(encoded)") else {
            throw WikimediaError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("MelingoMac/1.0 (language learning; local-first)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WikimediaError.badResponse }
        if http.statusCode == 404 { return [] }
        guard (200..<300).contains(http.statusCode) else {
            throw WikimediaError.httpStatus(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WikimediaError.parseFailed
        }
        let buckets = preferredBuckets(in: root, languageHint: languageHint)
        var results: [WiktionaryDefinition] = []
        for entry in buckets {
            let pos = (entry["partOfSpeech"] as? String) ?? ""
            let definitions = entry["definitions"] as? [[String: Any]] ?? []
            for def in definitions {
                if let gloss = def["definition"] as? String {
                    let clean = stripHTML(gloss).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        var example: String?
                        if let examples = def["examples"] as? [String],
                           let first = examples.first {
                            example = stripHTML(first).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let examples = def["examples"] as? [[String: Any]],
                                  let first = examples.first?["example"] as? String
                                    ?? examples.first?["text"] as? String {
                            example = stripHTML(first).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        results.append(WiktionaryDefinition(
                            partOfSpeech: pos,
                            gloss: clean,
                            example: example?.isEmpty == true ? nil : example
                        ))
                    }
                }
            }
        }
        return results
    }

    /// Prefer the learner's content language (e.g. `fr`), then other non-English buckets, then `en`.
    private static func preferredBuckets(
        in root: [String: Any],
        languageHint: String?
    ) -> [[String: Any]] {
        let hint = (languageHint ?? "")
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        let hintKeys: [String] = {
            switch hint {
            case "ja", "jp": return ["ja"]
            case "zh", "cn": return ["zh", "zh-cn", "cmn"]
            case "": return []
            default: return [hint]
            }
        }()
        for key in hintKeys {
            if let bucket = root[key] as? [[String: Any]], !bucket.isEmpty {
                return bucket
            }
        }
        // Homographs: skip English when we know the text language (FR pour ≠ EN pour).
        if !hint.isEmpty, hint != "en" {
            for (key, value) in root {
                let code = key.lowercased()
                guard code != "en", code != "other" else { continue }
                if let bucket = value as? [[String: Any]], !bucket.isEmpty {
                    return bucket
                }
            }
        }
        if let en = root["en"] as? [[String: Any]], !en.isEmpty {
            return en
        }
        return root.values.compactMap { $0 as? [[String: Any]] }.first ?? []
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

// MARK: - IPA (MediaWiki wikitext)

enum WiktionaryMediaWikiClient {
    /// Fetch page wikitext and extract IPA / pronunciation templates.
    /// Tries lemma variants (e.g. `d'août` → `août`) and both en + language-specific wikis.
    static func ipaReadings(for term: String, languageHint: String? = nil) async throws -> [String] {
        let candidates = lemmaCandidates(for: term)
        guard !candidates.isEmpty else { return [] }
        let hosts = wikiHosts(for: languageHint)
        var found: [String] = []
        for host in hosts {
            for candidate in candidates {
                let readings = (try? await fetchIPA(term: candidate, host: host)) ?? []
                for r in readings where !found.contains(r) {
                    found.append(r)
                }
                if !found.isEmpty { return found }
            }
        }
        return found
    }

    private static func wikiHosts(for languageHint: String?) -> [String] {
        let base = languageHint?.lowercased().split(separator: "-").first.map(String.init) ?? ""
        var hosts = ["en.wiktionary.org"]
        switch base {
        case "fr": hosts.insert("fr.wiktionary.org", at: 0)
        case "de": hosts.insert("de.wiktionary.org", at: 0)
        case "es": hosts.insert("es.wiktionary.org", at: 0)
        case "it": hosts.insert("it.wiktionary.org", at: 0)
        case "pt": hosts.insert("pt.wiktionary.org", at: 0)
        case "ru": hosts.insert("ru.wiktionary.org", at: 0)
        case "ja": hosts.insert("ja.wiktionary.org", at: 0)
        case "zh": hosts.insert("zh.wiktionary.org", at: 0)
        case "ko": hosts.insert("ko.wiktionary.org", at: 0)
        default: break
        }
        return hosts
    }

    /// `d'août` → [`d'août`, `août`]; strips common Romance clitics / articles.
    private static func lemmaCandidates(for term: String) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        func push(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            out.append(t)
        }
        push(trimmed)
        push(trimmed.lowercased())
        // Strip leading elision: d', l', n', m', s', t', c', j', qu'
        if let regex = try? NSRegularExpression(
            pattern: #"^(?:[dlmnstcj]|qu)['’](.+)$"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range),
               let r = Range(match.range(at: 1), in: trimmed) {
                push(String(trimmed[r]))
                push(String(trimmed[r]).lowercased())
            }
        }
        // Strip trailing punctuation
        let stripped = trimmed.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        push(stripped)
        push(stripped.lowercased())
        return out
    }

    private static func fetchIPA(term: String, host: String) async throws -> [String] {
        var components = URLComponents(string: "https://\(host)/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: term),
            URLQueryItem(name: "prop", value: "wikitext"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        guard let url = components.url else { throw WikimediaError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("MelingoMac/1.0 (language learning; local-first)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WikimediaError.badResponse
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let parse = root["parse"] as? [String: Any],
            let wikitext = parse["wikitext"] as? String
        else {
            return []
        }
        return extractIPA(from: wikitext)
    }

    private static func extractIPA(from wikitext: String) -> [String] {
        var found: [String] = []
        func push(_ raw: String) {
            guard let ipa = sanitizeIPA(raw), !found.contains(ipa) else { return }
            found.append(ipa)
        }

        // Prefer dedicated pronunciation templates — never bare wiki links.
        let patterns = [
            #"\{\{IPA\|([^}]+)\}\}"#,
            #"\{\{[a-z]{2}-IPA\|([^}]+)\}\}"#,
            #"\{\{pron\|([^}]+)\}\}"#,
            #"\{\{pronunciation\|([^}]+)\}\}"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(wikitext.startIndex..<wikitext.endIndex, in: wikitext)
            regex.enumerateMatches(in: wikitext, options: [], range: range) { match, _, _ in
                guard let match, let full = Range(match.range(at: 1), in: wikitext) else { return }
                let parts = wikitext[full].split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                for part in parts {
                    push(part)
                }
            }
            if !found.isEmpty { return found }
        }

        // Fallback: slash-delimited IPA only (`/ʁuʒ/`), never `[...]` (collides with wiki links).
        let bare = #"(?:^|[\s\(＝=])(/[^/\n\[\]]{1,48}/)"#
        if let regex = try? NSRegularExpression(pattern: bare) {
            let range = NSRange(wikitext.startIndex..<wikitext.endIndex, in: wikitext)
            regex.enumerateMatches(in: wikitext, options: [], range: range) { match, _, stop in
                guard let match, let full = Range(match.range(at: 1), in: wikitext) else { return }
                push(String(wikitext[full]))
                if found.count >= 3 { stop.pointee = true }
            }
        }
        return found
    }

    /// Keep real IPA (`/ʁuʒ/`, `[ʁuʒ]`) and drop wiki markup like `[[w:…|…]]` / `[[son#fro|son]]`.
    private static func sanitizeIPA(_ raw: String) -> String? {
        var s = raw
            .replacingOccurrences(of: "lang=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Reject wiki links / templates leaking into the field.
        if s.contains("[[") || s.contains("]]") || s.contains("{{") || s.contains("}}") { return nil }
        if s.hasPrefix("w:") || s.hasPrefix("#") { return nil }
        // Accept /…/ form.
        if s.hasPrefix("/"), s.hasSuffix("/"), s.count >= 3 { return s }
        // Accept phonetic […] only when it looks like IPA (no pipes / wiki crumbs).
        if s.hasPrefix("["), s.hasSuffix("]"), s.count >= 3, !s.contains("|"), !s.contains("#") {
            return s
        }
        // Sometimes templates omit slashes — wrap if it has IPA-ish chars and no ASCII spaces spam.
        let ipaChars = CharacterSet(charactersIn: "ˈˌːɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃʼˈˌːˑ")
        if s.unicodeScalars.contains(where: { ipaChars.contains($0) }),
           !s.contains(" "),
           s.count <= 48 {
            return "/\(s)/"
        }
        return nil
    }
}

// MARK: - Commons image search

struct CommonsImageResult: Sendable, Hashable, Identifiable {
    var id: String { title }
    var title: String
    var thumbURL: URL?
    var fullURL: URL?
}

enum WikimediaCommonsClient {
    /// Search Commons via `commons.wikimedia.org/w/api.php` (generator=search + imageinfo).
    static func searchImages(query: String, limit: Int = 12) async throws -> [CommonsImageResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: trimmed),
            URLQueryItem(name: "gsrnamespace", value: "6"), // File:
            URLQueryItem(name: "gsrlimit", value: String(max(1, min(limit, 50)))),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url"),
            URLQueryItem(name: "iiurlwidth", value: "320"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        guard let url = components.url else { throw WikimediaError.badURL }
        var request = URLRequest(url: url)
        request.setValue("MelingoMac/1.0 (language learning; local-first)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WikimediaError.badResponse
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queryObj = root["query"] as? [String: Any],
            let pages = queryObj["pages"] as? [[String: Any]]
        else {
            return []
        }
        return pages.compactMap { page in
            let title = page["title"] as? String ?? ""
            let infos = page["imageinfo"] as? [[String: Any]] ?? []
            let info = infos.first
            let thumb = (info?["thumburl"] as? String).flatMap(URL.init(string:))
            let full = (info?["url"] as? String).flatMap(URL.init(string:))
            guard thumb != nil || full != nil else { return nil }
            return CommonsImageResult(title: title, thumbURL: thumb, fullURL: full)
        }
    }

    static func downloadImageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("MelingoMac/1.0 (language learning; local-first)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WikimediaError.badResponse
        }
        return data
    }
}

enum WikimediaError: Error, Sendable, Equatable {
    case badURL
    case badResponse
    case httpStatus(Int)
    case parseFailed
}
