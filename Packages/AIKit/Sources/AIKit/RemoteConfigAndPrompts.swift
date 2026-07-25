import Foundation
import Domain
import Security

public enum APIKeyStore {
    private static let service = "com.melingo.mac.api-key"

    public static func save(_ key: String, account: String = "remote") throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LanguageModelError.underlying("keychain write failed (\(status))")
        }
    }

    public static func load(account: String = "remote") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func clear(account: String = "remote") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func account(for configID: UUID) -> String {
        "remote.\(configID.uuidString)"
    }
}

public enum RemoteConfigStorage {
    public static let defaultKey = "ai.remoteSettings.v2"
    private static let legacyKey = "ai.remoteConfig.v1"

    public nonisolated static func load(key: String = defaultKey) -> RemoteAISettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let settings = try? JSONDecoder().decode(RemoteAISettings.self, from: data) {
            return settings
        }
        // Migrate legacy single config.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode(RemoteModelConfig.self, from: data) {
            let migrated = RemoteAISettings(
                enabled: legacy.enabled,
                configs: [legacy.asModelConfig()]
            )
            save(migrated, key: key)
            return migrated
        }
        return RemoteAISettings()
    }

    public nonisolated static func save(_ settings: RemoteAISettings, key: String = defaultKey) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Bridge for code still reading a flat config.
    public nonisolated static func loadLegacyBridge(key: String = defaultKey) -> RemoteModelConfig {
        let settings = load(key: key)
        guard let cfg = settings.defaultConfig else {
            return RemoteModelConfig(enabled: settings.enabled)
        }
        return RemoteModelConfig(
            displayName: cfg.name,
            model: cfg.model,
            baseURL: cfg.baseURL ?? cfg.capability.defaultEndpoint?.absoluteString ?? "",
            enabled: settings.enabled,
            providerRaw: cfg.apiProvider.rawValue
        )
    }
}

public enum MLXConfigStorage {
    public static let key = "ai.mlxConfig.v1"

    public struct Config: Codable, Sendable, Equatable {
        public var modelID: String
        public var localRelativePath: String?

        public init(modelID: String = "", localRelativePath: String? = nil) {
            self.modelID = modelID
            self.localRelativePath = localRelativePath
        }

        public var isConfigured: Bool {
            !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && localRelativePath != nil
        }
    }

