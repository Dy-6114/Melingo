import Foundation
import SwiftData
import Testing
@testable import DataKit
import Domain

@Suite("DocumentFileStore")
struct DocumentFileStoreTests {
    @Test("stores and reads binary under document folder")
    func storesBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-files-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentFileStore(rootDirectory: root)
        try store.ensureRootExists()
        let id = UUID()

        let relative = try store.store(data: Data("epub-bytes".utf8), documentID: id, fileExtension: "epub")
        #expect(relative.hasSuffix("/original.epub"))
        let read = try store.read(relativePath: relative)
        #expect(String(data: read, encoding: .utf8) == "epub-bytes")

        try store.deleteAll(for: id)
        #expect(!FileManager.default.fileExists(atPath: store.absoluteURL(for: relative).path))
    }

    @Test("stores page previews and reports count")
    func storesPagePreviews() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-previews-\(UUID().uuidString)", isDirectory: true)
        let store = DocumentFileStore(rootDirectory: root)
        try store.ensureRootExists()
        let id = UUID()

        let paths = try store.storePagePreviews(
            [
                (pageIndex: 1, pngData: Data([0x89, 0x50, 0x4E, 0x47])),
                (pageIndex: 0, pngData: Data([0x89, 0x50, 0x4E, 0x47])),
            ],
            documentID: id
        )
        #expect(paths.count == 2)
        #expect(paths[0].hasSuffix("/previews/page-0.png"))
        #expect(store.pagePreviewCount(for: id) == 2)
        #expect(store.pagePreviewURL(documentID: id, pageIndex: 0) != nil)
        #expect(store.pagePreviewURL(documentID: id, pageIndex: 9) == nil)

        try store.deleteAll(for: id)
        #expect(store.pagePreviewCount(for: id) == 0)
    }
}

@Suite("LibrarySwiftDataRepository")
struct LibraryRepositoryTests {
    @Test("retired channel imports remain readable as plain text")
    @MainActor
    func retiredChannelImport() async throws {
        let stack = try DataKitStack.makeInMemory()
        let context = ModelContext(stack.store.container)
        let id = UUID()
        let model = DocumentModel(
            id: id,
            title: "Imported channel",
            sourceKindRaw: "telegram",
            sourceURL: "@saved-channel",
            storedFileRelativePath: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let segment = TextSegment(
            documentID: id, order: 0, text: "A saved post.",
            translation: "一篇已保存的帖子。", isNewParagraph: true
        )
        model.segments = [TextSegmentMapper.makeModel(from: segment, document: model)]
        context.insert(model)
        try context.save()

        let document = try #require(try await stack.library.fetchDocuments().first)
        #expect(document.id == id)
        #expect(document.title == "Imported channel")
        #expect(document.sourceKind == .plainText)
        let segments = try await stack.library.fetchSegments(for: id)
        #expect(segments.map(\.text) == [segment.text])
        #expect(segments.first?.translation == segment.translation)

        try await stack.library.save(document: document, segments: segments)
        #expect(try await stack.library.fetchDocuments().first?.sourceKind == .plainText)
        #expect(try await stack.library.fetchSegments(for: id).first?.text == segment.text)
    }

    @Test("save fetch and delete documents with segments")
    func roundTrip() async throws {
        let stack = try DataKitStack.makeInMemory()
        let document = Document(title: "Basho", sourceKind: .plainText)
        let segments = [
            TextSegment(documentID: document.id, order: 1, text: "second"),
            TextSegment(documentID: document.id, order: 0, text: "first", isNewParagraph: true),
        ]

        try await stack.library.save(document: document, segments: segments)

        let listed = try await stack.library.fetchDocuments()
        #expect(listed.count == 1)
        #expect(listed[0].title == "Basho")

        let loadedSegments = try await stack.library.fetchSegments(for: document.id)
        #expect(loadedSegments.map(\.text) == ["first", "second"])

        try await stack.library.delete(document.id)
        #expect(try await stack.library.fetchDocuments().isEmpty)
    }

    @Test("persists segment explanation for library progress")
    func persistsExplanation() async throws {
        let stack = try DataKitStack.makeInMemory()
        let document = Document(title: "Progress", sourceKind: .plainText)
        var segments = [
            TextSegment(documentID: document.id, order: 0, text: "一句目。", isNewParagraph: true),
            TextSegment(documentID: document.id, order: 1, text: "二句目。"),
        ]
        try await stack.library.save(document: document, segments: segments)

        segments[0].explanation = "grammar note"
        segments[0].translation = "First."
        try await stack.library.save(document: document, segments: segments)

        let loaded = try await stack.library.fetchSegments(for: document.id)
        #expect(loaded[0].explanation == "grammar note")
        #expect(loaded[0].translation == "First.")
        #expect(loaded[1].explanation == nil)

        let progress = DocumentLearningProgress.of(loaded)
        #expect(progress.explained == 1)
        #expect(progress.total == 2)
    }
}

@Suite("VocabularySwiftDataRepository")
struct VocabularyRepositoryTests {
    @Test("upsert filters by language and records review")
    func upsertAndReview() async throws {
        let stack = try DataKitStack.makeInMemory()
        let pair = LanguagePair(source: "ja", target: "en")
        let entry = VocabularyEntry(word: "蛙", meaning: "frog", languagePair: pair)

        try await stack.vocabulary.upsert(entry)
        let fetched = try await stack.vocabulary.fetchEntries(for: pair)
        #expect(fetched.count == 1)

        var scheduled = entry
        scheduled.srsState = .learning
        scheduled.stability = 2.3
        scheduled.difficulty = 5.0
        scheduled.dueDate = "2099-01-01"
        scheduled.lastReviewedAt = .now
        scheduled.reviewCount = 1
        try await stack.vocabulary.applyReview(
            scheduled,
            result: ReviewResult(vocabularyID: entry.id, grade: 3)
        )
        let after = try await stack.vocabulary.fetchEntries(for: pair)
        #expect(after[0].reviewCount == 1)
        #expect(after[0].srsState == .learning)
        #expect(after[0].dueDate == "2099-01-01")
        #expect(abs(after[0].stability - 2.3) < 0.001)
    }
}

@Suite("Settings and cache")
struct SettingsAndCacheTests {
    @Test("profile defaults then updates")
    func profileRoundTrip() async throws {
        let stack = try DataKitStack.makeInMemory()
        let initial = try await stack.settings.loadProfile()
        #expect(initial.preferredLanguagePair.source == "ja")

        var updated = initial
        updated.remoteAIEnabled = true
        updated.activeAIProviderID = "mlx"
        updated.aiFallbackMode = .ask
        try await stack.settings.saveProfile(updated)

        let loaded = try await stack.settings.loadProfile()
        #expect(loaded.remoteAIEnabled)
        #expect(loaded.activeAIProviderID == "mlx")
        #expect(loaded.aiFallbackMode == .ask)
    }

