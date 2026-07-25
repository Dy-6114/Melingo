import Foundation
import CryptoKit

public struct LanguageModelCapabilities: Sendable, Hashable {
    public let supportsStreaming: Bool
    public let supportsOffline: Bool
    public let maxContextTokens: Int
    public let providerID: String

    public init(
        supportsStreaming: Bool,
        supportsOffline: Bool,
        maxContextTokens: Int,
        providerID: String
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsOffline = supportsOffline
        self.maxContextTokens = maxContextTokens
        self.providerID = providerID
    }
}

public enum LanguageModelError: Error, Sendable, Equatable {
    case providerUnavailable
    case contextTooLong
    case networkUnreachable
    case rateLimited
    case unauthorized
    case contentBlocked
    case malformedResponse
    case remoteOptInRequired
    case cancelled
    /// Ask fallback: Presentation should confirm before switching providers.
    case fallbackConsentRequired(preferred: String, fallback: String)
    case underlying(String)

    public var isRetryable: Bool {
        switch self {
        case .networkUnreachable, .rateLimited, .providerUnavailable:
            return true
        case .contextTooLong, .unauthorized, .contentBlocked, .malformedResponse,
                .remoteOptInRequired, .cancelled, .fallbackConsentRequired, .underlying:
            return false
        }
    }
}

/// Domain-facing AI surface. Concrete providers live in AIKit (TZ §6.3 / П4).
public protocol LanguageModelServicing: Sendable {
    var capabilities: LanguageModelCapabilities { get }
    /// Whether this provider can serve requests right now (weights + runtime, etc.).
    var isReady: Bool { get }

    func explainWord(_ word: String, in context: TextContext) async throws -> AIExplanation
    func analyzeGrammar(of segment: TextSegment, languagePair: LanguagePair) async throws -> GrammarBreakdown
    func answer(question: String, about segment: TextSegment, languagePair: LanguagePair) async throws -> AIAnswer
    func translate(_ segment: TextSegment, to targetLanguage: String) async throws -> String

    /// Full-sentence reading line (furigana / kana / pinyin) for learner display.
    func generateReadingLine(for segment: TextSegment, languagePair: LanguagePair) async throws -> String

    /// Raw completion with an explicit system prompt (pack JSON, structured tasks).
    /// Does **not** use the tutor persona — callers own the contract.
    func complete(systemPrompt: String, userMessage: String) async throws -> String

    /// Streaming Q&A when the active provider supports it.
    func answerStream(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) -> AsyncThrowingStream<String, Error>
}

public extension LanguageModelServicing {
    var isReady: Bool { true }
}

public extension ExplanationCacheKey {
    static let explainPromptVersion = "explain-v4"

    static func forExplain(
        text: String,
        targetLanguage: String,
        providerID: String,
        promptVersion: String = explainPromptVersion
    ) -> ExplanationCacheKey {
        ExplanationCacheKey(
            sourceTextHash: Self.sha256Hex(text),
            targetLanguage: targetLanguage,
            promptVersion: promptVersion,
            providerID: providerID
        )
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
