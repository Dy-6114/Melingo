import Foundation
import Domain

/// ZIP backup / restore for `~/Documents/Melingo` (store + Documents + model metadata).
public enum MelingoBackupService {
    public struct Manifest: Codable, Sendable {
        public var schemaVersion: String
        public var exportedAt: Date
        public var appVersion: String

        public init(schemaVersion: String, exportedAt: Date = .now, appVersion: String) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.appVersion = appVersion
        }
    }

    public enum BackupError: LocalizedError {
        case exportFailed(String)
        case importFailed(String)
        case missingStore

        public var errorDescription: String? {
            switch self {
            case .exportFailed(let message): return message
            case .importFailed(let message): return message
            case .missingStore: return "No Melingo.store found to back up."
            }
        }
    }

    /// Creates a ZIP at `destination` containing store sidecars, Documents/, Models metadata, manifest.
    public static func exportZIP(
        to destination: URL,
        appVersion: String,
        schemaVersion: String = "1.4.0"
    ) throws {
        let root = MelingoPaths.ensureRoot()
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("Melingo-Backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Store + SQLite sidecars
        let storeURL = MelingoPaths.storeURL
        guard fm.fileExists(atPath: storeURL.path) else { throw BackupError.missingStore }
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(
                at: src,
                to: staging.appendingPathComponent(src.lastPathComponent)
            )
        }

        // Documents/
        let docsDest = staging.appendingPathComponent("Documents", isDirectory: true)
        if fm.fileExists(atPath: MelingoPaths.documents.path) {
            try fm.copyItem(at: MelingoPaths.documents, to: docsDest)
        } else {
            try fm.createDirectory(at: docsDest, withIntermediateDirectories: true)
        }

        // Models metadata only (skip weight blobs)
        let modelsDest = staging.appendingPathComponent("Models", isDirectory: true)
        try fm.createDirectory(at: modelsDest, withIntermediateDirectories: true)
        if fm.fileExists(atPath: MelingoPaths.models.path),
           let kids = try? fm.contentsOfDirectory(
            at: MelingoPaths.models,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for child in kids {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: child.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let destDir = modelsDest.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    if let files = try? fm.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        for file in files {
                            let name = file.lastPathComponent.lowercased()
                            if name.hasSuffix(".safetensors") || name.hasSuffix(".gguf") { continue }
                            try? fm.copyItem(
                                at: file,
                                to: destDir.appendingPathComponent(file.lastPathComponent)
                            )
                        }
                    }
                } else {
                    let name = child.lastPathComponent.lowercased()
                    if name.hasSuffix(".safetensors") || name.hasSuffix(".gguf") { continue }
                    try? fm.copyItem(
                        at: child,
                        to: modelsDest.appendingPathComponent(child.lastPathComponent)
                    )
                }
            }
        }

        let manifest = Manifest(schemaVersion: schemaVersion, appVersion: appVersion)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try zipDirectory(staging, to: destination)
        _ = root
    }

    /// Restores a Melingo backup ZIP into `~/Documents/Melingo`. Caller should relaunch.
    public static func importZIP(from source: URL) throws {
        let fm = FileManager.default
        let root = MelingoPaths.ensureRoot()
        let staging = fm.temporaryDirectory
            .appendingPathComponent("Melingo-Restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try unzipArchive(source, to: staging)

        let storeName = MelingoPaths.storeURL.lastPathComponent
        let stagedStore = staging.appendingPathComponent(storeName)
        guard fm.fileExists(atPath: stagedStore.path) else {
            throw BackupError.importFailed("ZIP is missing Melingo.store")
        }

        // Pre-restore safety copy of live store
        let liveStore = MelingoPaths.storeURL
        if fm.fileExists(atPath: liveStore.path) {
            for suffix in ["", "-shm", "-wal"] {
                let src = URL(fileURLWithPath: liveStore.path + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dest = URL(fileURLWithPath: liveStore.path + ".pre-restore.bak" + suffix)
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
            }
        }

        for suffix in ["", "-shm", "-wal"] {
            let staged = URL(fileURLWithPath: stagedStore.path + suffix)
            let live = URL(fileURLWithPath: liveStore.path + suffix)
            if fm.fileExists(atPath: live.path) {
                try fm.removeItem(at: live)
            }
            if fm.fileExists(atPath: staged.path) {
                try fm.copyItem(at: staged, to: live)
            }
        }

        let stagedDocs = staging.appendingPathComponent("Documents", isDirectory: true)
        if fm.fileExists(atPath: stagedDocs.path) {
            let liveDocs = MelingoPaths.documents
            if fm.fileExists(atPath: liveDocs.path) {
                try fm.removeItem(at: liveDocs)
            }
            try fm.copyItem(at: stagedDocs, to: liveDocs)
        }

        let stagedModels = staging.appendingPathComponent("Models", isDirectory: true)
        if fm.fileExists(atPath: stagedModels.path) {
            try mergeDirectory(from: stagedModels, to: MelingoPaths.models)
        }

        _ = root
    }

    // MARK: - ZIP via ditto (macOS)

    private static func zipDirectory(_ directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, destination.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
            throw BackupError.exportFailed(msg)
        }
    }

    private static func unzipArchive(_ archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
            throw BackupError.importFailed(msg)
        }

        // ditto --keepParent may nest an extra folder; flatten if needed.
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), kids.count == 1 {
            var isDir: ObjCBool = false
            let only = kids[0]
            if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir),
               isDir.boolValue,
               !FileManager.default.fileExists(atPath: only.appendingPathComponent("Melingo.store").path) {
                // keep as-is when store is at staging root after extract
            }
            // If store is inside the single child folder, move children up.
            let nestedStore = only.appendingPathComponent("Melingo.store")
            if isDir.boolValue, FileManager.default.fileExists(atPath: nestedStore.path) {
                for child in (try? FileManager.default.contentsOfDirectory(
                    at: only, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? [] {
                    let dest = directory.appendingPathComponent(child.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: child, to: dest)
                }
            }
        }
    }

    private static func mergeDirectory(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let kids = try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in kids {
            let target = dest.appendingPathComponent(child.lastPathComponent)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &isDir)
            if isDir.boolValue {
                try mergeDirectory(from: child, to: target)
            } else {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: child, to: target)
            }
        }
    }
}
