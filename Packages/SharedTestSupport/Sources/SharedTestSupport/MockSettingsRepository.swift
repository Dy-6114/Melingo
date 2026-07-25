import Foundation
import Domain

public actor MockSettingsRepository: SettingsRepository {
    public var profile: UserProfile

    public init(profile: UserProfile = UserProfile(
        preferredLanguagePair: LanguagePair(source: "ja", target: "en")
    )) {
        self.profile = profile
    }

    public func loadProfile() async throws -> UserProfile { profile }

    public func saveProfile(_ profile: UserProfile) async throws {
        self.profile = profile
    }
}
