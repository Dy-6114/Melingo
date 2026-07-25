import Foundation
import Domain

public actor MockExplanationCacheRepository: ExplanationCacheRepository {
    public var storage: [ExplanationCacheKey: AIExplanation] = [:]

    public init() {}

    public func explanation(forKey key: ExplanationCacheKey) async throws -> AIExplanation? {
        storage[key]
    }

    public func store(_ explanation: AIExplanation, forKey key: ExplanationCacheKey) async throws {
        storage[key] = explanation
    }

    public func invalidate(matching sourceTextHash: String) async throws {
        storage = storage.filter { $0.key.sourceTextHash != sourceTextHash }
    }
}
