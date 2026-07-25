import Foundation

/// Canonical on-disk home for all Melingo user data.
///
/// Lives in `~/Documents/Melingo` so learning content (library, translations,
/// vocabulary, covers, voice recordings, Gemma weights) survives deleting or
/// reinstalling the `.app` bundle. Older builds used Application Support;
/// `ensureRoot()` migrates that tree once.
public enum MelingoPaths {
    public static let folderName = "Melingo"

    /// `~/Documents/Melingo`
    public static var root: URL {
        documentsBase.appendingPathComponent(folderName, isDirectory: true)
    }

    public static var storeURL: URL {
        root.appendingPathComponent("Melingo.store", isDirectory: false)
    }

    /// Imported originals, page previews, scene images, avatars.
    public static var documents: URL {
        root.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Downloaded MLX / Gemma weights.
    public static var models: URL {
        root.appendingPathComponent("Models", isDirectory: true)
    }

    /// Previous location (`~/Library/Application Support/Melingo`).
    public static var legacyApplicationSupportRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Creates `~/Documents/Melingo` and one-shot migrates from Application Support.
    @discardableResult
    public static func ensureRoot() -> URL {
        let fm = FileManager.default
        let dest = root
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        writeReadmeIfNeeded(at: dest)

        let legacy = legacyApplicationSupportRoot
        let marker = dest.appendingPathComponent(".migrated-from-app-support", isDirectory: false)
        if !fm.fileExists(atPath: marker.path), fm.fileExists(atPath: legacy.path) {
            migrateTree(from: legacy, to: dest)
            try? Data("ok\n".utf8).write(to: marker, options: .atomic)
            writeLegacyPointer(at: legacy, pointingTo: dest)
        }

        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        return dest
    }

    private static var documentsBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Documents", isDirectory: true)
    }

    /// Moves items from legacy → dest when the destination path is missing.
    /// Prefer `move` (fast for multi-GB Gemma); fall back to copy on failure.
    private static func migrateTree(from source: URL, to dest: URL) {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in kids {
            let name = child.lastPathComponent
            // Skip leftover journal noise if a previous run left an empty dest store.
            if name.hasPrefix(".") { continue }
            let target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                // Merge directories (e.g. Documents/ already partially present).
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                    migrateTree(from: child, to: target)
                }
                continue
            }
            do {
                try fm.moveItem(at: child, to: target)
            } catch {
                do {
                    try fm.copyItem(at: child, to: target)
                    try? fm.removeItem(at: child)
                } catch {
                    // Leave legacy in place; next launch will retry missing pieces.
                }
            }
        }
    }

    private static func writeReadmeIfNeeded(at root: URL) {
        let url = root.appendingPathComponent("README.txt", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        Melingo user data
        =================
        This folder holds your library, translations, vocabulary, images, voice
        recordings, and optional on-device AI models (Gemma / MLX).

        It is intentionally outside the Melingo.app bundle so deleting or updating
        the app does not erase your progress. Keep a backup of this folder if you
        want to move to another Mac.

        """
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func writeLegacyPointer(at legacy: URL, pointingTo dest: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let note = legacy.appendingPathComponent("MOVED.txt", isDirectory: false)
        let text = """
        Melingo data moved to:
        \(dest.path)

        You can delete this Application Support folder after confirming
        Documents/Melingo looks complete.
        """
        try? Data(text.utf8).write(to: note, options: .atomic)
    }
}
