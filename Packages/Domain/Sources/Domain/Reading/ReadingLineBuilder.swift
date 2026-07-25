import Foundation

/// Builds a furigana / reading line for a segment when possible without a network call.
public enum ReadingLineBuilder: Sendable {
    /// Prefer offline heuristics; returns nil when the language needs morphological AI help.
    public static func localReading(
        for text: String,
        sourceLanguage: String,
        vocabulary: [VocabularyItem] = []
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lang = sourceLanguage.lowercased()
        if lang.hasPrefix("zh") {
            return mandarinPinyin(for: trimmed)
        }
        if lang.hasPrefix("ja") {
            if isMostlyKana(trimmed) { return spacedKana(trimmed) }
            if let fromVocab = readingFromVocabulary(vocabulary, original: trimmed) {
                return fromVocab
            }
            return nil
        }
        if lang.hasPrefix("ko") {
            // Hangul is already phonetic; spacing helps learners.
            return trimmed
        }
        return nil
    }

    /// Merge AI / local candidates; never overwrite a non-empty existing reading unless `force`.
    /// Reject prose masquerading as a reading line (common LLM mistake on FR/EN/etc.).
    public static func resolve(
        existing: String?,
        aiReading: String?,
        text: String,
        sourceLanguage: String,
        vocabulary: [VocabularyItem],
        force: Bool = false
    ) -> String? {
        if !force,
           let existing,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isPlausibleReading(existing, sourceLanguage: sourceLanguage) {
            return existing
        }
        if let aiReading {
            let t = aiReading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, isPlausibleReading(t, sourceLanguage: sourceLanguage) {
                return t
            }
        }
        return localReading(for: text, sourceLanguage: sourceLanguage, vocabulary: vocabulary)
    }

    /// Reading lines are short pronunciation aids — not paragraph summaries.
    public static func isPlausibleReading(_ value: String, sourceLanguage: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lang = sourceLanguage.lowercased()
        if lang.hasPrefix("ja") || lang.hasPrefix("zh") || lang.hasPrefix("ko") {
            // Allow longer kana/pinyin lines for full sentences.
            return t.count <= 400 && !t.contains("The text ") && !t.contains("This passage")
        }
        // Romance / Germanic: only IPA-like snippets, never English commentary.
        if t.count > 80 { return false }
        if t.contains(". ") || t.contains("The ") || t.contains("This ") { return false }
        let looksIPA = t.contains("/") || t.contains("[") || t.contains("]")
        return looksIPA || t.count <= 40
    }

    // MARK: - Heuristics

    private static func mandarinPinyin(for text: String) -> String? {
        let mutable = NSMutableString(string: text)
        let okLatin = CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        guard okLatin else { return nil }
        _ = CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let result = (mutable as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == text ? nil : result
    }

    private static func isMostlyKana(_ text: String) -> Bool {
        var kana = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || v == 0x30FC {
                kana += 1
            } else if scalar.properties.isAlphabetic || (0x4E00...0x9FFF).contains(v) {
                letters += 1
            }
        }
        return kana > 0 && kana >= letters
    }

    private static func spacedKana(_ text: String) -> String {
        text.replacingOccurrences(of: "　", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Greedy longest-match replacement of surface forms with their readings.
    static func readingFromVocabulary(_ items: [VocabularyItem], original: String) -> String? {
        let usable = items
            .compactMap { item -> (word: String, reading: String)? in
                guard let reading = item.reading?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reading.isEmpty,
                      !item.word.isEmpty
                else { return nil }
                return (item.word, reading)
            }
            .sorted { $0.word.count > $1.word.count }
        guard !usable.isEmpty else { return nil }

        var cursor = original.startIndex
        var parts: [String] = []
        var replaced = false
        while cursor < original.endIndex {
            let rest = original[cursor...]
            var matched = false
            for pair in usable {
                if rest.hasPrefix(pair.word) {
                    parts.append(pair.reading)
                    cursor = original.index(cursor, offsetBy: pair.word.count)
                    matched = true
                    replaced = true
                    break
                }
            }
            if !matched {
                parts.append(String(original[cursor]))
                cursor = original.index(after: cursor)
            }
        }
        guard replaced else { return nil }
        return parts.joined()
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
