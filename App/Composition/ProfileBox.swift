import Foundation
import Domain

/// Thread-safe snapshot of UserProfile for AIKit callbacks.
final class ProfileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UserProfile

    init(_ value: UserProfile) {
        self.value = value
    }

    func get() -> UserProfile {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ value: UserProfile) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
