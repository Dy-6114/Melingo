import Foundation

/// Parses LLM / NotebookLM JSON into a pack draft. Accepts field aliases and strips fences.
public enum PackJSONParser {
    public static func parse(_ raw: String) throws -> PackImportDraft {
        let extracted = extractJSONPayload(from: raw)
        guard let data = extracted.data(using: .utf8) else {
            throw PackJSONError.invalidEncoding
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PackJSONError.invalidEncoding
        }
        if let dict = object as? [String: Any] {
            return try draft(from: dict)
        }
        if let array = object as? [[String: Any]] {
            let cards = try array.compactMap(card(from:))
            guard !cards.isEmpty else { throw PackJSONError.noCards }
            return PackImportDraft(title: "Imported pack", description: "", cards: cards)
        }
        throw PackJSONError.unexpectedRoot
    }

    public static let notebookPrompt = """
    Create a vocabulary learning pack as JSON only (no markdown fences, no commentary). Schema:
    {
      "title": "Short pack title",
      "description": "1–2 sentences about the material",
      "cards": [
        {
          "term": "ONE word or short fixed expression in the LEARNING language only (not a sentence)",
          "translation": "gloss in the learner's native language",
          "context": "optional short EXAMPLE SENTENCE in the learning language using the term"
        }
      ]
    }
    Rules: term = vocabulary headword / set phrase (1–5 words max). Never put random sentences or native-language text in term. Aim for 8–20 useful cards. Return ONLY the JSON object.
    """

    /// System prompt for `complete(system:user:)` — not the tutor persona.
    public static func generationSystemPrompt(
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let learn = languageDisplayName(learningLanguage)
        let native = languageDisplayName(nativeLanguage)
        return """
        You generate VOCABULARY packs for language learners.
        Return ONLY valid JSON matching the schema. No markdown fences, no apology, no prose.

        Languages:
        - Learning language (L2): \(learn) (code: \(learningLanguage))
        - Native language (L1): \(native) (code: \(nativeLanguage))

        HARD RULES for each card:
        1. "term" MUST be a single word OR a short fixed expression/set phrase IN \(learn) only.
           - Max ~5 words / ~40 characters. Examples of GOOD terms: boarding pass, 搭乗券, check-in, 空港.
           - FORBIDDEN as term: full sentences, random prose, questions, L1/\(native) text, English if L2 is not English.
        2. "translation" MUST be a short gloss IN \(native) only (the meaning of the term).
        3. "context" (optional) MUST be one short EXAMPLE SENTENCE IN \(learn) that uses the term — never in \(native).
        4. Prefer concrete, topic-relevant vocabulary. No duplicates. No invented meta commentary.
        5. Prefer 8–16 cards.
        6. Sense must match the topic and any "context" example — avoid false friends
           (e.g. French "gratuité" in a gratitude context ≠ "free of charge"; prefer gratitude/thanks).

        Schema:
        {"title":"...","description":"...","cards":[{"term":"...","translation":"...","context":"..."}]}
        """
    }

    /// Drops cards that are clearly sentences / wrong-script / empty after trim.
    public static func sanitizeVocabularyCards(
        _ cards: [PackCardDraft],
        learningLanguage: String
    ) -> [PackCardDraft] {
        cards.compactMap { card in
            let term = card.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = card.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !translation.isEmpty else { return nil }
            let words = term.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).count
            guard words <= 6, term.count <= 48 else { return nil }
            // Sentence-like terms (many words + terminal punctuation).
            if words >= 4, let last = term.last, ".!?。！？".contains(last) {
                return nil
            }
            guard termMatchesLearningScript(term, language: learningLanguage) else { return nil }
            let context = card.context?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanContext = (context?.isEmpty == false) ? context : nil
            return PackCardDraft(term: term, translation: translation, context: cleanContext)
        }
    }

    public static func languageDisplayName(_ code: String) -> String {
        switch code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased() {
        case "zh", "cn": return "Chinese"
        case "en": return "English"
        case "ja", "jp": return "Japanese"
        case "ko": return "Korean"
        case "ru": return "Russian"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "vi": return "Vietnamese"
        case "th": return "Thai"
        default: return code
        }
    }

    private static func termMatchesLearningScript(_ term: String, language: String) -> Bool {
        let base = language.lowercased().split(separator: "-").first.map(String.init) ?? language.lowercased()
        let scalars = term.unicodeScalars
        func has(_ block: (Unicode.Scalar) -> Bool) -> Bool {
            scalars.contains(where: block)
        }
        switch base {
        case "ja", "jp":
            return has {
                ($0.value >= 0x3040 && $0.value <= 0x30FF) // kana
                    || ($0.value >= 0x4E00 && $0.value <= 0x9FFF) // CJK
                    || ($0.value >= 0x3400 && $0.value <= 0x4DBF)
            }
        case "zh", "cn":
            return has { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        case "ko":
            return has { $0.value >= 0xAC00 && $0.value <= 0xD7AF }
                || has { $0.value >= 0x1100 && $0.value <= 0x11FF }
        case "ru":
            return has { $0.value >= 0x0400 && $0.value <= 0x04FF }
        case "ar":
            return has { $0.value >= 0x0600 && $0.value <= 0x06FF }
        case "th":
            return has { $0.value >= 0x0E00 && $0.value <= 0x0E7F }
        case "en", "es", "fr", "de", "it", "pt", "vi", "nl", "pl", "tr", "id", "ms":
            // Latin-script L2: reject if dominated by CJK / Cyrillic / Hangul / Arabic.
            let foreign = has {
                ($0.value >= 0x4E00 && $0.value <= 0x9FFF)
                    || ($0.value >= 0x0400 && $0.value <= 0x04FF)
                    || ($0.value >= 0xAC00 && $0.value <= 0xD7AF)
                    || ($0.value >= 0x0600 && $0.value <= 0x06FF)
                    || ($0.value >= 0x3040 && $0.value <= 0x30FF)
            }
            return !foreign
        default:
            return true
        }
    }

    /// Pull JSON object/array out of model prose / fences.
    public static func extractJSONPayload(from raw: String) -> String {
        var text = stripCodeFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") { return text }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end {
            return String(text[start...end])
        }
        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]"),
           start < end {
            return String(text[start...end])
        }
        return text
    }

    private static func draft(from dict: [String: Any]) throws -> PackImportDraft {
        let title = string(dict, keys: ["title", "name", "packTitle"]) ?? "Imported pack"
        let description = string(dict, keys: ["description", "packDescription", "summary"]) ?? ""
        let cardsRaw = dict["cards"] ?? dict["items"] ?? dict["vocabulary"] ?? dict["entries"]
        guard let cardsArray = cardsRaw as? [[String: Any]] else {
            throw PackJSONError.noCards
        }
        let cards = try cardsArray.compactMap(card(from:))
        guard !cards.isEmpty else { throw PackJSONError.noCards }
        return PackImportDraft(title: title, description: description, cards: cards)
    }

    private static func card(from dict: [String: Any]) throws -> PackCardDraft? {
        let term = string(dict, keys: ["term", "word", "front", "source", "l2"])
        let translation = string(dict, keys: ["translation", "meaning", "back", "target", "l1"])
        guard let term, !term.isEmpty, let translation, !translation.isEmpty else {
            return nil
        }
        let context = string(dict, keys: ["context", "example", "usage", "sentence"])
        return PackCardDraft(term: term, translation: translation, context: context)
    }

    private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let end = text.range(of: "```", options: .backwards) {
                text = String(text[..<end.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PackJSONError: Error, Sendable, Equatable {
    case invalidEncoding
    case unexpectedRoot
    case noCards
}
