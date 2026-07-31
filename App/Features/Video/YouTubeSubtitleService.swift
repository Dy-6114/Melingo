import Foundation

// Port of jdepoix/youtube-transcript-api (ANDROID Innertube → captionTracks → timedtext).
// No Python runtime — same request shape, native Swift.

struct YouTubeCue: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

struct YouTubeImportPayload: Codable, Sendable, Hashable {
    var schemaVersion: Int
    var videoID: String
    var title: String
    var languageCode: String
    var languageName: String
    var cues: [YouTubeCue]
    var importedAt: Date

    init(
        schemaVersion: Int = 1,
        videoID: String,
        title: String,
        languageCode: String,
        languageName: String,
        cues: [YouTubeCue],
        importedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.videoID = videoID
        self.title = title
        self.languageCode = languageCode
        self.languageName = languageName
        self.cues = cues
        self.importedAt = importedAt
    }
}

enum YouTubeSubtitleError: LocalizedError {
    case invalidURL
    case videoNotFound
    case noCaptions
    case fetchFailed
    case parseFailed
    case ageRestricted
    case ipBlocked
    case poTokenRequired

    var errorDescription: String? {
        switch self {
        case .invalidURL: return AppL10n.t("import.youtube.error.invalidURL")
        case .videoNotFound: return AppL10n.t("import.youtube.error.videoNotFound")
        case .noCaptions: return AppL10n.t("import.youtube.error.noCaptions")
        case .fetchFailed: return AppL10n.t("import.youtube.error.fetchFailed")
        case .parseFailed: return AppL10n.t("import.youtube.error.parseFailed")
        case .ageRestricted: return AppL10n.t("import.youtube.error.ageRestricted")
        case .ipBlocked: return AppL10n.t("import.youtube.error.ipBlocked")
        case .poTokenRequired: return AppL10n.t("import.youtube.error.poTokenRequired")
        }
    }
}

enum YouTubeSubtitleService {
    private static let watchURL = "https://www.youtube.com/watch?v="
    private static let innertubePlayerURL = "https://www.youtube.com/youtubei/v1/player?key="
    /// Public Innertube key embedded in every YouTube watch page (fallback only).
    private static let fallbackInnertubeAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    private struct InnertubeClient: Sendable {
        var name: String
        var version: String
        var userAgent: String
    }

