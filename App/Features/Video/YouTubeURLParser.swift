import Foundation

enum YouTubeURLParser {
    /// Extracts an 11-character YouTube video id from common URL shapes.
    static func videoID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count == 11,
           trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return trimmed
        }

        let withScheme: String = {
            if trimmed.contains("://") { return trimmed }
            return "https://\(trimmed)"
        }()

        guard let url = URL(string: withScheme), let host = url.host?.lowercased() else {
            return nil
        }

        let isYouTubeHost =
            host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
            || host == "m.youtube.com"
            || host == "www.youtube.com"
            || host == "music.youtube.com"

        guard isYouTubeHost else { return nil }

        if host == "youtu.be" {
            let id = url.path.split(separator: "/").first.map(String.init)
            return validate(id)
        }

        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value {
            return validate(v)
        }

        let parts = url.path.split(separator: "/").map(String.init)
        if let embedIdx = parts.firstIndex(of: "embed"), parts.indices.contains(embedIdx + 1) {
            return validate(parts[embedIdx + 1])
        }
        if let shortsIdx = parts.firstIndex(of: "shorts"), parts.indices.contains(shortsIdx + 1) {
            return validate(parts[shortsIdx + 1])
        }
        if let liveIdx = parts.firstIndex(of: "live"), parts.indices.contains(liveIdx + 1) {
            return validate(parts[liveIdx + 1])
        }

        return nil
    }

    static func isYouTubeURL(_ raw: String) -> Bool {
        videoID(from: raw) != nil
    }

    static func canonicalURL(videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }

    private static func validate(_ id: String?) -> String? {
        guard let id, id.count == 11,
              id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
        else { return nil }
        return id
    }
}
