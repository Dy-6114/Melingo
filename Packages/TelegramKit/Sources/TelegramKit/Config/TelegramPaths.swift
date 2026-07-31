import Foundation

/// On-disk layout under `~/Documents/Melingo/Telegram`.
public enum TelegramPaths {
    public static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melingo/Telegram", isDirectory: true)
    }

    public static var tdlibDirectory: URL {
        root.appendingPathComponent("tdlib", isDirectory: true)
    }

    public static var exportsDirectory: URL {
        root.appendingPathComponent("Exports", isDirectory: true)
    }

    public static var sessionKeyURL: URL {
        root.appendingPathComponent("session-key.txt")
    }

    @discardableResult
    public static func ensureDirectories() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: tdlibDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        return root
    }

    public static func loadOrCreateSessionKey() -> String {
        ensureDirectories()
        if let existing = try? String(contentsOf: sessionKeyURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let key = "primary"
        try? key.write(to: sessionKeyURL, atomically: true, encoding: .utf8)
        return key
    }

    public static func setSessionKey(_ key: String) {
        ensureDirectories()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "primary" : trimmed
        try? value.write(to: sessionKeyURL, atomically: true, encoding: .utf8)
    }

    public static func exportFolder(forUsername username: String) -> URL {
        let name = ChannelExporter.normalizeUsername(username)
        return exportsDirectory.appendingPathComponent(name, isDirectory: true)
    }
}
