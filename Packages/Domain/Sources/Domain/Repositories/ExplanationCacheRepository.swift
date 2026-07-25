import Foundation

/// Cached AI explanation keyed by content hash (TZ technical decision §3).
public protocol ExplanationCacheRepository: Sendable {
    func explanation(forKey key: ExplanationCacheKey) async throws -> AIExplanation?
    func store(_ explanation: AIExplanation, forKey key: ExplanationCacheKey) async throws
    func invalidate(matching sourceTextHash: String) async throws
}

public struct ExplanationCacheKey: Codable, Sendable, Hashable {
    public var sourceTextHash: String
    public var targetLanguage: String
    public var promptVersion: String
    public var providerID: String?

    public init(
        sourceTextHash: String,
        targetLanguage: String,
        promptVersion: String,
        providerID: String? = nil
    ) {
        self.sourceTextHash = sourceTextHash
        self.targetLanguage = targetLanguage
        self.promptVersion = promptVersion
        self.providerID = providerID
    }
}
