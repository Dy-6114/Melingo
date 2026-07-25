import Foundation
import SwiftData
import Domain

public struct SwiftDataStore: Sendable {
    public let container: ModelContainer
    public let fileStore: DocumentFileStore

    public init(container: ModelContainer, fileStore: DocumentFileStore) {
        self.container = container
        self.fileStore = fileStore
    }

    /// Persistent store under `~/Documents/Melingo` (survives app reinstall).
    public static func makePersistent(
        appSupportSubdirectory: String = "Melingo"
    ) throws -> SwiftDataStore {
        // Parameter kept for call-site compatibility; folder name is always MelingoPaths.
        _ = appSupportSubdirectory
        let root = MelingoPaths.ensureRoot()
        let fileStore = DocumentFileStore(rootDirectory: MelingoPaths.documents)
        try fileStore.ensureRootExists()

        let storeURL = MelingoPaths.storeURL
        Self.backupStoreFiles(at: storeURL)
        do {
            return try Self.makePersistent(storeURL: storeURL, fileStore: fileStore)
        } catch {
            throw MelingoStoreOpenError.openFailed(
                underlying: error,
                storePath: storeURL.path,
                dataRootPath: root.path
            )
        }
    }

    /// In-memory store for unit tests.
    public static func makeInMemory(
        fileRoot: URL? = nil
    ) throws -> SwiftDataStore {
        let root = fileRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Melingo-Tests-\(UUID().uuidString)", isDirectory: true)
        let fileStore = DocumentFileStore(rootDirectory: root.appendingPathComponent("Documents", isDirectory: true))
        try fileStore.ensureRootExists()

        let schema = Schema(versionedSchema: MelingoSchemaV2.self)
        let config = ModelConfiguration(
            "MelingoInMemory",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: MelingoMigrationPlan.self,
            configurations: [config]
        )
        return SwiftDataStore(container: container, fileStore: fileStore)
    }

    private static func makePersistent(
        storeURL: URL,
        fileStore: DocumentFileStore
    ) throws -> SwiftDataStore {
        let schema = Schema(versionedSchema: MelingoSchemaV2.self)
        let config = ModelConfiguration(
            "Melingo",
            schema: schema,
            url: storeURL
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: MelingoMigrationPlan.self,
            configurations: [config]
        )
        return SwiftDataStore(container: container, fileStore: fileStore)
    }

    /// Pre-open safety copy. Never deletes the live store.
    static func backupStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return }
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dest = URL(fileURLWithPath: storeURL.path + ".bak" + suffix)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: src, to: dest)
        }
    }
}

/// Surfaced when the SwiftData container cannot open — data on disk is left intact.
public enum MelingoStoreOpenError: LocalizedError {
    case openFailed(underlying: Error, storePath: String, dataRootPath: String)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(underlying, storePath, dataRootPath):
            return """
            Couldn’t open the library database.

            Your data was not erased. Folder: \(dataRootPath)
            Store: \(storePath)
            Backup (if present): \(storePath).bak

            \(underlying.localizedDescription)
            """
        }
    }
}