    /// Prefer ANDROID (no PoToken). Fall back if a client returns no tracks.
    private static let clients: [InnertubeClient] = [
        .init(
            name: "ANDROID",
            version: "20.10.38",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"
        ),
        .init(
            name: "ANDROID",
            version: "19.09.37",
            userAgent: "com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip"
        ),
        .init(
            name: "IOS",
            version: "19.45.4",
            userAgent: "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)"
        ),
    ]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpAdditionalHeaders = [
            "Accept-Language": "en-US",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        ]
        return URLSession(configuration: config)
    }()

    struct TranscriptResult: Sendable {
        var title: String
        var languageCode: String
        var languageName: String
        var cues: [YouTubeCue]
    }

    private struct CaptionTrack: Sendable {
        var languageCode: String
        var languageName: String
        var baseURL: URL
        var isGenerated: Bool
        var requiresPoToken: Bool
    }

    /// Full pipeline: watch HTML → Innertube player → pick track → download cues.
    static func fetchTranscript(
        videoID: String,
        preferredLanguages: [String]
    ) async throws -> TranscriptResult {
        let html = try await fetchVideoHTML(videoID: videoID)
        let apiKey = extractInnertubeAPIKey(from: html) ?? fallbackInnertubeAPIKey
        let pageTitle = extractOGTitle(from: html) ?? "YouTube"

        var lastError: Error = YouTubeSubtitleError.noCaptions
        var sawPoTokenOnly = false

        for client in clients {
            do {
                let player = try await fetchInnertubePlayer(
                    videoID: videoID,
                    apiKey: apiKey,
                    client: client
                )
                if let playabilityError = playabilityError(player["playabilityStatus"] as? [String: Any]) {
                    lastError = playabilityError
                    continue
                }

                let title =
                    (player["videoDetails"] as? [String: Any])?["title"] as? String
                    ?? pageTitle

                let tracks = extractCaptionTracks(from: player)
                guard !tracks.isEmpty else {
                    lastError = YouTubeSubtitleError.noCaptions
                    continue
                }

                let ordered = orderedTracks(tracks, preferredLanguages: preferredLanguages)
                for track in ordered {
                    if track.requiresPoToken { sawPoTokenOnly = true }
                    do {
                        let cues = try await downloadCues(
                            from: track.baseURL,
                            userAgent: client.userAgent
                        )
                        if !cues.isEmpty {
                            return TranscriptResult(
                                title: title,
                                languageCode: track.languageCode,
                                languageName: track.languageName,
                                cues: cues
                            )
                        }
                    } catch {
                        lastError = error
                    }
                }
            } catch {
                lastError = error
            }
        }

        // Last resort: captionTracks embedded in the watch page (often PoToken-gated).
        if let embedded = extractCaptionTracks(fromHTML: html), !embedded.isEmpty {
            let title = pageTitle
            for track in orderedTracks(embedded, preferredLanguages: preferredLanguages) {
                if track.requiresPoToken { sawPoTokenOnly = true }
                do {
                    let cues = try await downloadCues(
                        from: track.baseURL,
                        userAgent: clients[0].userAgent
                    )
                    if !cues.isEmpty {
                        return TranscriptResult(
                            title: title,
                            languageCode: track.languageCode,
                            languageName: track.languageName,
                            cues: cues
                        )
                    }
                } catch {
                    lastError = error
                }
            }
        }

        if sawPoTokenOnly, lastError is YouTubeSubtitleError {
            throw YouTubeSubtitleError.poTokenRequired
        }
        throw lastError
    }

    // MARK: - Watch page

    private static func fetchVideoHTML(videoID: String) async throws -> String {
        var html = try await fetchHTML(videoID: videoID)
        if html.contains("action=\"https://consent.youtube.com/s\"") {
            try await createConsentCookie(from: html)
            html = try await fetchHTML(videoID: videoID)
            if html.contains("action=\"https://consent.youtube.com/s\"") {
                throw YouTubeSubtitleError.fetchFailed
            }
        }
        return html
    }

    private static func fetchHTML(videoID: String) async throws -> String {
        guard let url = URL(string: watchURL + videoID) else {
            throw YouTubeSubtitleError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try raiseHTTPErrors(response, data: data)
        guard let html = String(data: data, encoding: .utf8) else {
            throw YouTubeSubtitleError.parseFailed
        }
        // Keep raw HTML — unescaping the whole page can corrupt embedded JSON/URLs.
        return html
    }

    private static func createConsentCookie(from html: String) async throws {
        guard let match = html.range(of: #"name="v" value="([^"]+)""#, options: .regularExpression) else {
            throw YouTubeSubtitleError.fetchFailed
        }
        let snippet = String(html[match])
        guard let valueRange = snippet.range(of: #"value="([^"]+)""#, options: .regularExpression) else {
            throw YouTubeSubtitleError.fetchFailed
        }
        let valuePart = String(snippet[valueRange])
        guard let q1 = valuePart.range(of: "value=\"")?.upperBound,
              let q2 = valuePart[q1...].firstIndex(of: "\"")
        else { throw YouTubeSubtitleError.fetchFailed }
        let token = String(valuePart[q1..<q2])
        let cookie = HTTPCookie(properties: [
            .domain: ".youtube.com",
            .path: "/",
            .name: "CONSENT",
            .value: "YES+\(token)",
        ])
        if let cookie {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
    }

    private static func extractInnertubeAPIKey(from html: String) -> String? {
        let pattern = #""INNERTUBE_API_KEY"\s*:\s*"([a-zA-Z0-9_-]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    // MARK: - Innertube player

    private static func fetchInnertubePlayer(
        videoID: String,
        apiKey: String,
        client: InnertubeClient
    ) async throws -> [String: Any] {
        guard let url = URL(string: innertubePlayerURL + apiKey) else {
            throw YouTubeSubtitleError.fetchFailed
        }
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": client.name,
                    "clientVersion": client.version,
                    "hl": "en",
                    "gl": "US",
                ],
            ],
            "videoId": videoID,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        try raiseHTTPErrors(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeSubtitleError.parseFailed
        }
        return json
    }

    private static func playabilityError(_ status: [String: Any]?) -> YouTubeSubtitleError? {
        guard let status else { return nil }
        let value = status["status"] as? String
        guard let value, value != "OK" else { return nil }

        let reason = status["reason"] as? String ?? ""
        if value == "LOGIN_REQUIRED" {
            if reason.contains("not a bot") { return .ipBlocked }
            if reason.contains("inappropriate") { return .ageRestricted }
        }
        if value == "ERROR", reason.contains("unavailable") {
            return .videoNotFound
        }
        // UNPLAYABLE / other — try next client rather than hard-failing.
        return .videoNotFound
    }

    private static func extractCaptionTracks(from player: [String: Any]) -> [CaptionTrack] {
        guard let captions = player["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]]
        else { return [] }
        return parseTrackDictionaries(tracks)
    }

    private static func extractCaptionTracks(fromHTML html: String) -> [CaptionTrack]? {
        guard let start = html.range(of: "ytInitialPlayerResponse")?.lowerBound,
              let brace = html[start...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        var end: String.Index?
        for index in html[brace...].indices {
            let ch = html[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    end = html.index(after: index)
                    break
                }
            }
        }
        guard let end,
              let data = html[brace..<end].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let tracks = extractCaptionTracks(from: json)
        return tracks.isEmpty ? nil : tracks
    }

    private static func parseTrackDictionaries(_ tracks: [[String: Any]]) -> [CaptionTrack] {
        tracks.compactMap { item -> CaptionTrack? in
            guard let base = item["baseUrl"] as? String,
                  let lang = item["languageCode"] as? String
            else { return nil }
            // JSON may contain literal \u0026; JSONSerialization already decodes those.
            let cleaned = stripFmt(base)
            guard let url = URL(string: cleaned) else { return nil }
            let name = textFromName(item["name"]) ?? lang
            let kind = (item["kind"] as? String) ?? ""
            return CaptionTrack(
                languageCode: lang,
                languageName: name,
                baseURL: url,
                isGenerated: kind == "asr",
                requiresPoToken: cleaned.contains("exp=xpe")
            )
        }
    }

    private static func orderedTracks(
        _ tracks: [CaptionTrack],
        preferredLanguages: [String]
    ) -> [CaptionTrack] {
        let priority = preferredLanguages.map { normalizeLang($0) }.filter { !$0.isEmpty }
        let manual = tracks.filter { !$0.isGenerated }
        let generated = tracks.filter(\.isGenerated)

        var ordered: [CaptionTrack] = []
        var seen = Set<String>()

        func append(_ track: CaptionTrack) {
            let key = track.languageCode + (track.isGenerated ? "|asr" : "|manual")
            guard seen.insert(key).inserted else { return }
            ordered.append(track)
        }

        for code in priority {
            if let hit = manual.first(where: { languageMatches($0.languageCode, code) }) {
                append(hit)
            }
        }
        for code in priority {
            if let hit = generated.first(where: { languageMatches($0.languageCode, code) }) {
                append(hit)
            }
        }
        // Prefer tracks that do not need PoToken.
        for track in (manual + generated).sorted(by: { !$0.requiresPoToken && $1.requiresPoToken }) {
            append(track)
        }
        return ordered
    }

    private static func normalizeLang(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func languageMatches(_ trackCode: String, _ preferred: String) -> Bool {
        let track = normalizeLang(trackCode)
        let pref = normalizeLang(preferred)
        if track == pref { return true }
        if track.hasPrefix(pref + "-") { return true }
        if pref.hasPrefix(track + "-") { return true }
        let trackBase = track.split(separator: "-").first.map(String.init) ?? track
        let prefBase = pref.split(separator: "-").first.map(String.init) ?? pref
        return trackBase == prefBase
    }

    // MARK: - Download cues

    private static func downloadCues(from baseURL: URL, userAgent: String) async throws -> [YouTubeCue] {
        // Prefer json3 (stable for official + ASR). Fall back to default XML / srv3 / vtt.
        let candidates: [URL] = [
            appendingFmt(baseURL, "json3"),
            baseURL,
            appendingFmt(baseURL, "srv3"),
            appendingFmt(baseURL, "vtt"),
        ]

        var sawPoTokenEmpty = baseURL.absoluteString.contains("exp=xpe")
        var lastError: Error = YouTubeSubtitleError.noCaptions

        for url in candidates {
            do {
                let cues = try await fetchAndParse(url: url, userAgent: userAgent)
                if !cues.isEmpty { return cues }
            } catch {
                lastError = error
                if url.absoluteString.contains("exp=xpe") {
                    sawPoTokenEmpty = true
                }
            }
        }

        if sawPoTokenEmpty {
            throw YouTubeSubtitleError.poTokenRequired
        }
        throw lastError
    }

    private static func fetchAndParse(url: URL, userAgent: String) async throws -> [YouTubeCue] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        try raiseHTTPErrors(response, data: data)
        guard !data.isEmpty else { throw YouTubeSubtitleError.noCaptions }

        if let cues = try? parseJSON3(data), !cues.isEmpty {
            return cues
        }
        if let cues = try? parseTimedTextXML(data), !cues.isEmpty {
            return cues
        }
        if let cues = try? parseVTT(data), !cues.isEmpty {
            return cues
        }
        throw YouTubeSubtitleError.parseFailed
    }

    private static func parseJSON3(_ data: Data) throws -> [YouTubeCue] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]]
        else { throw YouTubeSubtitleError.parseFailed }

        var cues: [YouTubeCue] = []
        for event in events {
            guard let startMs = intValue(event["tStartMs"]) else { continue }
            let durationMs = intValue(event["dDurationMs"]) ?? 2000
            let segs = event["segs"] as? [[String: Any]] ?? []
            let text = segs
                .compactMap { $0["utf8"] as? String }
                .joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = TimeInterval(startMs) / 1000
            let end = start + TimeInterval(durationMs) / 1000
            cues.append(YouTubeCue(start: start, end: max(end, start + 0.2), text: text))
        }
        return mergeAdjacentDuplicates(cues)
    }

    private static func parseTimedTextXML(_ data: Data) throws -> [YouTubeCue] {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw YouTubeSubtitleError.parseFailed
        }
        var cues: [YouTubeCue] = []
        let pattern = #"<text\s+start="([^"]+)"(?:\s+dur="([^"]+)")?[^>]*>([\s\S]*?)</text>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw YouTubeSubtitleError.parseFailed
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let match,
                  let startR = Range(match.range(at: 1), in: xml),
                  let textR = Range(match.range(at: 3), in: xml),
                  let start = Double(xml[startR])
            else { return }
            let dur: Double = {
                if match.range(at: 2).location != NSNotFound,
                   let durR = Range(match.range(at: 2), in: xml),
                   let value = Double(xml[durR]) {
                    return value
                }
                return 2.0
            }()
            let raw = String(xml[textR])
                .decodingHTMLEntities()
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            cues.append(YouTubeCue(start: start, end: start + max(dur, 0.2), text: raw))
        }
        guard !cues.isEmpty else { throw YouTubeSubtitleError.parseFailed }
        return mergeAdjacentDuplicates(cues)
    }

    private static func parseVTT(_ data: Data) throws -> [YouTubeCue] {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("-->")
        else { throw YouTubeSubtitleError.parseFailed }

        var cues: [YouTubeCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count >= 2,
                  let start = parseVTTClock(parts[0]),
                  let end = parseVTTClock(parts[1])
            else { continue }
            let body = lines
                .drop(while: { !$0.contains("-->") })
                .dropFirst()
                .joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(YouTubeCue(start: start, end: max(end, start + 0.2), text: body))
        }
        guard !cues.isEmpty else { throw YouTubeSubtitleError.parseFailed }
        return mergeAdjacentDuplicates(cues)
    }

    private static func parseVTTClock(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        let bits = cleaned.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard bits.count >= 2, let sec = Double(bits.last ?? "") else { return nil }
        if bits.count == 2, let m = Double(bits[0]) {
            return m * 60 + sec
        }
        if bits.count >= 3,
           let h = Double(bits[bits.count - 3]),
           let m = Double(bits[bits.count - 2]) {
            return h * 3600 + m * 60 + sec
        }
        return nil
    }

    private static func mergeAdjacentDuplicates(_ cues: [YouTubeCue]) -> [YouTubeCue] {
        guard var current = cues.first else { return [] }
        var out: [YouTubeCue] = []
        for cue in cues.dropFirst() {
            if cue.text == current.text, cue.start <= current.end + 0.35 {
                current.end = max(current.end, cue.end)
            } else {
                out.append(current)
                current = cue
            }
        }
        out.append(current)
        return out
    }

    // MARK: - Helpers

    private static func stripFmt(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString
                .replacingOccurrences(of: "&fmt=srv3", with: "")
                .replacingOccurrences(of: "?fmt=srv3&", with: "?")
                .replacingOccurrences(of: "?fmt=srv3", with: "")
        }
        let items = (components.queryItems ?? []).filter { $0.name != "fmt" }
        components.percentEncodedQuery = nil
        components.queryItems = items.isEmpty ? nil : items
        // Prefer appending via string to avoid over-encoding signature/sparams when possible.
        if let rebuilt = components.string {
            return rebuilt
        }
        return urlString
    }

    private static func appendingFmt(_ url: URL, _ fmt: String) -> URL {
        let base = stripFmt(url.absoluteString)
        let joiner = base.contains("?") ? "&" : "?"
        return URL(string: base + joiner + "fmt=\(fmt)") ?? url
    }

    private static func raiseHTTPErrors(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeSubtitleError.fetchFailed
        }
        if http.statusCode == 429 {
            throw YouTubeSubtitleError.ipBlocked
        }
        guard (200..<300).contains(http.statusCode) else {
            throw YouTubeSubtitleError.fetchFailed
        }
        _ = data
    }

    private static func textFromName(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return value as? String }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func extractOGTitle(from html: String) -> String? {
        let pattern = #"<meta\s+property="og:title"\s+content="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
            .decodingHTMLEntities()
            .replacingOccurrences(of: " - YouTube", with: "")
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}