    public static func load() -> Config {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    public static func save(_ config: Config) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

public enum PromptLibrary {
    public static let segmentExplainVersion = ExplanationCacheKey.explainPromptVersion
    public static let segmentTranslateVersion = "translate-v3"

    public static func nativeLanguageName(for targetLanguage: String) -> String {
        switch targetLanguage.lowercased() {
        case "zh", "zh-cn", "zh-hans": return "中文"
        case "zh-tw", "zh-hant": return "繁體中文"
        case "en": return "English"
        case "ja", "jp": return "日本語"
        case "ko": return "한국어"
        case "ru": return "русский"
        case "es": return "español"
        case "fr": return "français"
        case "de": return "Deutsch"
        case "it": return "italiano"
        case "pt": return "português"
        case "vi": return "tiếng Việt"
        case "th": return "ไทย"
        default: return targetLanguage
        }
    }

    /// Closing line for Apple Intelligence: instructions stay English; output language is local.
    public static func respondOnLocalLanguage(_ targetLanguage: String) -> String {
        "Respond on \(nativeLanguageName(for: targetLanguage))."
    }

    /// English task brief + mandatory local-language closing line (Foundation Models).
    public static func appleIntelligenceInstructions(
        _ englishTask: String,
        nativeLanguageCode: String
    ) -> String {
        """
        \(englishTask.trimmingCharacters(in: .whitespacesAndNewlines))
        \(roleDiscipline)
        \(respondOnLocalLanguage(nativeLanguageCode))
        """
    }

    /// Hard role rules shared by explain / tutor prompts.
    public static let roleDiscipline = """
    ROLE DISCIPLINE (mandatory):
    - Do exactly the assigned task. Nothing else.
    - Never refuse, apologize, or say you cannot / do not know / are unsure.
    - Never invent meta-commentary, disclaimers, or “as an AI…” text.
    - Never expand beyond the requested schema or fields.
    - Keep answers short and concrete; do not pad with tips, fluff, or repetition.
    - Stay within the given text; do not discuss unrelated topics.
    """

    /// Caps user/segment text before it is sent to a model.
    public static func clipForContext(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.prefix(maxChars)) + "…"
    }

    public static let explainMaxInputChars = 2_400
    public static let translateMaxInputChars = 4_000
    public static let answerMaxInputChars = 2_000

    public static func segmentExplainSystemPrompt(text: String, targetLanguage: String) -> String {
        let lang = nativeLanguageName(for: targetLanguage)
        let clipped = clipForContext(text, maxChars: explainMaxInputChars)
        return """
        You explain language-learning segments for a learner whose native language is \(lang).
        \(roleDiscipline)
        LANGUAGE RULE (mandatory, non-negotiable):
        - Write EVERY descriptive string in \(lang) only: translation, explanation, vocabulary meanings/usage/examples, grammar explanations/examples, cultural_context, learning_tips.
        - Do NOT use English (unless \(lang) itself is English).
        - Part-of-speech names and grammar point titles must also be in \(lang).
        - "reading" is ONLY a pronunciation aid (furigana / pinyin / Hangul / IPA). For European languages without a reading system, set "reading" to null — never put a summary or commentary there.

        Return ONLY valid JSON matching the schema below — no markdown fences, no prose outside JSON.
        Prefer at most 6 vocabulary items and 4 grammar points. Omit empty optional fields (use null).

        Text:
        ---
        \(clipped)
        ---

        Schema (keys in English; ALL descriptive values in \(lang)):
        {
          "translation": "Natural \(lang) translation; correct grammar/agreement",
          "reading": "furigana/pinyin/Hangul/IPA only, else null",
          "explanation": "Brief context/tone in \(lang) (Markdown ok, keep short)",
          "vocabulary": [
            {
              "word": "form from the text",
              "reading": "pronunciation or null",
              "meaning": "contextual sense in \(lang)",
              "usage": "one short note in \(lang) or null",
              "example": "one short example + \(lang) gloss or null"
            }
          ],
          "grammar_points": [
            {
              "point": "name in \(lang)",
              "explanation": "short explanation in \(lang)",
              "example": "short example + \(lang) gloss or null"
            }
          ],
          "cultural_context": "one short note in \(lang) or null",
          "difficulty_level": "beginner | intermediate | advanced",
          "learning_tips": "one short tip in \(lang) or null"
        }
        """
    }

    public static func analyzeUserMessage(text: String, targetLanguage: String) -> String {
        let lang = nativeLanguageName(for: targetLanguage)
        return """
        Explain this segment. Output JSON only. Every descriptive field must be in \(lang).
        \(clipForContext(text, maxChars: explainMaxInputChars))
        """
    }

    public static func tutorSystemPrompt(nativeLanguage: String, segmentText: String) -> String {
        let lang = nativeLanguageName(for: nativeLanguage)
        let clipped = clipForContext(segmentText, maxChars: answerMaxInputChars)
        return """
        You are a language tutor. Answer only in \(lang).
        \(roleDiscipline)
        Answer the user's question about this segment only. Be concrete; 2–8 short sentences max.
        Segment:
        ---
        \(clipped)
        ---
        """
    }

    public static func segmentTranslateSystemPrompt(targetLanguage: String) -> String {
        let lang = nativeLanguageName(for: targetLanguage)
        let code = targetLanguage.lowercased()
        var extra = ""
        if code.hasPrefix("ru") {
            extra = """
             Critical Russian grammar rules:
            - Agree adjectives/pronouns with noun gender and number (какой текст, not какая текст).
            - After numerals 2–4 use genitive singular for masculine nouns where required (три персонажа, not три персонажей).
            - Prefer natural word order; do not calque English/French syntax.
            """
        }
        return """
        Translate into natural, fluent \(lang). Return only the translation — no quotes, labels, or commentary.
        \(roleDiscipline)
        Preserve meaning and register. Obey \(lang) grammar: agreement, declension, conjugation, and numeral forms.\(extra)
        Note: single-word lookups must use the system translator elsewhere — you only translate multi-word segments.
        """
    }

    public static func segmentReadingSystemPrompt(sourceLanguage: String) -> String {
        let src = sourceLanguage.lowercased()
        if src.hasPrefix("ja") {
            return """
            Convert the Japanese sentence into a learner reading line: hiragana (with spaces between words/phrases). \
            Keep punctuation. Return only the reading line, no quotes or commentary.
            """
        }
        if src.hasPrefix("zh") {
            return """
            Convert the Chinese sentence into spaced pinyin (tone marks optional). \
            Return only the pinyin line, no quotes or commentary.
            """
        }
        if src.hasPrefix("ko") {
            return """
            Return the Korean sentence as a clear Hangul reading line with spaces between words if helpful. \
            Return only that line, no quotes or commentary.
            """
        }
        return """
        Produce a pronunciation / reading line for language learners for the given sentence. \
        Return only the reading line, no quotes or commentary.
        """
    }
}
