import Foundation
import Domain

/// Shared across Melingo apps (Lab + main) — lives in `~/Documents/Melingo`, not app UserDefaults.
struct LibraryBootstrapPrefs: Codable, Equatable, Sendable {
    var defaultTagsSeeded: Bool
    var suppressedDefaultTagNames: [String]

    static let empty = LibraryBootstrapPrefs(defaultTagsSeeded: false, suppressedDefaultTagNames: [])

    static var fileURL: URL {
        MelingoPaths.root.appendingPathComponent("library-bootstrap.json", isDirectory: false)
    }

    static func load() -> LibraryBootstrapPrefs {
        MelingoPaths.ensureRoot()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(LibraryBootstrapPrefs.self, from: data)
        else {
            return migrateFromUserDefaultsIfNeeded()
        }
        return decoded
    }

    func save() {
        MelingoPaths.ensureRoot()
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// One-shot: pull Lab/main UserDefaults seed flag into the shared sidecar.
    private static func migrateFromUserDefaultsIfNeeded() -> LibraryBootstrapPrefs {
        let udKey = "library.defaultTagsSeeded"
        let seeded = UserDefaults.standard.bool(forKey: udKey)
        var prefs = LibraryBootstrapPrefs.empty
        if seeded {
            prefs.defaultTagsSeeded = true
            prefs.save()
        }
        return prefs
    }
}
