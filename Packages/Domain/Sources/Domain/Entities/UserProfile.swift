import Foundation

public struct UserProfile: Codable, Sendable, Hashable {
    public var preferredLanguagePair: LanguagePair
    public var uiLocale: String
    /// Opt-in remote AI; default false (on-device first).
    public var remoteAIEnabled: Bool
    /// Preferred backend: `foundation-models` | `mlx` | `remote`.
    public var activeAIProviderID: String
    /// When preferred is unavailable — see `AIFallbackMode`.
    public var aiFallbackMode: AIFallbackMode
    public var hasCompletedOnboarding: Bool
    public var displayName: String?
    public var avatarRelativePath: String?

    public init(
        preferredLanguagePair: LanguagePair,
        uiLocale: String = AppLocale.defaultUILocale(),
        remoteAIEnabled: Bool = false,
        activeAIProviderID: String = AIProviderID.foundationModels.rawValue,
        aiFallbackMode: AIFallbackMode = .offlineOnly,
        hasCompletedOnboarding: Bool = false,
        displayName: String? = nil,
        avatarRelativePath: String? = nil
    ) {
        self.preferredLanguagePair = preferredLanguagePair
        self.uiLocale = uiLocale
        self.remoteAIEnabled = remoteAIEnabled
        self.activeAIProviderID = activeAIProviderID
        self.aiFallbackMode = aiFallbackMode
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.displayName = displayName
        self.avatarRelativePath = avatarRelativePath
    }

    public var preferredAIProvider: AIProviderID {
        AIProviderID(rawValue: activeAIProviderID) ?? .foundationModels
    }
}