private extension String {
    func decodingHTMLEntities() -> String {
        var result = self
        // Decode repeatedly so You&amp;#39;ll → You&#39;ll → You'll
        for _ in 0..<3 {
            let entities: [(String, String)] = [
                ("&amp;", "&"),
                ("&lt;", "<"),
                ("&gt;", ">"),
                ("&quot;", "\""),
                ("&#39;", "'"),
                ("&apos;", "'"),
                ("\u{00a0}", " "),
            ]
            for (entity, value) in entities {
                result = result.replacingOccurrences(of: entity, with: value)
            }
            if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
                let ns = result as NSString
                let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
                var mutable = result
                for match in matches {
                    guard match.numberOfRanges > 1,
                          let full = Range(match.range, in: mutable),
                          let numR = Range(match.range(at: 1), in: mutable),
                          let code = Int(mutable[numR]),
                          let scalar = UnicodeScalar(code)
                    else { continue }
                    mutable.replaceSubrange(full, with: String(Character(scalar)))
                }
                result = mutable
            }
            if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
                let ns = result as NSString
                let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
                var mutable = result
                for match in matches {
                    guard match.numberOfRanges > 1,
                          let full = Range(match.range, in: mutable),
                          let numR = Range(match.range(at: 1), in: mutable),
                          let code = Int(mutable[numR], radix: 16),
                          let scalar = UnicodeScalar(code)
                    else { continue }
                    mutable.replaceSubrange(full, with: String(Character(scalar)))
                }
                result = mutable
            }
        }
        return result
    }
}
