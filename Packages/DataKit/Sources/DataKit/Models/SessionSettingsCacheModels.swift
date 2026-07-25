import Foundation
import SwiftData

@Model
final class ReadingSessionModel {
    @Attribute(.unique) var id: UUID
    var documentID: UUID?
    var dateLocal: String
    var startedAt: Date
    var seconds: Int

    init(id: UUID, documentID: UUID?, dateLocal: String, startedAt: Date, seconds: Int) {
        self.id = id
        self.documentID = documentID
        self.dateLocal = dateLocal
        self.startedAt = startedAt
        self.seconds = seconds
    }
}

@Model
final class UserProfileModel {
    @Attribute(.unique) var id: String
    var sourceLanguage: String
    var targetLanguage: String
    var uiLocale: String
    var remoteAIEnabled: Bool
    var activeAIProviderID: String
    var aiFallbackModeRaw: String
    var hasCompletedOnboarding: Bool
    var displayName: String?
    var avatarRelativePath: String?

    static let singletonID = "default"

    init(
        id: String = UserProfileModel.singletonID,
        sourceLanguage: String,
        targetLanguage: String,
        uiLocale: String,
        remoteAIEnabled: Bool,
        activeAIProviderID: String,
        aiFallbackModeRaw: String = "offlineOnly",
        hasCompletedOnboarding: Bool = false,
        displayName: String? = nil,
        avatarRelativePath: String? = nil
    ) {
        self.id = id
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.uiLocale = uiLocale
        self.remoteAIEnabled = remoteAIEnabled
        self.activeAIProviderID = activeAIProviderID
        self.aiFallbackModeRaw = aiFallbackModeRaw
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.displayName = displayName
        self.avatarRelativePath = avatarRelativePath
    }
}

@Model
final class ExplanationCacheModel {
    @Attribute(.unique) var id: UUID
    var sourceTextHash: String
    var targetLanguage: String
    var promptVersion: String
    var providerID: String?
    var payloadJSON: Data
    var storedAt: Date

    init(
        id: UUID = UUID(),
        sourceTextHash: String,
        targetLanguage: String,
        promptVersion: String,
        providerID: String?,
        payloadJSON: Data,
        storedAt: Date = .now
    ) {
        self.id = id
        self.sourceTextHash = sourceTextHash
        self.targetLanguage = targetLanguage
        self.promptVersion = promptVersion
        self.providerID = providerID
        self.payloadJSON = payloadJSON
        self.storedAt = storedAt
    }
}
