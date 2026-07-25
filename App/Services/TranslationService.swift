import Foundation
import Network

/// Gloss translation: prefer an online engine when the network is up, then fall back
/// to on-device Apple Translation. Never invents text.
@MainActor
final class TranslationService {
    enum ServiceError: Error, LocalizedError {
        case unavailable
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Translation unavailable. Check the network or install an Apple language pack."
            case .emptyInput:
                return "Nothing to translate."
            }
        }
    }

    private let apple = LocalTranslationService()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func translate(
        _ text: String,
        from source: String,
        to target: String
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.emptyInput }
        let sourceCode = normalize(source)
        let targetCode = normalize(target)
        if sourceCode == targetCode { return trimmed }

        if NetworkReachability.isOnline {
            if let online = await translateOnline(trimmed, from: sourceCode, to: targetCode) {
                return online
            }
        }

        do {
            return try await apple.translate(trimmed, from: sourceCode, to: targetCode)
        } catch {
            // Last chance: online even if reachability said offline (VPN / captive portal).
            if let online = await translateOnline(trimmed, from: sourceCode, to: targetCode) {
                return online
            }
            throw ServiceError.unavailable
        }
    }

    func translateBatch(
        _ texts: [String],
        from source: String,
        to target: String
    ) async throws -> [String] {
        var out: [String] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            out.append(try await translate(text, from: source, to: target))
        }
        return out
    }

    // MARK: - Online engines

    private func translateOnline(_ text: String, from source: String, to target: String) async -> String? {
        if let g = await googleTranslate(text, from: source, to: target) { return g }
        if let m = await myMemoryTranslate(text, from: source, to: target) { return m }
        return nil
    }

    /// Unofficial Google Translate endpoint (same family many open-source clients use).
    private func googleTranslate(_ text: String, from source: String, to target: String) async -> String? {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: googleLang(source)),
            URLQueryItem(name: "tl", value: googleLang(target)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            // Response shape: [[["translated","source",…],…],…]
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = root.first as? [Any]
            else { return nil }
            var parts: [String] = []
            for item in sentences {
                guard let row = item as? [Any], let piece = row.first as? String else { continue }
                parts.append(piece)
            }
            let joined = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        } catch {
            return nil
        }
    }

    private func myMemoryTranslate(_ text: String, from source: String, to target: String) async -> String? {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(googleLang(source))|\(googleLang(target))"),
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseData = json["responseData"] as? [String: Any],
                  let translated = responseData["translatedText"] as? String
            else { return nil }
            let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            // MyMemory echoes quota / error messages into translatedText.
            if trimmed.lowercased().contains("query length limit") { return nil }
            if trimmed.lowercased().hasPrefix("invalid") { return nil }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private func googleLang(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        switch base {
        case "jp": return "ja"
        case "zh", "cn", "cmn", "zh_hans", "zhhans": return "zh-CN"
        case "tw", "zh_hant", "zhhant": return "zh-TW"
        default: return base
        }
    }

    private func normalize(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        switch base {
        case "jp": return "ja"
        case "cn", "zh-cn", "cmn": return "zh-Hans"
        case "tw", "zh-tw": return "zh-Hant"
        default: return base
        }
    }
}

/// Lightweight online check — prefers a positive path; treats `.requiresConnection` as offline.
enum NetworkReachability {
    private static let monitor = NWPathMonitor()
    private static let queue = DispatchQueue(label: "melingo.network")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedOnline = true
    nonisolated(unsafe) private static var started = false

    static var isOnline: Bool {
        startIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedOnline
    }

    private static func startIfNeeded() {
        lock.lock()
        let already = started
        if !already { started = true }
        lock.unlock()
        guard !already else { return }
        monitor.pathUpdateHandler = { path in
            lock.lock()
            cachedOnline = path.status == .satisfied
            lock.unlock()
        }
        monitor.start(queue: queue)
    }
}
