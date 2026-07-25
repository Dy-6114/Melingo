import Foundation

public protocol SettingsRepository: Sendable {
    func loadProfile() async throws -> UserProfile
    func saveProfile(_ profile: UserProfile) async throws
}
