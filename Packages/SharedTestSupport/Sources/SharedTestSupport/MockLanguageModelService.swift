import Foundation
import Domain

/// Test double for `LanguageModelServicing`.
///
/// Defaults throw — no fabricated AI copy. Tests must inject handlers with
/// explicit fixture values for the scenario under test.
public struct MockLanguageModelService: LanguageModelServicing {
    public var capabilities: LanguageModelCapabilities
    public var explainWordHandler: @Sendable (String, TextContext) async throws -> AIExplanation
    public var analyzeHandler: @Sendable (TextSegment, LanguagePair) async throws -> GrammarBreakdown
    public var answerHandler: @Sendable (String, TextSegment, LanguagePair) async throws -> AIAnswer
    public var translateHandler: @Sendable (TextSegment, String) async throws -> String
    public var readingHandler: @Sendable (TextSegment, LanguagePair) async throws -> String
    public var completeHandler: @Sendable (String, String) async throws -> String

    public init(
        capabilities: LanguageModelCapabilities = LanguageModelCapabilities(
            supportsStreaming: true,
            supportsOffline: true,
            maxContextTokens: 8_192,
            providerID: "test"
        ),
        explainWordHandler: @escaping @Sendable (String, TextContext) async throws -> AIExplanation = { _, _ in
            throw LanguageModelError.providerUnavailable
        },
        analyzeHandler: @escaping @Sendable (TextSegment, LanguagePair) async throws -> GrammarBreakdown = { _, _ in
            throw LanguageModelError.providerUnavailable
        },
        answerHandler: @escaping @Sendable (String, TextSegment, LanguagePair) async throws -> AIAnswer = { _, _, _ in
            throw LanguageModelError.providerUnavailable
        },
        translateHandler: @escaping @Sendable (TextSegment, String) async throws -> String = { _, _ in
            throw LanguageModelError.providerUnavailable
        },
        readingHandler: @escaping @Sendable (TextSegment, LanguagePair) async throws -> String = { _, _ in
            throw LanguageModelError.providerUnavailable
        },
        completeHandler: @escaping @Sendable (String, String) async throws -> String = { _, _ in
            throw LanguageModelError.providerUnavailable
        }
    ) {
        self.capabilities = capabilities
        self.explainWordHandler = explainWordHandler
        self.analyzeHandler = analyzeHandler
        self.answerHandler = answerHandler
        self.translateHandler = translateHandler
        self.readingHandler = readingHandler
        self.completeHandler = completeHandler
    }

    public func explainWord(_ word: String, in context: TextContext) async throws -> AIExplanation {
        try await explainWordHandler(word, context)
    }

    public func analyzeGrammar(of segment: TextSegment, languagePair: LanguagePair) async throws -> GrammarBreakdown {
        try await analyzeHandler(segment, languagePair)
    }

    public func answer(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> AIAnswer {
        try await answerHandler(question, segment, languagePair)
    }

    public func translate(_ segment: TextSegment, to targetLanguage: String) async throws -> String {
        try await translateHandler(segment, targetLanguage)
    }

    public func generateReadingLine(
        for segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> String {
        try await readingHandler(segment, languagePair)
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        try await completeHandler(systemPrompt, userMessage)
    }

    public func answerStream(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let answer = try await answerHandler(question, segment, languagePair)
                    continuation.yield(answer.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
