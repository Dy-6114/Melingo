import Foundation
import Network
import Domain
import NaturalLanguage

/// Result of a study-pair lookup that tolerates mixed L1/L2 text.
struct StudyLookupResult: Sendable, Equatable {
    /// Gloss shown in the UI («Перевод»).
    var gloss: String
    /// Headword to store on the card (prefer study / L2).
    var cardWord: String
    /// Meaning to store on the card (prefer native / L1).
    var cardMeaning: String
    /// `true` when the typed/clicked text was treated as native language.
    var inputWasNative: Bool
    var speakLanguage: String
}

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

    private enum ScriptFamily: Equatable {
        case latin, cyrillic, cjk, other
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

    /// Study-aware lookup: pick direction from the word’s script/language, then fall back.
    /// Avoids fr→ru “состоянием→состояние” being treated as a real gloss for Russian text.
    func resolveStudyLookup(_ text: String, pair: LanguagePair) async -> StudyLookupResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nativeFirst = inputLooksNative(trimmed, pair: pair)
        let attempts: [(from: String, to: String, inputWasNative: Bool)] = nativeFirst
            ? [(pair.target, pair.source, true), (pair.source, pair.target, false)]
            : [(pair.source, pair.target, false), (pair.target, pair.source, true)]

        for attempt in attempts {
            guard let gloss = try? await translate(trimmed, from: attempt.from, to: attempt.to),
                  Self.isUsefulGloss(gloss, of: trimmed),
                  glossLooksLikeDestination(gloss, to: attempt.to, from: attempt.from)
            else { continue }

            if attempt.inputWasNative {
                return StudyLookupResult(
                    gloss: gloss,
                    cardWord: gloss,
                    cardMeaning: trimmed,
                    inputWasNative: true,
                    speakLanguage: pair.target
                )
            }
            return StudyLookupResult(
                gloss: gloss,
                cardWord: trimmed,
                cardMeaning: gloss,
                inputWasNative: false,
                speakLanguage: pair.source
            )
        }
        return nil
    }

    /// Flexible gloss for phrases/lines: never returns an identity echo when reverse helps.
    func translateFlexible(_ text: String, pair: LanguagePair) async throws -> String {
        if let resolved = await resolveStudyLookup(text, pair: pair) {
            return resolved.gloss
        }
        return try await translate(text, from: pair.source, to: pair.target)
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

    static func isUsefulGloss(_ gloss: String, of input: String) -> Bool {
        let g = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return false }
        return g.localizedCaseInsensitiveCompare(
            input.trimmingCharacters(in: .whitespacesAndNewlines)
        ) != .orderedSame
    }

    // MARK: - Language / script heuristics

    private func inputLooksNative(_ text: String, pair: LanguagePair) -> Bool {
        let study = normalize(pair.source)
        let native = normalize(pair.target)
        if let detected = detectedLanguageCode(text) {
            if matchesLanguage(detected, native) { return true }
            if matchesLanguage(detected, study) { return false }
        }
        let inputScript = scriptFamily(of: text)
        let studyScript = expectedScript(for: study)
        let nativeScript = expectedScript(for: native)
        if inputScript != .other, studyScript != nativeScript {
            if inputScript == nativeScript { return true }
            if inputScript == studyScript { return false }
        }
        return false
    }

    private func glossLooksLikeDestination(_ gloss: String, to target: String, from source: String) -> Bool {
        let fromScript = expectedScript(for: normalize(source))
        let toScript = expectedScript(for: normalize(target))
        guard fromScript != toScript, fromScript != .other, toScript != .other else {
            return true
        }
        let glossScript = scriptFamily(of: gloss)
        // Reject same-script morphological “translations” (состояние ≠ condition).
        if glossScript == fromScript, glossScript != toScript {
            return false
        }
        return true
    }

    private func detectedLanguageCode(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return normalize(language.rawValue)
    }

    private func matchesLanguage(_ detected: String, _ code: String) -> Bool {
        detected == code || detected.hasPrefix(code) || code.hasPrefix(detected)
    }

    private func expectedScript(for code: String) -> ScriptFamily {
        switch code {
        case "ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "tg", "tt", "mn":
            return .cyrillic
        case "zh", "ja", "ko":
            return .cjk
        case "ar", "he", "fa", "ur":
            return .other
        default:
            return .latin
        }
    }

    private func scriptFamily(of text: String) -> ScriptFamily {
        var latin = 0, cyrillic = 0, cjk = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                cyrillic += 1
            } else if (0x4E00...0x9FFF).contains(v)
                        || (0x3040...0x30FF).contains(v)
                        || (0xAC00...0xD7AF).contains(v) {
                cjk += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        let best = max(latin, cyrillic, cjk)
        guard best > 0 else { return .other }
        if cyrillic == best { return .cyrillic }
        if cjk == best { return .cjk }
        if latin == best { return .latin }
        return .other
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
