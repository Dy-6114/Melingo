import Foundation
import Observation
import Domain
import DataKit
import ContentImportKit
import AIKit
#if canImport(MLXAdapter)
import MLXAdapter
#endif

/// In-memory UI store backed by real DataKit — no seed / sample content.
@MainActor
@Observable
final class AppLibraryStore {
    private(set) var documents: [Document] = []
    private(set) var segmentsByDocument: [Document.ID: [TextSegment]] = [:]
    private(set) var vocabulary: [VocabularyEntry] = []
    private(set) var packs: [WordPack] = []
    private(set) var profile: UserProfile
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var explainingSegmentIDs: Set<UUID> = []
    private(set) var batchByDocument: [Document.ID: BatchState] = [:]

    /// Cards produced by `generatePackCards(topic:)`, awaiting confirmation into a pack.
    private(set) var generatedDraft: PackImportDraft?
    private(set) var isGeneratingPack = false
    /// Sheet-local pack errors — do not drive the global red banner.
    private(set) var packGenerationError: String?
    /// Live progress while generating / localizing cards.
    private(set) var packGenerationProgress: PackGenProgress?

    struct PackGenProgress: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            case requesting
            case translating(done: Int, total: Int)
        }
        var phase: Phase
        var cardCountHint: Int?
    }

    /// In-flight whole-document AI job (progress bar + cancel).
    struct BatchState: Sendable, Equatable {
        var kind: DocumentBatchKind
        var completed: Int
        var total: Int
        var failed: Int
    }

    var remoteSettings: RemoteAISettings {
        didSet { RemoteConfigStorage.save(remoteSettings) }
    }

    /// Legacy flat view for simple bindings.
    var remoteConfig: RemoteModelConfig {
        get { RemoteConfigStorage.loadLegacyBridge() }
        set {
            var settings = remoteSettings
            settings.enabled = newValue.enabled
            if var cfg = settings.defaultConfig {
                cfg.name = newValue.displayName
                cfg.model = newValue.model
                cfg.baseURL = newValue.baseURL
                cfg.apiProvider = newValue.providerID
                settings.configs = settings.configs.map { $0.id == cfg.id ? cfg : $0 }
                if settings.configs.isEmpty { settings.configs = [newValue.asModelConfig()] }
            } else {
                settings.configs = [newValue.asModelConfig()]
            }
            remoteSettings = settings
        }
    }

    /// Pending Ask-mode fallback confirmation.
    private(set) var pendingFallback: (preferred: String, fallback: String)?
    private(set) var lastExplanationFromCache = false

    /// Cards due for review today (new + review, capped).
    var dueQueue: [VocabularyEntry] {
        VocabularyScheduling.dueQueue(
            from: vocabulary,
            newLimit: SRSPrefs.dailyNewLimit,
            reviewLimit: SRSPrefs.dailyReviewLimit
        )
    }

    var dueCount: Int { dueQueue.count }

    var newDueCount: Int {
        dueQueue.filter { $0.srsState == .new }.count
    }

    var reviewDueCount: Int {
        dueQueue.filter { $0.srsState != .new }.count
    }

    /// Cards whose last review falls on the local calendar day.
    var reviewedTodayCount: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return vocabulary.filter { ($0.lastReviewedAt ?? .distantPast) >= start }.count
    }

    /// Consecutive local days with at least one card last-reviewed that day.
    /// Approximate (per-card last review only) — good enough for hub motivation.
    var studyStreakDays: Int {
        let cal = Calendar.current
        let reviewedDays: Set<Date> = Set(
            vocabulary.compactMap { entry in
                guard let at = entry.lastReviewedAt else { return nil }
                return cal.startOfDay(for: at)
            }
        )
        guard !reviewedDays.isEmpty else { return 0 }

        var day = cal.startOfDay(for: .now)
        if !reviewedDays.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            if !reviewedDays.contains(day) { return 0 }
        }

        var streak = 0
        while reviewedDays.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    func dismissError() {
        lastError = nil
    }

    /// Learned (not new) vs total cards in a pack — for AI pack progress bars.
    func packLearningProgress(for pack: WordPack) -> (learned: Int, total: Int) {
        let cards = vocabulary.filter { $0.packIDs.contains(pack.id) }
        // "Started" (left .new) — not mastery. UI string: packs.progress.
        let learned = cards.filter { $0.srsState != .new }.count
        return (learned, cards.count)
    }

    @ObservationIgnored private let stack: DataKitStack
    @ObservationIgnored private let importRouter: ContentImportRouter
    @ObservationIgnored private let model: any LanguageModelServicing
    @ObservationIgnored private let router: LanguageModelRouter?
    @ObservationIgnored private let profileBox: ProfileBox
    @ObservationIgnored private var batchTasks: [Document.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var askTask: Task<String, Error>?

    init(stack: DataKitStack, model: (any LanguageModelServicing)? = nil) {
        self.stack = stack
        self.importRouter = ContentImportRouter()
        let initialProfile = UserProfile(
            preferredLanguagePair: LanguagePair(source: "ja", target: "en")
        )
        self.profile = initialProfile
        self.profileBox = ProfileBox(initialProfile)
        self.remoteSettings = RemoteConfigStorage.load()

        if let model {
            self.model = model
            self.router = nil
        } else {
            let remote = RemoteAPIProvider(
                settingsProvider: { RemoteConfigStorage.load() },
                apiKeyProvider: { id in
                    APIKeyStore.load(account: APIKeyStore.account(for: id))
                        ?? APIKeyStore.load()
                }
            )
            let box = profileBox
            let built = LanguageModelRouter(
                foundation: FoundationModelsProvider(),
                mlx: Self.makeMLXProvider(),
                remote: remote,
                profileProvider: { box.get() }
            )
            self.router = built
            self.model = built
        }
    }

    private static func makeMLXProvider() -> (any LanguageModelServicing)? {
        #if canImport(MLXAdapter)
        return MLXProvider() as any LanguageModelServicing
        #else
        return nil
        #endif
    }

    static func live() throws -> AppLibraryStore {
        AppLibraryStore(stack: try DataKitStack.makePersistent())
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await stack.settings.loadProfile()
            profile = loaded
            profileBox.set(loaded)
            AppL10n.sync(from: loaded)
            documents = try await stack.library.fetchDocuments()
            var map: [Document.ID: [TextSegment]] = [:]
            for doc in documents {
                map[doc.id] = try await stack.library.fetchSegments(for: doc.id)
            }
            segmentsByDocument = map
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            await backfillNormalizedWordsIfNeeded()
            await ensureDefaultTagPacks()
            await ReviewReminderService.reschedule(dueCountHint: dueCount)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// One-shot fill after Schema V2 migration (optional fields default to nil).
    private func backfillNormalizedWordsIfNeeded() async {
        var changed = false
        for i in vocabulary.indices {
            let expected = VocabularyEntry.normalizeWord(vocabulary[i].word)
            if vocabulary[i].normalizedWord != expected {
                vocabulary[i].normalizedWord = expected
                do {
                    try await stack.vocabulary.upsert(vocabulary[i])
                    changed = true
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        if changed {
            vocabulary = (try? await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)) ?? vocabulary
        }
    }

    /// Language model used for AI pack generation — same router as reading features.
    var languageModel: any LanguageModelServicing { model }

    func segments(for id: Document.ID) -> [TextSegment] {
        segmentsByDocument[id] ?? []
    }

    func progress(for id: Document.ID) -> DocumentLearningProgress {
        DocumentLearningProgress.of(segments(for: id))
    }

    func isBatchRunning(documentID: Document.ID) -> Bool {
        batchTasks[documentID] != nil
    }

    func batchExplainAll(documentID: Document.ID) {
        startBatch(documentID, kind: .explain)
    }

    func batchTranslateAll(documentID: Document.ID) {
        startBatch(documentID, kind: .translate)
    }

    func cancelBatch(documentID: Document.ID) {
        batchTasks[documentID]?.cancel()
        batchTasks[documentID] = nil
        batchByDocument[documentID] = nil
    }

    @discardableResult
    func importSource(_ source: ImportSource) async -> Document? {
        do {
            let imported = try await importRouter.importContent(from: source)
            var document = imported.document
            if let staging = imported.stagingFileURL {
                let scoped = staging.startAccessingSecurityScopedResource()
                defer { if scoped { staging.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: staging) {
                    let ext = staging.pathExtension.isEmpty ? "bin" : staging.pathExtension
                    document.storedFileRelativePath = try stack.store.fileStore.store(
                        data: data, documentID: document.id, fileExtension: ext)
                }
            }
            if !imported.pagePreviews.isEmpty {
                _ = try stack.store.fileStore.storePagePreviews(
                    imported.pagePreviews.map { ($0.pageIndex, $0.pngData) },
                    documentID: document.id
                )
            }
            if !imported.illustrations.isEmpty {
                try stack.store.fileStore.storeIllustrations(imported.illustrations, documentID: document.id)
                // Warm cache in background so the reader opens with local files.
                Task.detached(priority: .utility) { [fileStore = stack.store.fileStore, docID = document.id] in
                    await Self.prefetchSceneImages(imported.illustrations, documentID: docID, fileStore: fileStore)
                }
            }
            try await stack.library.save(document: document, segments: imported.segments)
            await load()
            lastError = nil
            return documents.first(where: { $0.id == document.id }) ?? document
        } catch {
            lastError = Self.describeImport(error)
            return nil
        }
    }

    /// Persist YouTube video metadata (cues JSON) + transcript segments.
    func saveYouTubeVideo(
        document: inout Document,
        segments: [TextSegment],
        payloadData: Data
    ) async throws {
        document.storedFileRelativePath = try stack.store.fileStore.store(
            data: payloadData,
            documentID: document.id,
            fileExtension: "youtube.json"
        )
        try await stack.library.save(document: document, segments: segments)
        await load()
        lastError = nil
    }

    func readDocumentFile(relativePath: String) throws -> Data {
        try stack.store.fileStore.read(relativePath: relativePath)
    }

    func pagePreviewURL(for documentID: Document.ID, pageIndex: Int = 0) -> URL? {
        stack.store.fileStore.pagePreviewURL(documentID: documentID, pageIndex: pageIndex)
    }

    func pagePreviewCount(for documentID: Document.ID) -> Int {
        stack.store.fileStore.pagePreviewCount(for: documentID)
    }

    func illustrations(for documentID: Document.ID) -> [ArticleIllustration] {
        stack.store.fileStore.loadIllustrations(documentID: documentID)
    }

    func sceneImageURL(for documentID: Document.ID, illustrationID: UUID) -> URL? {
        stack.store.fileStore.sceneImageURL(documentID: documentID, illustrationID: illustrationID)
    }

    private static func prefetchSceneImages(
        _ items: [ArticleIllustration],
        documentID: UUID,
        fileStore: DocumentFileStore
    ) async {
        for item in items {
            if fileStore.sceneImageURL(documentID: documentID, illustrationID: item.id) != nil { continue }
            guard let url = URL(string: item.remoteURL) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continue
                }
                guard !data.isEmpty, data.count < 8_000_000 else { continue }
                _ = try? fileStore.storeSceneImage(data: data, documentID: documentID, illustrationID: item.id)
            } catch {
                continue
            }
        }
    }

    func deleteDocument(_ id: Document.ID) async {
        do {
            try await stack.library.delete(id)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Optional title override after import.
    func renameDocument(_ id: Document.ID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var document = documents.first(where: { $0.id == id }) else { return }
        document.title = trimmed
        document.updatedAt = .now
        let segments = segmentsByDocument[id] ?? []
        do {
            try await stack.library.save(document: document, segments: segments)
            if let idx = documents.firstIndex(where: { $0.id == id }) {
                documents[idx] = document
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProfile(_ profile: UserProfile) async {
        var updated = profile
        // Keep interface language aligned with the user's native (explanation) language.
        let native = updated.preferredLanguagePair.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !native.isEmpty {
            updated.uiLocale = native
        }
        do {
            try await stack.settings.saveProfile(updated)
            self.profile = updated
            profileBox.set(updated)
            AppL10n.sync(from: updated)
            vocabulary = try await stack.vocabulary.fetchEntries(for: updated.preferredLanguagePair)
            await ReviewReminderService.reschedule(dueCountHint: dueCount)
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func translate(segment: TextSegment) async -> Bool {
        explainingSegmentIDs.insert(segment.id)
        defer { explainingSegmentIDs.remove(segment.id) }
        do {
            let pair = profile.preferredLanguagePair
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }

            // Prefer system/online gloss engines for all Translate actions — LLMs often
            // invent nonsense on short social-media text. Fall back to the model only
            // when engines fail and the segment is multi-word.
            let text: String
            if let gloss = try? await TranslationService().translateFlexible(trimmed, pair: pair) {
                let g = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                if !g.isEmpty, TranslationService.isUsefulGloss(g, of: trimmed) {
                    text = g
                } else if LexemeRouter.isSingleWord(trimmed) {
                    lastError = AppL10n.t("lookup.limited")
                    return false
                } else {
                    text = try await model.translate(segment, to: pair.target)
                }
            } else if LexemeRouter.isSingleWord(trimmed) {
                lastError = AppL10n.t("lookup.limited")
                return false
            } else {
                text = try await model.translate(segment, to: pair.target)
            }

            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                lastError = AppL10n.t("lookup.limited")
                return false
            }
            try await updateSegment(segment.id, documentID: segment.documentID) { seg in
                var copy = seg
                copy.translation = cleaned
                return copy
            }
            lastError = nil
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    @discardableResult
    func explain(segment: TextSegment) async -> GrammarBreakdown? {
        explainingSegmentIDs.insert(segment.id)
        defer { explainingSegmentIDs.remove(segment.id) }
        lastExplanationFromCache = false
        do {
            let providerID = model.capabilities.providerID
            let cacheKey = ExplanationCacheKey.forExplain(
                text: segment.text,
                targetLanguage: profile.preferredLanguagePair.target,
                providerID: providerID
            )
            if let cached = try await stack.explanationCache.explanation(forKey: cacheKey) {
                lastExplanationFromCache = true
                try await applyExplanation(cached.breakdown, to: segment)
                lastError = nil
                return cached.breakdown
            }

            let breakdown = try await model.analyzeGrammar(
                of: segment, languagePair: profile.preferredLanguagePair)
            try await applyExplanation(breakdown, to: segment)
            try await stack.explanationCache.store(
                AIExplanation(breakdown: breakdown), forKey: cacheKey)
            lastError = nil
            return breakdown
        } catch let error as LanguageModelError {
            if case .fallbackConsentRequired(let preferred, let fallback) = error {
                pendingFallback = (preferred, fallback)
            }
            lastError = Self.describe(error)
            return nil
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    func confirmFallbackAndRetryExplain(segment: TextSegment) async -> GrammarBreakdown? {
        guard let pending = pendingFallback else {
            return await explain(segment: segment)
        }
        router?.allowFallback(to: pending.fallback)
        pendingFallback = nil
        return await explain(segment: segment)
    }

    func dismissFallbackPrompt() {
        pendingFallback = nil
        router?.clearFallbackConsent()
    }

    private func applyExplanation(_ breakdown: GrammarBreakdown, to segment: TextSegment) async throws {
        try await updateSegment(segment.id, documentID: segment.documentID) { seg in
            var copy = seg
            if copy.translation == nil || copy.translation?.isEmpty == true {
                copy.translation = breakdown.translation
            }
            copy.explanation = breakdown.summary
            copy.readingText = ReadingLineBuilder.resolve(
                existing: copy.readingText,
                aiReading: breakdown.readingText,
                text: copy.text,
                sourceLanguage: profile.preferredLanguagePair.source,
                vocabulary: breakdown.vocabulary
            )
            return copy
        }
        for item in breakdown.vocabulary {
            let entry = VocabularyEntry(
                word: item.word,
                meaning: item.meaning,
                usage: item.usage,
                example: item.example,
                reading: item.reading,
                sourceDocumentID: segment.documentID,
                sourceDocumentTitle: documents.first { $0.id == segment.documentID }?.title,
                languagePair: profile.preferredLanguagePair
            )
            try await stack.vocabulary.upsert(entry)
        }
        vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
    }

    func generateReading(segment: TextSegment, force: Bool = false) async {
        if !force,
           let existing = segment.readingText,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        explainingSegmentIDs.insert(segment.id)
        defer { explainingSegmentIDs.remove(segment.id) }
        do {
            let local = ReadingLineBuilder.localReading(
                for: segment.text,
                sourceLanguage: profile.preferredLanguagePair.source
            )
            let reading: String
            if let local {
                reading = local
            } else {
                reading = try await model.generateReadingLine(
                    for: segment, languagePair: profile.preferredLanguagePair)
            }
            let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try await updateSegment(segment.id, documentID: segment.documentID) { seg in
                var copy = seg
                copy.readingText = trimmed
                return copy
            }
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    func ask(question: String, about segment: TextSegment) async -> String? {
        do {
            let answer = try await model.answer(
                question: question,
                about: segment,
                languagePair: profile.preferredLanguagePair
            )
            lastError = nil
            return answer.text
        } catch let error as LanguageModelError {
            if case .fallbackConsentRequired(let preferred, let fallback) = error {
                pendingFallback = (preferred, fallback)
            }
            lastError = Self.describe(error)
            return nil
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    /// Streams Q&A tokens into `onChunk`. Cancel via `cancelAsk()`.
    func askStreaming(
        question: String,
        about segment: TextSegment,
        onChunk: @escaping @MainActor (String) -> Void
    ) async -> String? {
        askTask?.cancel()
        let pair = profile.preferredLanguagePair
        let modelRef = model
        let task = Task { () -> String in
            var assembled = ""
            for try await chunk in modelRef.answerStream(
                question: question, about: segment, languagePair: pair
            ) {
                try Task.checkCancellation()
                assembled += chunk
                await MainActor.run { onChunk(chunk) }
            }
            return assembled
        }
        askTask = task
        do {
            let assembled = try await task.value
            askTask = nil
            lastError = nil
            return assembled.isEmpty ? nil : assembled
        } catch is CancellationError {
            askTask = nil
            lastError = Self.describe(LanguageModelError.cancelled)
            return nil
        } catch let error as LanguageModelError {
            askTask = nil
            if case .fallbackConsentRequired(let preferred, let fallback) = error {
                pendingFallback = (preferred, fallback)
            }
            lastError = Self.describe(error)
            return nil
        } catch {
            askTask = nil
            lastError = Self.describe(error)
            return nil
        }
    }

    func cancelAsk() {
        askTask?.cancel()
        askTask = nil
    }

    func deleteVocabulary(_ id: VocabularyEntry.ID) async {
        do {
            try await stack.vocabulary.delete(id)
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Deletes a card and, when `deletePair` is true, its twin sharing `pairID`.
    func deleteVocabulary(_ id: VocabularyEntry.ID, deletePair: Bool) async {
        guard deletePair,
              let entry = vocabulary.first(where: { $0.id == id }),
              let pairID = entry.pairID else {
            await deleteVocabulary(id)
            return
        }
        let twinIDs = vocabulary.filter { $0.pairID == pairID }.map(\.id)
        do {
            for twinID in twinIDs {
                try await stack.vocabulary.delete(twinID)
            }
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func suspendVocabulary(_ id: VocabularyEntry.ID, suspend: Bool) async {
        guard let idx = vocabulary.firstIndex(where: { $0.id == id }) else { return }
        var entry = vocabulary[idx]
        entry.suspendedAt = suspend ? .now : nil
        entry.updatedAt = .now
        do {
            try await stack.vocabulary.upsert(entry)
            vocabulary[idx] = entry
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func review(_ entry: VocabularyEntry, grade: FSRS.Grade) async -> VocabularyEntry? {
        do {
            let useCase = ScheduleVocabularyReviewUseCase(
                vocabulary: stack.vocabulary,
                desiredRetention: SRSPrefs.desiredRetention
            )
            let updated = try await useCase(entry, grade: grade)
            if let idx = vocabulary.firstIndex(where: { $0.id == updated.id }) {
                vocabulary[idx] = updated
            }
            lastError = nil
            return updated
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Session undo / editor restore — writes the card snapshot back to the store.
    func restoreVocabularySnapshot(_ entry: VocabularyEntry) async -> Bool {
        do {
            try await stack.vocabulary.upsert(entry)
            if let idx = vocabulary.firstIndex(where: { $0.id == entry.id }) {
                vocabulary[idx] = entry
            } else {
                vocabulary.append(entry)
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func fetchReviewLog(for entryID: VocabularyEntry.ID, limit: Int = 12) async -> [ReviewResult] {
        (try? await stack.vocabulary.fetchReviewEvents(for: entryID, limit: limit)) ?? []
    }

    /// Adds a card to a pack (and drops system Ungrouped if other packs remain).
    @discardableResult
    func addVocabulary(_ entryID: VocabularyEntry.ID, toPack packID: WordPack.ID) async -> Bool {
        guard let idx = vocabulary.firstIndex(where: { $0.id == entryID }) else { return false }
        var entry = vocabulary[idx]
        var ids = entry.packIDs
        if !ids.contains(packID) { ids.append(packID) }
        let hasOtherPack = ids.contains { $0 != WordPack.systemUngroupedID }
        if hasOtherPack {
            ids.removeAll { $0 == WordPack.systemUngroupedID }
        }
        entry.packIDs = normalizedPackIDs(ids)
        entry.updatedAt = .now
        do {
            try await stack.vocabulary.upsert(entry)
            vocabulary[idx] = entry
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Ahead-of-schedule cards for Study Ahead (soonest due first).
    func studyAheadCandidates(limit: Int = 10, excludingIDs: Set<UUID> = []) -> [VocabularyEntry] {
        let today = LocalCalendarDate.string()
        return vocabulary
            .filter {
                $0.suspendedAt == nil
                    && !excludingIDs.contains($0.id)
                    && !VocabularyScheduling.isDue($0)
                    && !$0.dueDate.isEmpty
                    && $0.dueDate > today
            }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(limit)
            .map { $0 }
    }

    func updateVocabulary(
        _ id: VocabularyEntry.ID,
        word: String? = nil,
        meaning: String,
        reading: String?,
        example: String?,
        packIDs: [UUID]? = nil
    ) async {
        guard let idx = vocabulary.firstIndex(where: { $0.id == id }) else { return }
        var entry = vocabulary[idx]
        if let word {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                entry.word = trimmed
                entry.normalizedWord = VocabularyEntry.normalizeWord(trimmed)
            }
        }
        entry.meaning = meaning
        entry.reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        entry.example = example?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let packIDs {
            entry.packIDs = normalizedPackIDs(packIDs)
        }
        entry.meaningEditedManually = true
        entry.updatedAt = .now
        do {
            try await stack.vocabulary.upsert(entry)
            vocabulary[idx] = entry
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Find or create a user tag by display name (e.g. «Диалог»).
    @discardableResult
    func ensureTag(named name: String) async -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = packs.first(where: {
            $0.kind == .tag && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing.id
        }
        guard await createTag(name: trimmed) else { return nil }
        return packs.first(where: {
            $0.kind == .tag && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        })?.id
    }

    func recordReadingSession(documentID: Document.ID, seconds: Int, startedAt: Date) async {
        guard seconds >= 1 else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let session = ReadingSession(
            documentID: documentID,
            dateLocal: formatter.string(from: startedAt),
            startedAt: startedAt,
            seconds: seconds
        )
        try? await stack.sessions.record(session)
        // Mirror into hours-first activity log (Stats screen).
        StudyActivityLog.record(mode: "reading", seconds: seconds, startedAt: startedAt)
    }

    private var batchConcurrency: Int {
        let value = UserDefaults.standard.integer(forKey: "ai.batchConcurrency")
        // Default 1 — LLMRequestQueue serializes; avoid parallel segment write races.
        return value == 0 ? 1 : min(max(value, 1), 2)
    }

    private func startBatch(_ documentID: Document.ID, kind: DocumentBatchKind) {
        guard batchTasks[documentID] == nil else { return }
        let pending = DocumentLearningProgress.pendingIDs(
            in: segments(for: documentID),
            kind: kind
        )
        guard !pending.isEmpty else { return }

        batchByDocument[documentID] = BatchState(
            kind: kind, completed: 0, total: pending.count, failed: 0)
        let concurrency = batchConcurrency
        batchTasks[documentID] = Task { [weak self] in
            await self?.runBatch(
                documentID: documentID, kind: kind, ids: pending, concurrency: concurrency)
        }
    }

    private func runBatch(
        documentID: Document.ID,
        kind: DocumentBatchKind,
        ids: [UUID],
        concurrency: Int
    ) async {
        var index = 0
        while index < ids.count {
            if Task.isCancelled { break }
            let end = min(index + concurrency, ids.count)
            let chunk = Array(ids[index..<end])
            index = end
            let tasks = chunk.map { segmentID in
                Task { @MainActor [weak self] () -> Bool in
                    guard let self, !Task.isCancelled else { return false }
                    guard let segment = self.segments(for: documentID)
                        .first(where: { $0.id == segmentID })
                    else { return false }
                    switch kind {
                    case .explain:
                        return await self.explain(segment: segment) != nil
                    case .translate:
                        return await self.translate(segment: segment)
                    }
                }
            }
            for task in tasks {
                let ok = await task.value
                if var state = batchByDocument[documentID] {
                    state.completed += 1
                    if !ok { state.failed += 1 }
                    batchByDocument[documentID] = state
                }
            }
        }
        batchTasks[documentID] = nil
        batchByDocument[documentID] = nil
    }

    private func updateSegment(
        _ segmentID: UUID,
        documentID: Document.ID,
        mutate: (TextSegment) -> TextSegment
    ) async throws {
        var segments = segmentsByDocument[documentID] ?? []
        if segments.isEmpty {
            segments = try await stack.library.fetchSegments(for: documentID)
        }
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let updated = mutate(segments[idx])
        try await stack.library.updateSegment(updated)
        segments[idx] = updated
        segmentsByDocument[documentID] = segments
    }

    private func persistRemoteConfig() {
        RemoteConfigStorage.save(remoteSettings)
    }

    private static func describe(_ error: Error) -> String {
        if let lm = error as? LanguageModelError {
            switch lm {
            case .remoteOptInRequired:
                return "Enable remote AI in Settings and save an API key."
            case .unauthorized:
                return "API key rejected (401/403)."
            case .networkUnreachable:
                return "Network unreachable."
            case .rateLimited:
                return "Rate limited — retry later."
            case .providerUnavailable:
                return "AI provider unavailable. Check Settings (Apple Intelligence / MLX model / Remote)."
            case .malformedResponse:
                return "Model returned an unreadable response."
            case .fallbackConsentRequired(let preferred, let fallback):
                return "Fallback from \(preferred) to \(fallback) needs confirmation."
            case .cancelled:
                return "Cancelled."
            case .contextTooLong:
                return AppL10n.t("pack.gen.contextTooLong")
            case .underlying(let message):
                if message.localizedCaseInsensitiveContains("context")
                    || message.localizedCaseInsensitiveContains("window") {
                    return AppL10n.t("pack.gen.contextTooLong")
                }
                return message
            default:
                return String(describing: lm)
            }
        }
        return error.localizedDescription
    }

    // MARK: - Packs & manual cards

    private static let defaultTagNames = ["Book", "Podcast", "Conversation", "Work", "Hard"]

    /// Ensures system "Ungrouped". Seeds Book/Podcast/… only once (shared sidecar) —
    /// never again after the user deletes them (UserDefaults-per-app caused Lab to reseed).
    private func ensureDefaultTagPacks() async {
        do {
            var existing = try await stack.vocabulary.fetchPacks()
            let hasUngrouped = existing.contains { $0.id == WordPack.systemUngroupedID }
            var prefs = LibraryBootstrapPrefs.load()
            let tags = existing.filter { $0.kind == .tag }
            let suppressed = Set(prefs.suppressedDefaultTagNames)

            var toCreate: [WordPack] = []

            // Mark seeded if library already has tags or onboarding finished — never fill name gaps.
            if !prefs.defaultTagsSeeded, (!tags.isEmpty || profile.hasCompletedOnboarding) {
                prefs.defaultTagsSeeded = true
                prefs.save()
            }

            if !prefs.defaultTagsSeeded, tags.isEmpty {
                let existingTagNames = Set(tags.map(\.name))
                for name in Self.defaultTagNames
                where !existingTagNames.contains(name) && !suppressed.contains(name) {
                    toCreate.append(WordPack(name: name, isSystem: true, kind: .tag))
                }
                prefs.defaultTagsSeeded = true
                prefs.save()
            }

            if !hasUngrouped {
                toCreate.append(
                    WordPack(
                        id: WordPack.systemUngroupedID,
                        name: "Ungrouped",
                        isSystem: true,
                        kind: .learningPack
                    )
                )
            }
            for pack in toCreate {
                try await stack.vocabulary.upsertPack(pack)
            }
            if !toCreate.isEmpty {
                existing = try await stack.vocabulary.fetchPacks()
            }
            packs = existing
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Cards not assigned to any tag/pack fall back to "Ungrouped".
    private func normalizedPackIDs(_ packIDs: [UUID]) -> [UUID] {
        packIDs.isEmpty ? [WordPack.systemUngroupedID] : packIDs
    }

    @discardableResult
    func setPackPinned(_ packID: WordPack.ID, pinned: Bool) async -> Bool {
        guard let idx = packs.firstIndex(where: { $0.id == packID }) else { return false }
        var pack = packs[idx]
        pack.isPinned = pinned
        pack.updatedAt = .now
        do {
            try await stack.vocabulary.upsertPack(pack)
            packs[idx] = pack
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func cardCount(for pack: WordPack) -> Int {
        vocabulary.filter { $0.packIDs.contains(pack.id) }.count
    }

    /// Recent cards, newest first, optionally scoped to a single pack/tag.
    func historyEntries(tagID: WordPack.ID? = nil) -> [VocabularyEntry] {
        let source = tagID.map { id in vocabulary.filter { $0.packIDs.contains(id) } } ?? vocabulary
        return source.sorted { $0.createdAt > $1.createdAt }
    }

    func absoluteAudioURL(for entry: VocabularyEntry) -> URL? {
        guard let path = entry.audioRelativePath else { return nil }
        return stack.store.fileStore.absoluteURL(for: path)
    }

    func absoluteDocumentFileURL(for document: Document) -> URL? {
        guard let path = document.storedFileRelativePath else { return nil }
        return stack.store.fileStore.absoluteURL(for: path)
    }

    func absoluteCoverURL(for pack: WordPack) -> URL? {
        guard let path = pack.coverRelativePath else { return nil }
        return stack.store.fileStore.absoluteURL(for: path)
    }

    func absoluteAvatarURL() -> URL? {
        guard let path = profile.avatarRelativePath else { return nil }
        return stack.store.fileStore.absoluteURL(for: path)
    }

    /// Manually authored card (New Card screen).
    /// - `reversed`: production direction (L1 shown as word, L2 as meaning).
    /// - `alsoCreateReverse`: also insert the opposite direction as a linked twin (`pairID`).
    @discardableResult
    func createManualCard(
        word: String,
        meaning: String,
        context: String?,
        reading: String? = nil,
        packIDs: [UUID],
        reversed: Bool,
        alsoCreateReverse: Bool = false,
        audioURL: URL? = nil
    ) async -> Bool {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty, !trimmedMeaning.isEmpty else {
            lastError = "Word and meaning are required."
            return false
        }
        let trimmedContext = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReading = reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let packs = normalizedPackIDs(packIDs)
        let pair = profile.preferredLanguagePair

        let primaryWord = reversed ? trimmedMeaning : trimmedWord
        let primaryMeaning = reversed ? trimmedWord : trimmedMeaning
        let primaryDirection: CardDirection = reversed ? .reverse : .forward
        let reverseDirection: CardDirection = reversed ? .forward : .reverse

        let pairID = alsoCreateReverse ? UUID() : nil

        var entry = upsertMergeCandidate(
            word: primaryWord,
            meaning: primaryMeaning,
            direction: alsoCreateReverse ? primaryDirection : .forward,
            pairID: pairID,
            example: (trimmedContext?.isEmpty == false) ? trimmedContext : nil,
            reading: reversed ? nil : ((trimmedReading?.isEmpty == false) ? trimmedReading : nil),
            packIDs: packs,
            languagePair: pair
        )

        if let audioURL {
            do {
                let data = try Data(contentsOf: audioURL)
                let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
                entry.audioRelativePath = try stack.store.fileStore.storeAudio(
                    data: data, entryID: entry.id, fileExtension: ext)
            } catch {
                lastError = error.localizedDescription
            }
        }

        do {
            try await stack.vocabulary.upsert(entry)
            if alsoCreateReverse {
                let reverseWord = reversed ? trimmedWord : trimmedMeaning
                let reverseMeaning = reversed ? trimmedMeaning : trimmedWord
                let reverse = upsertMergeCandidate(
                    word: reverseWord,
                    meaning: reverseMeaning,
                    direction: reverseDirection,
                    pairID: pairID,
                    example: (trimmedContext?.isEmpty == false) ? trimmedContext : nil,
                    reading: reversed ? ((trimmedReading?.isEmpty == false) ? trimmedReading : nil) : nil,
                    packIDs: packs,
                    languagePair: pair
                )
                try await stack.vocabulary.upsert(reverse)
            }
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Reuse existing row when `(normalizedWord, languagePair, direction)` matches.
    private func upsertMergeCandidate(
        word: String,
        meaning: String,
        direction: CardDirection,
        pairID: UUID?,
        example: String?,
        reading: String?,
        packIDs: [UUID],
        languagePair: LanguagePair
    ) -> VocabularyEntry {
        let norm = VocabularyEntry.normalizeWord(word)
        if let existing = vocabulary.first(where: {
            ($0.normalizedWord ?? VocabularyEntry.normalizeWord($0.word)) == norm
                && $0.languagePair == languagePair
                && ($0.direction ?? .forward) == direction
        }) {
            var merged = existing
            merged.meaning = meaning
            merged.example = example ?? merged.example
            merged.reading = reading ?? merged.reading
            merged.packIDs = Array(Set(merged.packIDs + packIDs))
            if merged.pairID == nil { merged.pairID = pairID }
            merged.direction = direction
            merged.normalizedWord = norm
            merged.meaningEditedManually = true
            merged.updatedAt = .now
            return merged
        }
        return VocabularyEntry(
            word: word,
            meaning: meaning,
            example: example,
            reading: reading,
            languagePair: languagePair,
            packIDs: packIDs,
            meaningEditedManually: true,
            pairID: pairID,
            direction: direction,
            normalizedWord: norm
        )
    }
    @discardableResult
    func importPack(draft: PackImportDraft, coverData: Data? = nil) async -> WordPack? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !draft.cards.isEmpty else {
            lastError = "The pack needs a title and at least one card."
            return nil
        }
        var pack = WordPack(
            name: title,
            packDescription: draft.description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            languagePair: profile.preferredLanguagePair,
            kind: .learningPack
        )
        if let coverData {
            do {
                pack.coverRelativePath = try stack.store.fileStore.storeCover(
                    data: coverData, packID: pack.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
        do {
            try await stack.vocabulary.upsertPack(pack)
            for card in draft.cards {
                let entry = VocabularyEntry(
                    word: card.term,
                    meaning: card.translation,
                    example: card.context?.nilIfEmpty,
                    languagePair: profile.preferredLanguagePair,
                    packIDs: [pack.id]
                )
                try await stack.vocabulary.upsert(entry)
            }
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            packs = try await stack.vocabulary.fetchPacks()
            lastError = nil
            return pack
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func discardGeneratedDraft() {
        generatedDraft = nil
        packGenerationError = nil
        packGenerationProgress = nil
    }

    func clearPackGenerationError() {
        packGenerationError = nil
    }

    /// Asks the active language model for vocabulary cards about `topic` via a
    /// JSON-only system prompt (never the tutor persona). Localizes glosses with
    /// Apple Translation when needed. Failures stay on the sheet — not the red banner.
    @discardableResult
    func generatePackCards(topic: String) async -> PackImportDraft? {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return nil }
        isGeneratingPack = true
        packGenerationError = nil
        generatedDraft = nil
        packGenerationProgress = PackGenProgress(phase: .requesting, cardCountHint: nil)
        defer {
            isGeneratingPack = false
            packGenerationProgress = nil
        }

        let pair = profile.preferredLanguagePair
        let learnName = PackJSONParser.languageDisplayName(pair.source)
        let nativeName = PackJSONParser.languageDisplayName(pair.target)
        let system = PackJSONParser.generationSystemPrompt(
            learningLanguage: pair.source,
            nativeLanguage: pair.target
        )
        let user = """
        Topic: \(PromptLibrary.clipForContext(trimmedTopic, maxChars: 120))
        Produce 8–12 vocabulary cards (WORDS / SHORT EXPRESSIONS only). Keep JSON compact.
        Every "term" must be in \(learnName) (\(pair.source)) — not in \(nativeName).
        Every "translation" must be a short gloss in \(nativeName) (\(pair.target)).
        Optional "context" = one short example in \(learnName) (≤12 words).
        No long sentences as terms. JSON only — no markdown.
        """

        do {
            var raw = try await model.complete(systemPrompt: system, userMessage: user)
            var draft: PackImportDraft
            do {
                draft = try PackJSONParser.parse(raw)
            } catch {
                // One retry — many local models wrap JSON in prose on the first try.
                packGenerationProgress = PackGenProgress(phase: .requesting, cardCountHint: nil)
                let retryUser = """
                Return ONLY a JSON object. No markdown. No commentary.
                Topic: \(trimmedTopic)
                term = word/short expression in \(learnName) only (max 5 words).
                translation = gloss in \(nativeName).
                context = optional example sentence in \(learnName).
                Schema: {"title":"...","description":"...","cards":[{"term":"...","translation":"...","context":"..."}]}
                """
                raw = try await model.complete(systemPrompt: system, userMessage: retryUser)
                draft = try PackJSONParser.parse(raw)
            }
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.title = trimmedTopic
            }

            let sanitized = PackJSONParser.sanitizeVocabularyCards(
                draft.cards, learningLanguage: pair.source
            )
            guard !sanitized.isEmpty else {
                packGenerationError = AppL10n.t("pack.gen.badTerms")
                return nil
            }
            draft.cards = sanitized

            packGenerationProgress = PackGenProgress(
                phase: .translating(done: 0, total: draft.cards.count),
                cardCountHint: draft.cards.count
            )

            // Prefer the model's topic-aware gloss. Apple Translation is sense-blind
            // (e.g. gratitude context → "gratuité" wrongly becomes "бесплатно"/free).
            let translator = TranslationService()
            var localized: [PackCardDraft] = []
            localized.reserveCapacity(draft.cards.count)
            for (index, card) in draft.cards.enumerated() {
                packGenerationProgress = PackGenProgress(
                    phase: .translating(done: index, total: draft.cards.count),
                    cardCountHint: draft.cards.count
                )
                var updated = card
                let llmGloss = card.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                let needsMachineGloss = llmGloss.isEmpty
                    || llmGloss.localizedCaseInsensitiveCompare(card.term) == .orderedSame
                if needsMachineGloss,
                   let nativeText = try? await translator.translate(
                    card.term, from: pair.source, to: pair.target
                   ), !nativeText.isEmpty {
                    updated.translation = nativeText
                } else {
                    updated.translation = llmGloss
                }
                localized.append(updated)
            }
            draft.cards = localized
            packGenerationProgress = PackGenProgress(
                phase: .translating(done: draft.cards.count, total: draft.cards.count),
                cardCountHint: draft.cards.count
            )

            generatedDraft = draft
            packGenerationError = nil
            return draft
        } catch is PackJSONError {
            packGenerationError = AppL10n.t("pack.gen.parseFail")
            return nil
        } catch let error as LanguageModelError {
            packGenerationError = Self.describeLocalized(error)
            return nil
        } catch {
            packGenerationError = Self.describeLocalized(error)
            return nil
        }
    }

    private static func describeLocalized(_ error: Error) -> String {
        if let lm = error as? LanguageModelError {
            switch lm {
            case .providerUnavailable:
                return AppL10n.t("pack.gen.providerUnavailable")
            case .malformedResponse:
                return AppL10n.t("pack.gen.parseFail")
            case .networkUnreachable:
                return AppL10n.t("error.network")
            case .remoteOptInRequired:
                return AppL10n.t("error.remoteOptIn")
            default:
                break
            }
        }
        return describe(error)
    }

    /// Persists the pending `generatedDraft` cards into an existing pack.
    func appendGeneratedCards(packID: WordPack.ID) async {
        guard let draft = generatedDraft, !draft.cards.isEmpty else { return }
        do {
            for card in draft.cards {
                let entry = VocabularyEntry(
                    word: card.term,
                    meaning: card.translation,
                    example: card.context?.nilIfEmpty,
                    languagePair: profile.preferredLanguagePair,
                    packIDs: [packID]
                )
                try await stack.vocabulary.upsert(entry)
            }
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            generatedDraft = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deletePackWithCards(_ packID: WordPack.ID) async {
        guard packID != WordPack.systemUngroupedID else {
            lastError = "The Ungrouped pack can’t be deleted."
            return
        }
        let cover = packs.first { $0.id == packID }?.coverRelativePath
        do {
            try await stack.vocabulary.deletePackRemovingCards(packID)
            if let cover {
                try? stack.store.fileStore.deleteRelativePath(cover)
            }
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            packs = try await stack.vocabulary.fetchPacks()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Tags

    @discardableResult
    func createLearningPack(name: String, description: String? = nil) async -> WordPack? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Pack name is required."
            return nil
        }
        if packs.contains(where: {
            $0.kind == .learningPack && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            lastError = "A pack with that name already exists."
            return nil
        }
        let pack = WordPack(
            name: trimmed,
            packDescription: description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            languagePair: profile.preferredLanguagePair,
            kind: .learningPack
        )
        do {
            try await stack.vocabulary.upsertPack(pack)
            packs = try await stack.vocabulary.fetchPacks()
            lastError = nil
            return pack
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func renamePack(_ packID: WordPack.ID, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Pack name is required."
            return false
        }
        guard let idx = packs.firstIndex(where: {
            $0.id == packID && $0.kind == .learningPack && !$0.isSystem
        }) else {
            lastError = "Pack not found."
            return false
        }
        var pack = packs[idx]
        pack.name = trimmed
        pack.updatedAt = .now
        do {
            try await stack.vocabulary.upsertPack(pack)
            packs[idx] = pack
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deletePack(_ packID: WordPack.ID) async -> Bool {
        guard let pack = packs.first(where: {
            $0.id == packID && $0.kind == .learningPack && !$0.isSystem
        }) else {
            lastError = "Pack not found."
            return false
        }
        do {
            try await stack.vocabulary.deletePack(pack.id)
            packs = try await stack.vocabulary.fetchPacks()
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createTag(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Tag name is required."
            return false
        }
        if packs.contains(where: { $0.kind == .tag && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            lastError = "A tag with that name already exists."
            return false
        }
        let pack = WordPack(name: trimmed, isSystem: false, kind: .tag)
        do {
            try await stack.vocabulary.upsertPack(pack)
            packs = try await stack.vocabulary.fetchPacks()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameTag(_ packID: WordPack.ID, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Tag name is required."
            return false
        }
        guard let idx = packs.firstIndex(where: { $0.id == packID && $0.kind == .tag }) else {
            lastError = "Tag not found."
            return false
        }
        if packs.contains(where: {
            $0.kind == .tag && $0.id != packID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            lastError = "A tag with that name already exists."
            return false
        }
        var pack = packs[idx]
        pack.name = trimmed
        pack.updatedAt = .now
        do {
            try await stack.vocabulary.upsertPack(pack)
            packs[idx] = pack
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Removes a tag pack without deleting cards (memberships drop via pack delete).
    func deleteTag(_ packID: WordPack.ID) async {
        guard let pack = packs.first(where: { $0.id == packID && $0.kind == .tag }) else { return }
        do {
            // Detach tag from cards, then delete the pack (keep cards).
            for entry in vocabulary where entry.packIDs.contains(packID) {
                var updated = entry
                updated.packIDs = entry.packIDs.filter { $0 != packID }
                if updated.packIDs.isEmpty {
                    updated.packIDs = [WordPack.systemUngroupedID]
                }
                try await stack.vocabulary.upsert(updated)
            }
            try await stack.vocabulary.deletePack(pack.id)
            vocabulary = try await stack.vocabulary.fetchEntries(for: profile.preferredLanguagePair)
            packs = try await stack.vocabulary.fetchPacks()

            if Self.defaultTagNames.contains(pack.name) {
                var prefs = LibraryBootstrapPrefs.load()
                if !prefs.suppressedDefaultTagNames.contains(pack.name) {
                    prefs.suppressedDefaultTagNames.append(pack.name)
                }
                prefs.defaultTagsSeeded = true
                prefs.save()
            }

            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves picked photo data as the profile avatar and persists the profile.
    func saveAvatarImage(_ data: Data, fileExtension: String = "jpg") async {
        do {
            let relative = try stack.store.fileStore.storeAvatar(data: data, fileExtension: fileExtension)
            var updated = profile
            updated.avatarRelativePath = relative
            await saveProfile(updated)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func describeImport(_ error: Error) -> String {
        if let importError = error as? ContentImportError {
            switch importError {
            case .unsupportedSource:
                return "This file type isn’t supported yet."
            case .unreadableFile:
                return "Couldn’t open that file."
            case .emptyContent:
                return "No readable text found. Scanned PDFs need OCR (coming soon)."
            case .networkFailed:
                return "Download failed."
            case .parseFailed(let detail):
                return detail.isEmpty ? "Couldn’t parse that file." : detail
            }
        }
        return error.localizedDescription
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
