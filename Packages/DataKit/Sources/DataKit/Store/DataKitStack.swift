import Foundation
import Domain

/// Convenience bundle of SwiftData-backed repositories for the composition root.
public struct DataKitStack: Sendable {
    public let store: SwiftDataStore
    public let library: LibraryRepositoryWithFiles
    public let vocabulary: VocabularySwiftDataRepository
    public let sessions: SessionSwiftDataRepository
    public let settings: SettingsSwiftDataRepository
    public let explanationCache: ExplanationCacheSwiftDataRepository

    public init(store: SwiftDataStore) {
        self.store = store
        let libraryRepo = LibrarySwiftDataRepository(modelContainer: store.container)
        self.library = LibraryRepositoryWithFiles(repository: libraryRepo, fileStore: store.fileStore)
        self.vocabulary = VocabularySwiftDataRepository(modelContainer: store.container)
        self.sessions = SessionSwiftDataRepository(modelContainer: store.container)
        self.settings = SettingsSwiftDataRepository(modelContainer: store.container)
        self.explanationCache = ExplanationCacheSwiftDataRepository(modelContainer: store.container)
    }

    public static func makeInMemory() throws -> DataKitStack {
        DataKitStack(store: try SwiftDataStore.makeInMemory())
    }

    public static func makePersistent() throws -> DataKitStack {
        DataKitStack(store: try SwiftDataStore.makePersistent())
    }
}
