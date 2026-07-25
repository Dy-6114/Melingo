import Foundation
import Domain

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence adapter. Runtime-gated for macOS 26+.
public struct FoundationModelsProvider: LanguageModelServicing {
    public init() {}

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(
            supportsStreaming: true,
            supportsOffline: true,
            maxContextTokens: 4_096,
            providerID: AIProviderID.foundationModels.rawValue
        )
    }

    public static var availabilityDescription: String {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Available"
            case .unavailable(.deviceNotEligible):
                return "This Mac isn’t eligible for Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence model is still downloading."
            case .unavailable(let other):
                return "Unavailable (\(String(describing: other)))."
            @unknown default:
                return "Unavailable."
            }
            #else
            return "Foundation Models SDK not linked."
            #endif
        }
        return "Requires macOS 26 or later."
    }

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return SystemLanguageModel.default.isAvailable
            #else
            return false
            #endif
        }
        return false
    }

    public func explainWord(_ word: String, in context: TextContext) async throws -> AIExplanation {
        let breakdown = try await analyzeGrammar(
            of: context.segment, languagePair: context.languagePair)
        let filtered = GrammarBreakdown(
            translation: breakdown.translation,
            summary: breakdown.summary,
            readingText: breakdown.readingText,
            notes: breakdown.notes,
            vocabulary: breakdown.vocabulary.filter {
                $0.word.localizedCaseInsensitiveContains(word)
                    || word.localizedCaseInsensitiveContains($0.word)
            },
            culturalContext: breakdown.culturalContext,
            difficultyLevel: breakdown.difficultyLevel,
            learningTips: breakdown.learningTips
        )
        return AIExplanation(breakdown: filtered.isEmptyVocabFallback(word: word, from: breakdown))
    }

    public func analyzeGrammar(of segment: TextSegment, languagePair: LanguagePair) async throws -> GrammarBreakdown {
        try await ensureAvailable()
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return try await generateGrammar(segment: segment, languagePair: languagePair)
            #else
            throw LanguageModelError.providerUnavailable
            #endif
        }
        throw LanguageModelError.providerUnavailable
    }

    public func answer(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> AIAnswer {
        var chunks: [String] = []
        for try await chunk in answerStream(
            question: question, about: segment, languagePair: languagePair
        ) {
            chunks.append(chunk)
        }
        let text = chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LanguageModelError.malformedResponse }
        return AIAnswer(text: text)
    }

    public func translate(_ segment: TextSegment, to targetLanguage: String) async throws -> String {
        try await ensureAvailable()
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            let session = LanguageModelSession(instructions: PromptLibrary.appleIntelligenceInstructions(
                """
                Translate the user text into natural, fluent \(PromptLibrary.nativeLanguageName(for: targetLanguage)).
                Return only the translation — no quotes, labels, or commentary.
                Preserve meaning and register. Obey target-language grammar.
                """,
                nativeLanguageCode: targetLanguage
            ))
            let clipped = PromptLibrary.clipForContext(
                segment.text, maxChars: PromptLibrary.translateMaxInputChars
            )
            let response = try await session.respond(to: clipped)
            return Self.plainText(fromRespondContent: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #else
            throw LanguageModelError.providerUnavailable
            #endif
        }
        throw LanguageModelError.providerUnavailable
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        try await ensureAvailable()
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            let session = LanguageModelSession(instructions: systemPrompt)
            let clipped = PromptLibrary.clipForContext(
                userMessage, maxChars: PromptLibrary.translateMaxInputChars
            )
            let response = try await session.respond(to: clipped)
            let text = Self.plainText(fromRespondContent: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LanguageModelError.malformedResponse }
            return text
            #else
            throw LanguageModelError.providerUnavailable
            #endif
        }
        throw LanguageModelError.providerUnavailable
    }

    public func generateReadingLine(
        for segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> String {
        if let local = ReadingLineBuilder.localReading(
            for: segment.text, sourceLanguage: languagePair.source
        ) {
            return local
        }
        try await ensureAvailable()
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            let session = LanguageModelSession(
                instructions: PromptLibrary.appleIntelligenceInstructions(
                    PromptLibrary.segmentReadingSystemPrompt(sourceLanguage: languagePair.source),
                    nativeLanguageCode: languagePair.target
                )
            )
            let response = try await session.respond(to: segment.text)
            return Self.plainText(fromRespondContent: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #else
            throw LanguageModelError.providerUnavailable
            #endif
        }
        throw LanguageModelError.providerUnavailable
    }

    public func answerStream(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await ensureAvailable()
                    if #available(macOS 26.0, *) {
                        #if canImport(FoundationModels)
                        let clippedSegment = PromptLibrary.clipForContext(
                            segment.text, maxChars: PromptLibrary.answerMaxInputChars
                        )
                        let session = LanguageModelSession(instructions: PromptLibrary.appleIntelligenceInstructions(
                            """
                            You are a language tutor. Answer the user's question about this segment only.
                            Be concrete; 2–8 short sentences max.
                            Segment:
                            ---
                            \(clippedSegment)
                            ---
                            """,
                            nativeLanguageCode: languagePair.target
                        ))
                        let clipped = PromptLibrary.clipForContext(
                            question, maxChars: PromptLibrary.answerMaxInputChars
                        )
                        let stream = session.streamResponse(to: clipped)
                        var previous = ""
                        for try await partial in stream {
                            let full = Self.plainText(fromStreamPartial: partial)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !full.isEmpty else { continue }
                            // Foundation Models snapshots are cumulative — emit deltas only.
                            if full.hasPrefix(previous) {
                                let delta = String(full.dropFirst(previous.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                            } else {
                                continuation.yield(full)
                            }
                            previous = full
                        }
                        continuation.finish()
                        #else
                        throw LanguageModelError.providerUnavailable
                        #endif
                    } else {
                        throw LanguageModelError.providerUnavailable
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func ensureAvailable() async throws {
        guard Self.isAvailable else { throw LanguageModelError.providerUnavailable }
    }

    /// Unwrap Foundation Models string payloads — never surface `Snapshot(content:…)` dumps.
    private static func plainText(fromRespondContent content: String) -> String {
        sanitizeModelPlainText(content)
    }

    private static func plainText(fromStreamPartial partial: Any) -> String {
        let mirror = Mirror(reflecting: partial)
        for child in mirror.children {
            guard child.label == "content" || child.label == "rawContent" else { continue }
            if let s = child.value as? String, !s.isEmpty {
                return sanitizeModelPlainText(s)
            }
        }
        return sanitizeModelPlainText(String(describing: partial))
    }

    /// If a caller still stringifies a Snapshot, recover the longest quoted `content:` payload.
    public static func sanitizeModelPlainText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("Snapshot(content:") else { return trimmed }
        guard let regex = try? NSRegularExpression(
            pattern: #"content:\s*"((?:[^"\\]|\\.)*)""#,
            options: []
        ) else { return trimmed }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = regex.matches(in: trimmed, options: [], range: range)
        var best = ""
        for match in matches {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: trimmed)
            else { continue }
            let piece = String(trimmed[r])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
            if piece.count > best.count { best = piece }
        }
        return best.isEmpty ? trimmed : best
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateGrammar(
        segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> GrammarBreakdown {
        let lang = PromptLibrary.nativeLanguageName(for: languagePair.target)
        let session = LanguageModelSession(instructions: PromptLibrary.appleIntelligenceInstructions(
            """
            You are a language learning assistant for speakers of \(lang).
            Analyze the learner's segment.
            CRITICAL: Every descriptive field (translation, explanation, vocabulary meanings, grammar notes) MUST be written entirely in \(lang). Never use English unless \(lang) is English.
            "reading" is pronunciation only (furigana/pinyin/IPA) or omit it — never a summary.
            Prefer structured output when asked.
            """,
            nativeLanguageCode: languagePair.target
        ))
        do {
            let result = try await session.respond(
                to: PromptLibrary.analyzeUserMessage(
                    text: segment.text, targetLanguage: languagePair.target),
                generating: FMGrammarDTO.self
            )
            return result.content.asGrammarBreakdown()
        } catch {
            // Fallback: free-form JSON then parse (still no fabricated content).
            let raw = try await session.respond(
                to: PromptLibrary.segmentExplainSystemPrompt(
                    text: segment.text, targetLanguage: languagePair.target)
                    + "\n\n" + PromptLibrary.analyzeUserMessage(
                        text: segment.text, targetLanguage: languagePair.target)
                    + "\n" + PromptLibrary.respondOnLocalLanguage(languagePair.target)
            )
            return try LLMJSONExtractor.parseGrammarBreakdown(from: raw.content)
        }
    }

    @available(macOS 26.0, *)
    @Generable
    struct FMGrammarDTO {
        var translation: String
        var explanation: String
        var reading: String?
        var vocabulary: [FMVocabDTO]?
        var grammar_points: [FMGrammarPointDTO]?
        var cultural_context: String?
        var difficulty_level: String?
        var learning_tips: String?

        func asGrammarBreakdown() -> GrammarBreakdown {
            GrammarBreakdown(
                translation: translation,
                summary: explanation,
                readingText: reading,
                notes: (grammar_points ?? []).map {
                    GrammarNote(point: $0.point, explanation: $0.explanation, example: $0.example)
                },
                vocabulary: (vocabulary ?? []).map {
                    VocabularyItem(
                        word: $0.word,
                        meaning: $0.meaning,
                        usage: $0.usage,
                        example: $0.example,
                        reading: $0.reading
                    )
                },
                culturalContext: cultural_context,
                difficultyLevel: difficulty_level,
                learningTips: learning_tips
            )
        }
    }

    @available(macOS 26.0, *)
    @Generable
    struct FMVocabDTO {
        var word: String
        var meaning: String
        var usage: String?
        var example: String?
        var reading: String?
    }

    @available(macOS 26.0, *)
    @Generable
    struct FMGrammarPointDTO {
        var point: String
        var explanation: String
        var example: String?
    }
    #endif
}