    @Test("explanation cache store hit and invalidate")
    func explanationCache() async throws {
        let stack = try DataKitStack.makeInMemory()
        let key = ExplanationCacheKey(
            sourceTextHash: "abc",
            targetLanguage: "en",
            promptVersion: "v1",
            providerID: "mock"
        )
        let explanation = AIExplanation(
            breakdown: GrammarBreakdown(translation: "hi", summary: "cached")
        )

        try await stack.explanationCache.store(explanation, forKey: key)
        let hit = try await stack.explanationCache.explanation(forKey: key)
        #expect(hit?.breakdown.summary == "cached")

        try await stack.explanationCache.invalidate(matching: "abc")
        let miss = try await stack.explanationCache.explanation(forKey: key)
        #expect(miss == nil)
    }
}

@Suite("SessionSwiftDataRepository")
struct SessionRepositoryTests {
    @Test("records and queries by date range")
    func sessionRange() async throws {
        let stack = try DataKitStack.makeInMemory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ReadingSession(
            documentID: UUID(),
            dateLocal: "2023-11-14",
            startedAt: start,
            seconds: 120
        )
        try await stack.sessions.record(session)

        let found = try await stack.sessions.fetchSessions(
            from: start.addingTimeInterval(-10),
            to: start.addingTimeInterval(10)
        )
        #expect(found.count == 1)
        #expect(found[0].seconds == 120)
    }
}

@Suite("Store durability")
struct StoreDurabilityTests {
    @Test("pre-open backup copies store without deleting live file")
    func backupDoesNotWipe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-bak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("Melingo.store")
        try Data("live-store".utf8).write(to: storeURL)
        SwiftDataStore.backupStoreFiles(at: storeURL)

        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        let bak = URL(fileURLWithPath: storeURL.path + ".bak")
        #expect(FileManager.default.fileExists(atPath: bak.path))
        #expect(try String(contentsOf: bak, encoding: .utf8) == "live-store")
    }

    @Test("V2 schema opens in-memory and persists twin fields")
    func twinFieldsRoundTrip() async throws {
        let stack = try DataKitStack.makeInMemory()
        let pair = LanguagePair(source: "fr", target: "en")
        let pairID = UUID()
        let forward = VocabularyEntry(
            word: "chat",
            meaning: "cat",
            languagePair: pair,
            pairID: pairID,
            direction: .forward
        )
        let reverse = VocabularyEntry(
            word: "cat",
            meaning: "chat",
            languagePair: pair,
            pairID: pairID,
            direction: .reverse
        )
        try await stack.vocabulary.upsert(forward)
        try await stack.vocabulary.upsert(reverse)
        let loaded = try await stack.vocabulary.fetchEntries(for: pair)
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { $0.pairID == pairID })
        #expect(Set(loaded.compactMap(\.direction)) == [.forward, .reverse])
        #expect(loaded.first(where: { $0.direction == .forward })?.normalizedWord == "chat")
    }

    @Test("updateSegment patches one row")
    func updateSegmentPatch() async throws {
        let stack = try DataKitStack.makeInMemory()
        let document = Document(title: "Patch", sourceKind: .plainText)
        var segments = [
            TextSegment(documentID: document.id, order: 0, text: "a", isNewParagraph: true),
            TextSegment(documentID: document.id, order: 1, text: "b"),
        ]
        try await stack.library.save(document: document, segments: segments)
        segments[0].translation = "A"
        try await stack.library.updateSegment(segments[0])
        let loaded = try await stack.library.fetchSegments(for: document.id)
        #expect(loaded[0].translation == "A")
        #expect(loaded[1].translation == nil)
    }
}

