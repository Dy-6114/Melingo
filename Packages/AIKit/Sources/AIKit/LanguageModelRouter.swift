import Foundation
import Domain

/// Routes to Foundation Models / MLX / Remote per profile + fallback policy (TD §4).
///
/// When preferred is `.hybrid`, affinity picks the fastest sensible offline provider:
/// interactive (lookups, short translate, tutor) → Apple Intelligence first;
/// analytical (grammar, structured complete) → MLX first when ready (engine + weights).
///
/// All completions go through `LLMRequestQueue` so Reader batch / Study / Ask do not race.
public final class LanguageModelRouter: LanguageModelServicing, @unchecked Sendable {
    private let foundation: (any LanguageModelServicing)?
    private let mlx: (any LanguageModelServicing)?
    private let remote: any LanguageModelServicing
    private let profileProvider: @Sendable () -> UserProfile
    /// One-shot consent after Ask UI confirmation (`fallback` provider id).
    private var consentedFallbackID: String?
    private let queue: LLMRequestQueue

    private enum RouteAffinity {
        case interactive
        case analytical

        var queuePriority: LLMRequestQueue.Priority {
            switch self {
            case .interactive: return .interactive
            case .analytical: return .analytical
            }
        }
    }

    public init(
        foundation: (any LanguageModelServicing)? = nil,
        mlx: (any LanguageModelServicing)? = nil,
        remote: any LanguageModelServicing,
        profileProvider: @escaping @Sendable () -> UserProfile,
        queue: LLMRequestQueue = .shared
    ) {
        self.foundation = foundation
        self.mlx = mlx
        self.remote = remote
        self.profileProvider = profileProvider
        self.queue = queue
    }

    public func allowFallback(to providerID: String) {
        consentedFallbackID = providerID
    }

    public func clearFallbackConsent() {
        consentedFallbackID = nil
    }

    public var isReady: Bool {
        foundation?.isReady == true || mlx?.isReady == true || remote.isReady
    }

    public var capabilities: LanguageModelCapabilities {
        (try? resolveProvider(affinity: .interactive)).map(\.capabilities)
            ?? LanguageModelCapabilities(
                supportsStreaming: false,
                supportsOffline: false,
                maxContextTokens: 0,
                providerID: "none"
            )
    }

    public func explainWord(_ word: String, in context: TextContext) async throws -> AIExplanation {
        try await withResolved(affinity: .interactive) { try await $0.explainWord(word, in: context) }
    }

    public func analyzeGrammar(of segment: TextSegment, languagePair: LanguagePair) async throws -> GrammarBreakdown {
        try await withResolved(affinity: .analytical) {
            try await $0.analyzeGrammar(of: segment, languagePair: languagePair)
        }
    }

