import Foundation
import SwiftData
import Domain

@ModelActor
public actor SettingsSwiftDataRepository: SettingsRepository {
    public func loadProfile() async throws -> UserProfile {
        if let existing = try fetchSingleton() {
            return UserProfileMapper.toEntity(existing)
        }
        let defaults = UserProfile(
            preferredLanguagePair: LanguagePair(source: "ja", target: "en")
        )
        modelContext.insert(UserProfileMapper.makeModel(from: defaults))
        try modelContext.save()
        return defaults
    }

    public func saveProfile(_ profile: UserProfile) async throws {
        if let existing = try fetchSingleton() {
            UserProfileMapper.apply(profile, to: existing)
        } else {
            modelContext.insert(UserProfileMapper.makeModel(from: profile))
        }
        try modelContext.save()
    }

    private func fetchSingleton() throws -> UserProfileModel? {
        let singletonID = UserProfileModel.singletonID
        var descriptor = FetchDescriptor<UserProfileModel>(
            predicate: #Predicate { $0.id == singletonID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
