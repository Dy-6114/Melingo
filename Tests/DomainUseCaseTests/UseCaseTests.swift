import Foundation
import Testing
import Domain
import SharedTestSupport

@Suite("ImportDocumentUseCase")
struct ImportDocumentUseCaseTests {
    @Test("imports plain text via matching importer and persists")
    func importsPlainText() async throws {
        let library = MockLibraryRepository()
        let importer = MockContentImporter()
        let useCase = ImportDocumentUseCase(importers: [importer], library: library)

        let document = try await useCase(.plainText(title: "Haiku", body: "古池や"))

        #expect(document.title == "Haiku")
        let saved = try await library.fetchDocuments()
        #expect(saved.count == 1)
        let segments = try await library.fetchSegments(for: document.id)
        #expect(segments.count == 1)
        #expect(segments[0].text == "古池や")
    }

    @Test("throws when no importer can handle the source")
    func unsupportedSource() async {
        let library = MockLibraryRepository()
        let importer = MockContentImporter(handledKinds: [.pdf])
        let useCase = ImportDocumentUseCase(importers: [importer], library: library)

        await #expect(throws: ContentImportError.unsupportedSource) {
            _ = try await useCase(.plainText(title: nil, body: "hello"))
        }
    }
}

@Suite("ExplainSelectedTextUseCase")
struct ExplainSelectedTextUseCaseTests {
    @Test("delegates to LanguageModelServicing")
    func explainsWord() async throws {
        let model = MockLanguageModelService(
            explainWordHandler: { word, _ in
                AIExplanation(
                    breakdown: GrammarBreakdown(
                        translation: "frog",
                        summary: "蛙 means frog in this haiku.",
                        vocabulary: [
                            VocabularyItem(word: word, meaning: "frog", reading: "かえる")
                        ]
                    )
                )
            }
        )
        let useCase = ExplainSelectedTextUseCase(model: model)
        let segment = TextSegment(documentID: UUID(), order: 0, text: "古池や蛙飛び込む水の音")
        let context = TextContext(
            segment: segment,
            languagePair: LanguagePair(source: "ja", target: "en")
        )

        let explanation = try await useCase(word: "蛙", context: context)

        #expect(explanation.breakdown.vocabulary.first?.word == "蛙")
        #expect(explanation.breakdown.summary.contains("蛙"))
    }
}

@Suite("ScheduleVocabularyReviewUseCase")
struct ScheduleVocabularyReviewUseCaseTests {
    @Test("applies FSRS and persists scheduled card")
    func schedulesWithFSRS() async throws {
        let vocab = MockVocabularyRepository()
        let pair = LanguagePair(source: "ja", target: "en")
        let entry = VocabularyEntry(word: "蛙", meaning: "frog", languagePair: pair)
        try await vocab.upsert(entry)

        let useCase = ScheduleVocabularyReviewUseCase(vocabulary: vocab)
        let updated = try await useCase(entry, grade: .good)

        #expect(updated.srsState == .review)
        #expect(updated.stability > 0)
        #expect(updated.reviewCount == 1)
        #expect(!updated.dueDate.isEmpty)

        let reviews = await vocab.reviews
        #expect(reviews.count == 1)
        #expect(reviews[0].grade == 3)

        let stored = try await vocab.fetchEntries(for: pair)
        #expect(stored[0].stability == updated.stability)
    }
}

@Suite("DocumentLearningProgress")
struct DocumentLearningProgressTests {
    private func segments(
        translations: [String?],
        explanations: [String?]
    ) -> [TextSegment] {
        let doc = UUID()
        return zip(translations, explanations).enumerated().map { index, pair in
            TextSegment(
                documentID: doc,
                order: index,
                text: "s\(index)",
                translation: pair.0,
                explanation: pair.1
            )
        }
    }

    @Test("counts explained and translated separately")
    func aggregates() {
        let segs = segments(
            translations: ["a", "b", nil],
            explanations: ["x", nil, nil]
        )
        let progress = DocumentLearningProgress.of(segs)
        #expect(progress.total == 3)
        #expect(progress.explained == 1)
        #expect(progress.translated == 2)
    }

    @Test("pending explain skips already explained")
    func pendingExplain() {
        let segs = segments(
            translations: [nil, "t", nil],
            explanations: ["done", nil, nil]
        )
        let ids = DocumentLearningProgress.pendingIDs(in: segs, kind: .explain)
        #expect(ids.count == 2)
        #expect(!ids.contains(segs[0].id))
    }

    @Test("pending translate skips explained and translated")
    func pendingTranslate() {
        let segs = segments(
            translations: [nil, "t", nil],
            explanations: ["done", nil, nil]
        )
        let ids = DocumentLearningProgress.pendingIDs(in: segs, kind: .translate)
        #expect(ids == [segs[2].id])
    }
}
