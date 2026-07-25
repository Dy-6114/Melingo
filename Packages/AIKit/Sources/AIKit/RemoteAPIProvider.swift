import Foundation
import Domain

/// Production remote provider — no fabricated responses.
public struct RemoteAPIProvider: LanguageModelServicing {
    private let client: ChatTransportClient
    private let settingsProvider: @Sendable () -> RemoteAISettings
    private let apiKeyProvider: @Sendable (UUID) -> String?

    public init(
        client: ChatTransportClient = ChatTransportClient(),
        settingsProvider: @escaping @Sendable () -> RemoteAISettings,
        apiKeyProvider: @escaping @Sendable (UUID) -> String?
    ) {
        self.client = client
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
    }

    /// Convenience matching older call sites (single Keychain account).
    public init(
        client: ChatTransportClient = ChatTransportClient(),
        configProvider: @escaping @Sendable () -> RemoteModelConfig,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        self.client = client
        self.settingsProvider = {
            let legacy = configProvider()
            return RemoteAISettings(enabled: legacy.enabled, configs: [legacy.asModelConfig()])
        }
        self.apiKeyProvider = { _ in apiKeyProvider() }
    }

    public var capabilities: LanguageModelCapabilities {
        let cfg = settingsProvider().defaultConfig
        return LanguageModelCapabilities(
            supportsStreaming: cfg?.capability.supportsStreaming ?? true,
            supportsOffline: false,
            maxContextTokens: 128_000,
            providerID: AIProviderID.remote.rawValue
        )
    }

    private func resolve() throws -> (ModelConfig, String?, Bool) {
        let settings = settingsProvider()
        guard settings.enabled else { throw LanguageModelError.remoteOptInRequired }
        guard let config = settings.defaultConfig else { throw LanguageModelError.providerUnavailable }
        let key = apiKeyProvider(config.id) ?? APIKeyStore.load()
        return (config, key, settings.enabled)
    }

    public func explainWord(_ word: String, in context: TextContext) async throws -> AIExplanation {
        let breakdown = try await analyzeGrammar(
            of: context.segment,
            languagePair: context.languagePair
        )
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
        let (config, key, enabled) = try resolve()
        let raw = try await client.complete(
            systemPrompt: PromptLibrary.segmentExplainSystemPrompt(
                text: segment.text, targetLanguage: languagePair.target),
            userMessage: PromptLibrary.analyzeUserMessage(
                text: segment.text, targetLanguage: languagePair.target),
            config: config,
            apiKey: key,
            remoteEnabled: enabled
        )
        return try LLMJSONExtractor.parseGrammarBreakdown(from: raw)
    }

    public func answer(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> AIAnswer {
        let (config, key, enabled) = try resolve()
        let system = PromptLibrary.tutorSystemPrompt(
            nativeLanguage: languagePair.target,
            segmentText: segment.text
        )
        let text = try await client.complete(
            systemPrompt: system,
            userMessage: PromptLibrary.clipForContext(question, maxChars: PromptLibrary.answerMaxInputChars),
            config: config,
            apiKey: key,
            remoteEnabled: enabled
        )
        return AIAnswer(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func translate(_ segment: TextSegment, to targetLanguage: String) async throws -> String {
        let (config, key, enabled) = try resolve()
        return try await client.complete(
            systemPrompt: PromptLibrary.segmentTranslateSystemPrompt(targetLanguage: targetLanguage),
            userMessage: PromptLibrary.clipForContext(
                segment.text, maxChars: PromptLibrary.translateMaxInputChars
            ),
            config: config,
            apiKey: key,
            remoteEnabled: enabled,
            timeout: 60
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        let (config, key, enabled) = try resolve()
        return try await client.complete(
            systemPrompt: systemPrompt,
            userMessage: PromptLibrary.clipForContext(
                userMessage, maxChars: PromptLibrary.translateMaxInputChars
            ),
            config: config,
            apiKey: key,
            remoteEnabled: enabled,
            timeout: 120
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func generateReadingLine(
        for segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> String {
        if let local = ReadingLineBuilder.localReading(
            for: segment.text,
            sourceLanguage: languagePair.source
        ) {
            return local
        }
        let (config, key, enabled) = try resolve()
        return try await client.complete(
            systemPrompt: PromptLibrary.segmentReadingSystemPrompt(sourceLanguage: languagePair.source),
            userMessage: segment.text,
            config: config,
            apiKey: key,
            remoteEnabled: enabled,
            timeout: 60
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func answerStream(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (config, key, enabled) = try resolve()
                    let lang = PromptLibrary.nativeLanguageName(for: languagePair.target)
                    let system = """
                    You are a language tutor. Answer in \(lang). Be concise and concrete. \
                    Base the answer on this segment: \(segment.text)
                    """
                    for try await chunk in client.stream(
                        systemPrompt: system,
                        userMessage: question,
                        config: config,
                        apiKey: key,
                        remoteEnabled: enabled
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

extension GrammarBreakdown {
    public func isEmptyVocabFallback(word: String, from full: GrammarBreakdown) -> GrammarBreakdown {
        if !vocabulary.isEmpty { return self }
        return GrammarBreakdown(
            translation: full.translation,
            summary: full.summary,
            readingText: full.readingText,
            notes: full.notes,
            vocabulary: [VocabularyItem(word: word, meaning: full.summary)],
            culturalContext: full.culturalContext,
            difficultyLevel: full.difficultyLevel,
            learningTips: full.learningTips
        )
    }
}
