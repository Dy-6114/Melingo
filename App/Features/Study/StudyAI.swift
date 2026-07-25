import Foundation
import Domain
import AIKit

/// Shared AI + offline fallbacks for Study modes. Never invents “correct” answers —
/// when the model is unavailable, modes degrade to card-owned context / empty states.
enum StudyAI {
    enum MatchResult: Equatable {
        case correct
        case nearMissAccent
        case nearMissForm
        case incorrect
    }

    /// Prefer MLX / analytical route (`complete`) for structured study generation.
    @MainActor
    static func ask(
        _ prompt: String,
        store: AppLibraryStore,
        preferMLX: Bool = true
    ) async -> String? {
        let clipped = String(prompt.prefix(3_500))
        if preferMLX {
            do {
                let raw = try await store.languageModel.complete(
                    systemPrompt: """
                    You are Melingo's study coach. Follow the user instructions exactly.
                    Reply with the requested format only — no markdown fences unless asked.
                    Prefer the learner's explanation language when writing glosses.
                    \(StudyLearnerPrefs.cefrPromptClause)
                    """,
                    userMessage: clipped
                )
                let text = sanitize(raw)
                if !text.isEmpty { return text }
            } catch {
                // Fall through to interactive answer (Apple Intelligence / remote).
            }
        }

        let pair = store.profile.preferredLanguagePair
        let segment = TextSegment(
            documentID: UUID(),
            order: 0,
            text: clipped,
            isNewParagraph: true
        )
        do {
            let answer = try await store.languageModel.answer(
                question: clipped,
                about: segment,
                languagePair: pair
            )
            let text = sanitize(answer.text)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    static func sanitize(_ raw: String) -> String {
        FoundationModelsProvider.sanitizeModelPlainText(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract first JSON object/array substring if the model wrapped it in prose.
    static func extractJSONObject(from text: String) -> String? {
        let cleaned = sanitize(text)
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end {
            return String(cleaned[start...end])
        }
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]"),
           start < end {
            return String(cleaned[start...end])
        }
        return nil
    }

    static func parseJSONDictionary(_ text: String) -> [String: Any]? {
        let raw = extractJSONObject(from: text) ?? sanitize(text)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func blankSentence(for entry: VocabularyEntry) -> (prompt: String, answer: String) {
        if let rotated = StudyLearnerPrefs.pickRotatedContext(for: entry.id, excluding: nil),
           rotated.contains("____") || rotated.localizedCaseInsensitiveContains(entry.word) {
            let blanked = rotated.contains("____") ? rotated : blankOut(word: entry.word, in: rotated)
            return (blanked, entry.word)
        }
        if let example = entry.example?.trimmingCharacters(in: .whitespacesAndNewlines),
           !example.isEmpty {
            let blanked = blankOut(word: entry.word, in: example)
            return (blanked, entry.word)
        }
        if let usage = entry.usage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !usage.isEmpty {
            let blanked = blankOut(word: entry.word, in: usage)
            return (blanked, entry.word)
        }
        return ("I need to use \"____\" here.", entry.word)
    }

    static func blankOut(word: String, in sentence: String) -> String {
        guard !word.isEmpty else { return sentence }
        if let range = sentence.range(of: word, options: .caseInsensitive) {
            return sentence.replacingCharacters(in: range, with: "____")
        }
        return sentence.replacingOccurrences(of: word, with: "____", options: .caseInsensitive)
    }

    /// Soft accept forms: lemma, reading, and obvious conjugated snippets from example/usage.
    static func acceptForms(for entry: VocabularyEntry) -> [String] {
        var forms: [String] = [entry.word]
        if let reading = entry.reading, !reading.isEmpty { forms.append(reading) }
        for field in [entry.example, entry.usage].compactMap({ $0 }) {
            for token in field.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
                let t = String(token)
                if t.count >= 2,
                   normalizeFolding(t).hasPrefix(normalizeFolding(entry.word).prefix(3)),
                   !forms.contains(where: { normalizePreserving($0) == normalizePreserving(t) }) {
                    forms.append(t)
                }
            }
        }
        return forms
    }

    static func answersMatch(_ typed: String, expected: String) -> Bool {
        grade(typed, expected: expected).isSuccess
    }

    static func grade(
        _ typed: String,
        expected: String,
        acceptForms: [String] = [],
        language: String? = nil
    ) -> MatchResult {
        let t = normalizePreserving(typed)
        guard !t.isEmpty else { return .incorrect }

        let accepts = ([expected] + acceptForms)
            .map(normalizePreserving)
            .filter { !$0.isEmpty }

        if accepts.contains(t) { return .correct }

        let ignoreAccents = StudyLearnerPrefs.ignoreAccents
            || !(languageRequiresAccents(language))

        let tFold = normalizeFolding(typed)
        let foldAccepts = accepts.map(normalizeFolding)
        if foldAccepts.contains(tFold) {
            return ignoreAccents ? .correct : .nearMissAccent
        }

        // Morphology: same lemma/stem, wrong inflection (vêtement/vêtements, mange/manger).
        if accepts.contains(where: { isMorphologicalVariant(t, of: $0, language: language) }) {
            return .nearMissForm
        }

        if accepts.contains(where: { editDistance($0, t) <= nearMissThreshold(for: $0) }) {
            return .nearMissForm
        }
        return .incorrect
    }

    /// Same stem with different FR/Romance inflection → near-miss form (not full credit).
    static func isMorphologicalVariant(_ typed: String, of expected: String, language: String?) -> Bool {
        let t = normalizePreserving(typed)
        let e = normalizePreserving(expected)
        guard t != e, t.count >= 3, e.count >= 3 else { return false }
        let code = (language ?? "").lowercased()
        if code.hasPrefix("fr") || code.hasPrefix("es") || code.hasPrefix("it") || code.hasPrefix("pt") {
            let st = stripRomanceInflection(t)
            let se = stripRomanceInflection(e)
            if st.count >= 3, st == se { return true }
        }
        // Shared prefix ≥ 70% of shorter word and length delta ≤ 3.
        let shorter = min(t.count, e.count)
        let shared = zip(t, e).prefix(while: { $0 == $1 }).count
        return shared >= max(3, (shorter * 7) / 10) && abs(t.count - e.count) <= 3
    }

    private static func stripRomanceInflection(_ s: String) -> String {
        var t = s
        let suffixes = ["ments", "ment", "tions", "tion", "euses", "euse", "eurs", "eur",
                        "eaux", "aux", "ées", "ees", "és", "es", "s", "x", "e"]
        for suf in suffixes where t.count > suf.count + 2 && t.hasSuffix(suf) {
            t = String(t.dropLast(suf.count))
            break
        }
        return t
    }

    /// Offline Challenge: sample/keywords containment (normalized).
    static func challengeOfflinePass(answer: String, sample: String, keywords: [String]) -> Bool {
        let a = normalizeFolding(answer)
        guard !a.isEmpty else { return false }
        let sampleTokens = sample
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { normalizeFolding(String($0)) }
            .filter { $0.count >= 3 }
        let hits = sampleTokens.filter { a.contains($0) }.count
        if hits >= min(2, max(1, sampleTokens.count / 3)) { return true }
        let keyHits = keywords.map(normalizeFolding).filter { !$0.isEmpty && a.contains($0) }
        return keyHits.count >= max(1, keywords.count / 2)
    }

    private static func languageRequiresAccents(_ language: String?) -> Bool {
        guard let language else { return true }
        let code = language.lowercased()
        // Accents are pedagogically load-bearing for these.
        return code.hasPrefix("fr") || code.hasPrefix("es") || code.hasPrefix("pt")
            || code.hasPrefix("it") || code.hasPrefix("de") || code.hasPrefix("vi")
            || code.hasPrefix("pl") || code.hasPrefix("cs") || code.hasPrefix("hu")
    }

    static func normalizePreserving(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʻ", with: "'")
    }

    static func normalizeFolding(_ s: String) -> String {
        normalizePreserving(s)
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    /// Legacy name used by older call sites.
    static func normalize(_ s: String) -> String {
        StudyLearnerPrefs.ignoreAccents ? normalizeFolding(s) : normalizePreserving(s)
    }

    private static func nearMissThreshold(for expected: String) -> Int {
        max(1, min(2, expected.count / 4))
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var cur = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            cur[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[bChars.count]
    }

    @MainActor
    static func pickStudyCards(store: AppLibraryStore, limit: Int = 12) -> [VocabularyEntry] {
        var cards = store.dueQueue
        if cards.count < limit {
            let extras = store.vocabulary.filter { entry in
                entry.suspendedAt == nil
                    && !cards.contains(where: { $0.id == entry.id })
            }
            cards.append(contentsOf: extras.prefix(limit - cards.count))
        }
        return Array(cards.prefix(limit))
    }

    @MainActor
    static func tagsWithCards(store: AppLibraryStore) -> [WordPack] {
        store.packs
            .filter { $0.kind == .tag }
            .filter { tag in
                store.vocabulary.contains { $0.packIDs.contains(tag.id) && $0.suspendedAt == nil }
            }
            .sorted { $0.name < $1.name }
    }

    @MainActor
    static func cardsWithAudio(store: AppLibraryStore) -> [VocabularyEntry] {
        store.vocabulary.filter {
            $0.suspendedAt == nil
                && $0.audioRelativePath != nil
                && store.absoluteAudioURL(for: $0) != nil
        }
    }

    /// Map drill outcome → FSRS so practice moves the schedule.
    /// Correct → good; near-miss → hard (partial credit, not a pass); miss/skip → again/hard.
    @MainActor
    static func applyDrillReview(
        _ entry: VocabularyEntry,
        outcome: MatchResult,
        skipped: Bool = false,
        store: AppLibraryStore
    ) async {
        let grade: FSRS.Grade
        if skipped {
            grade = .hard
        } else {
            switch outcome {
            case .correct: grade = .good
            case .nearMissAccent, .nearMissForm: grade = .hard
            case .incorrect: grade = .again
            }
        }
        _ = await store.review(entry, grade: grade)
    }

    /// Known vocabulary list for dialogue/challenge weaving (limits unknown-word overload).
    @MainActor
    static func knownWordBudget(store: AppLibraryStore, limit: Int = 40) -> [String] {
        store.vocabulary
            .filter { $0.suspendedAt == nil }
            .sorted { ($0.reviewCount, $0.stability) > ($1.reviewCount, $1.stability) }
            .prefix(limit)
            .map(\.word)
    }

    static var generationQualityClause: String {
        """
        \(StudyLearnerPrefs.cefrPromptClause)
        \(StudyLearnerPrefs.grammarGuardClause)
        """
    }

    /// Transparent Challenge / Production judge rubric (include in judge prompts).
    static func judgeRubric(feedbackLanguage: String) -> String {
        """
        Scoring rubric (be consistent):
        - score 3 / ok=true: meaning matches the prompt; grammar OK for CEFR; synonyms & paraphrase OK \
        (e.g. vestiaire ≈ vestiaire/armoire when sense fits).
        - score 2 / ok=true: meaning OK, minor grammar (gender/number/tense) — still pass, note the issue in feedback.
        - score 1 / ok=false: right idea but wrong key word, OR meaning OK but grammar blocks understanding.
        - score 0 / ok=false: empty, off-topic, or wrong language.
        Synonyms that preserve the communicative goal count as OK. Wrong lemma with similar spelling is NOT OK.
        Write "feedback" as a real short sentence in \(feedbackLanguage). Never echo schema placeholders.
        """
    }

    static func flagEmoji(for languageCode: String) -> String {
        let code = languageCode.lowercased()
        if code.hasPrefix("ru") { return "🇷🇺" }
        if code.hasPrefix("en") { return "🇬🇧" }
        if code.hasPrefix("fr") { return "🇫🇷" }
        if code.hasPrefix("de") { return "🇩🇪" }
        if code.hasPrefix("es") { return "🇪🇸" }
        if code.hasPrefix("pt") { return "🇵🇹" }
        if code.hasPrefix("it") { return "🇮🇹" }
        if code.hasPrefix("zh") { return "🇨🇳" }
        if code.hasPrefix("ja") { return "🇯🇵" }
        if code.hasPrefix("ko") { return "🇰🇷" }
        return "💬"
    }

    static func offlineChallengePrompt(
        step: Int,
        topic: String,
        word: String,
        targetLanguage: String
    ) -> String {
        let lang = targetLanguage.lowercased()
        if lang.hasPrefix("ru") {
            switch step {
            case 0: return "Вы в «\(topic)». Поздоровайтесь вежливо."
            case 1: return "Попросите то, что нужно. Постарайтесь использовать: \(word)"
            default: return "Вежливо завершите разговор."
            }
        }
        if lang.hasPrefix("zh") {
            switch step {
            case 0: return "你在「\(topic)」。礼貌地打招呼。"
            case 1: return "说出你需要的。尽量用到：\(word)"
            default: return "礼貌地结束对话。"
            }
        }
        if lang.hasPrefix("ja") {
            switch step {
            case 0: return "「\(topic)」にいます。丁寧にあいさつしてください。"
            case 1: return "必要なことを聞いてください。できれば「\(word)」を使って。"
            default: return "丁寧に会話を終えてください。"
            }
        }
        if lang.hasPrefix("ko") {
            switch step {
            case 0: return "「\(topic)」에 있습니다. 정중히 인사하세요."
            case 1: return "필요한 것을 요청하세요. 가능하면 「\(word)」를 쓰세요."
            default: return "정중히 대화를 마치세요."
            }
        }
        switch step {
        case 0: return "You’re at \(topic). Greet the staff politely."
        case 1: return "Ask for what you need. Try to use: \(word)"
        default: return "Close the interaction politely."
        }
    }

    static func offlineDialogueTurns(
        word: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> [(speaker: String, text: String, translation: String, isLearner: Bool)] {
        let src = sourceLanguage.lowercased()
        let tgt = targetLanguage.lowercased()
        if src.hasPrefix("fr") {
            return [
                ("A", "Bonjour ! Ça va aujourd’hui ?",
                 tgt.hasPrefix("ru") ? "Здравствуйте! Как дела сегодня?" : "Hello! How are you today?",
                 false),
                ("B", "Ça va — je voulais dire « \(word) ».",
                 tgt.hasPrefix("ru")
                    ? "Нормально — я хотел(а) сказать «\(word)»."
                    : "I’m fine — I wanted to say “\(word)”.",
                 true),
                ("A", "Super. On s’entraîne encore demain.",
                 tgt.hasPrefix("ru") ? "Отлично. Потренируемся ещё завтра." : "Nice. Let’s practice again tomorrow.",
                 false),
            ]
        }
        // Generic: keep L2 as word-only production line, L1 prompts via AppL10n elsewhere.
        return [
            ("A", "Hello!", AppL10n.t("dialogue.fallback.a1"), false),
            ("B", word, String(format: AppL10n.t("dialogue.fallback.b1tr"), word), true),
            ("A", "Great — see you tomorrow.", AppL10n.t("dialogue.fallback.a2"), false),
        ]
    }
}

extension StudyAI.MatchResult {
    var isSuccess: Bool {
        switch self {
        case .correct: return true
        case .nearMissAccent, .nearMissForm, .incorrect: return false
        }
    }

    var fsrsFriendly: Bool {
        switch self {
        case .correct: return true
        default: return false
        }
    }
}