    public func answer(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> AIAnswer {
        try await withResolved(affinity: .interactive) {
            try await $0.answer(question: question, about: segment, languagePair: languagePair)
        }
    }

    public func translate(_ segment: TextSegment, to targetLanguage: String) async throws -> String {
        try await withResolved(affinity: .interactive) { try await $0.translate(segment, to: targetLanguage) }
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        try await withResolved(affinity: .analytical) {
            try await $0.complete(systemPrompt: systemPrompt, userMessage: userMessage)
        }
    }

    public func generateReadingLine(
        for segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> String {
        try await withResolved(affinity: .interactive) {
            try await $0.generateReadingLine(for: segment, languagePair: languagePair)
        }
    }

    public func answerStream(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await queue.enqueue(priority: .interactive) {
                        let provider = try self.resolveProvider(affinity: .interactive)
                        for try await chunk in provider.answerStream(
                            question: question, about: segment, languagePair: languagePair
                        ) {
                            if Task.isCancelled { break }
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Resolution

    private func withResolved<T: Sendable>(
        affinity: RouteAffinity,
        _ body: @escaping @Sendable (any LanguageModelServicing) async throws -> T
    ) async throws -> T {
        try await queue.enqueue(priority: affinity.queuePriority) {
            try await self.withResolvedUnqueued(affinity: affinity, body)
        }
    }

    private func withResolvedUnqueued<T: Sendable>(
        affinity: RouteAffinity,
        _ body: @Sendable (any LanguageModelServicing) async throws -> T
    ) async throws -> T {
        let profile = profileProvider()
        let chain = candidateIDs(for: profile, affinity: affinity)
        guard let first = chain.first else { throw LanguageModelError.providerUnavailable }

        // Tune concurrency: remote can take 2; local stays at 1.
        let usesRemote = chain.contains(AIProviderID.remote.rawValue)
            && profile.remoteAIEnabled
            && profile.preferredAIProvider == .remote
        await queue.setMaxConcurrent(usesRemote ? 2 : 1)

        var lastError: Error = LanguageModelError.providerUnavailable
        for (index, id) in chain.enumerated() {
            guard let provider = provider(for: id, profile: profile) else {
                lastError = LanguageModelError.providerUnavailable
                continue
            }
            if index > 0, profile.aiFallbackMode == .ask {
                if consentedFallbackID != id {
                    throw LanguageModelError.fallbackConsentRequired(
                        preferred: first, fallback: id)
                }
            }
            do {
                let result = try await body(provider)
                if index > 0 { consentedFallbackID = nil }
                return result
            } catch let error as LanguageModelError {
                lastError = error
                if !shouldFallback(error: error, mode: profile.aiFallbackMode) {
                    throw error
                }
                continue
            } catch {
                lastError = error
                if profile.aiFallbackMode == .off { throw error }
                continue
            }
        }
        throw lastError
    }

    private func resolveProvider(affinity: RouteAffinity) throws -> any LanguageModelServicing {
        let profile = profileProvider()
        let chain = candidateIDs(for: profile, affinity: affinity)
        for id in chain {
            if let provider = provider(for: id, profile: profile) {
                return provider
            }
        }
        throw LanguageModelError.providerUnavailable
    }

    private func candidateIDs(for profile: UserProfile, affinity: RouteAffinity) -> [String] {
        let fm = AIProviderID.foundationModels.rawValue
        let mlxID = AIProviderID.mlx.rawValue
        let remoteID = AIProviderID.remote.rawValue
        // Honest readiness: weights alone are not enough — engine must be wired.
        let mlxReady = mlx?.isReady == true

        switch profile.preferredAIProvider {
        case .hybrid:
            let primary: [String]
            switch affinity {
            case .interactive:
                primary = [fm] + (mlxReady ? [mlxID] : [])
            case .analytical:
                primary = mlxReady ? [mlxID, fm] : [fm]
            }
            return appendFallback(primary, profile: profile, offlineExtras: [fm] + (mlxReady ? [mlxID] : []))

        case .foundationModels, .mlx, .remote:
            let preferred = profile.preferredAIProvider.rawValue
            switch profile.aiFallbackMode {
            case .off:
                return [preferred]
            case .offlineOnly, .ask:
                var ids = [preferred]
                for id in [fm, mlxID] where id != preferred {
                    if id == mlxID, !mlxReady { continue }
                    ids.append(id)
                }
                if preferred == remoteID {
                    return [preferred] + [fm] + (mlxReady ? [mlxID] : [])
                }
                return ids
            }
        }
    }

    private func appendFallback(
        _ primary: [String],
        profile: UserProfile,
        offlineExtras: [String]
    ) -> [String] {
        switch profile.aiFallbackMode {
        case .off:
            return Array(primary.prefix(1))
        case .offlineOnly, .ask:
            var ids = primary
            for id in offlineExtras where !ids.contains(id) {
                ids.append(id)
            }
            if profile.remoteAIEnabled, !ids.contains(AIProviderID.remote.rawValue) {
                // Remote never auto-appended for hybrid; only if explicitly preferred elsewhere.
            }
            return ids
        }
    }

    private func provider(for id: String, profile: UserProfile) -> (any LanguageModelServicing)? {
        switch AIProviderID(rawValue: id) {
        case .foundationModels:
            return foundation
        case .hybrid:
            return foundation
        case .mlx:
            guard mlx?.isReady == true else { return nil }
            return mlx
        case .remote:
            guard profile.remoteAIEnabled else { return nil }
            return remote
        case .none:
            return nil
        }
    }

    private func shouldFallback(error: LanguageModelError, mode: AIFallbackMode) -> Bool {
        switch mode {
        case .off: return false
        case .offlineOnly, .ask:
            switch error {
            case .providerUnavailable, .networkUnreachable, .rateLimited, .remoteOptInRequired:
                return true
            default:
                return false
            }
        }
    }
}
