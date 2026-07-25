import Foundation
import Testing
import Domain

@Suite("Domain entities")
struct DomainEntityTests {
    @Test("Document identity is stable across copy")
    func documentIdentity() {
        let id = UUID()
        let doc = Document(id: id, title: "A", sourceKind: .epub)
        #expect(doc.id == id)
        #expect(doc.sourceKind == .epub)
    }

    @Test("LanguagePair equality")
    func languagePairEquality() {
        let a = LanguagePair(source: "ja", target: "en")
        let b = LanguagePair(source: "ja", target: "en")
        #expect(a == b)
    }
}

@Suite("ReadingLineBuilder")
struct ReadingLineBuilderTests {
    @Test("Japanese kana-only text is returned as reading")
    func kanaOnly() {
        let reading = ReadingLineBuilder.localReading(for: "こんにちは", sourceLanguage: "ja")
        #expect(reading == "こんにちは")
    }

    @Test("Japanese kanji uses vocabulary readings when available")
    func vocabBacked() {
        let reading = ReadingLineBuilder.localReading(
            for: "古池や",
            sourceLanguage: "ja",
            vocabulary: [
                VocabularyItem(word: "古池", meaning: "old pond", reading: "ふるいけ"),
                VocabularyItem(word: "や", meaning: "particle", reading: "や"),
            ]
        )
        #expect(reading == "ふるいけや")
    }

    @Test("Chinese produces pinyin offline")
    func chinesePinyin() {
        let reading = ReadingLineBuilder.localReading(for: "你好", sourceLanguage: "zh")
        #expect(reading != nil)
        #expect(reading != "你好")
    }

    @Test("resolve prefers existing unless forced")
    func resolvePrefersExisting() {
        let resolved = ReadingLineBuilder.resolve(
            existing: "ふるいけ や",
            aiReading: "other",
            text: "古池や",
            sourceLanguage: "ja",
            vocabulary: []
        )
        #expect(resolved == "ふるいけ や")
    }
}
