import Foundation
import Testing
@testable import Domain

@Suite("PackJSONParser")
struct PackJSONParserTests {
    @Test("Parses a well-formed object with title/description/cards")
    func parsesObjectRoot() throws {
        let json = """
        {
          "title": "Airport phrases",
          "description": "Useful phrases for checking in.",
          "cards": [
            {"term": "搭乗券", "translation": "boarding pass", "context": "搭乗券を見せてください。"},
            {"term": "空港", "translation": "airport"}
          ]
        }
        """
        let draft = try PackJSONParser.parse(json)
        #expect(draft.title == "Airport phrases")
        #expect(draft.description == "Useful phrases for checking in.")
        #expect(draft.cards.count == 2)
        #expect(draft.cards[0].term == "搭乗券")
        #expect(draft.cards[0].translation == "boarding pass")
        #expect(draft.cards[0].context == "搭乗券を見せてください。")
        #expect(draft.cards[1].context == nil)
    }

    @Test("Strips markdown code fences before parsing")
    func stripsCodeFences() throws {
        let json = """
        ```json
        {"title": "Fenced", "cards": [{"term": "a", "translation": "b"}]}
        ```
        """
        let draft = try PackJSONParser.parse(json)
        #expect(draft.title == "Fenced")
        #expect(draft.cards.count == 1)
    }

    @Test("Accepts a bare JSON array of cards, defaulting title")
    func parsesArrayRoot() throws {
        let json = """
        [
          {"word": "猫", "meaning": "cat"},
          {"word": "犬", "meaning": "dog", "example": "犬が好きです。"}
        ]
        """
        let draft = try PackJSONParser.parse(json)
        #expect(draft.title == "Imported pack")
        #expect(draft.cards.count == 2)
        #expect(draft.cards[0].term == "猫")
        #expect(draft.cards[0].translation == "cat")
        #expect(draft.cards[1].context == "犬が好きです。")
    }

    @Test("Accepts field aliases for term/translation/context")
    func acceptsFieldAliases() throws {
        let json = """
        {"cards": [{"front": "hello", "back": "こんにちは", "sentence": "Hello there."}]}
        """
        let draft = try PackJSONParser.parse(json)
        #expect(draft.cards.count == 1)
        #expect(draft.cards[0].term == "hello")
        #expect(draft.cards[0].translation == "こんにちは")
        #expect(draft.cards[0].context == "Hello there.")
    }

    @Test("Drops cards missing a term or translation instead of fabricating one")
    func dropsIncompleteCards() throws {
        let json = """
        {"cards": [
          {"term": "only term"},
          {"translation": "only translation"},
          {"term": "complete", "translation": "complete"}
        ]}
        """
        let draft = try PackJSONParser.parse(json)
        #expect(draft.cards.count == 1)
        #expect(draft.cards[0].term == "complete")
    }

    @Test("Throws noCards when every card is incomplete")
    func throwsWhenNoValidCards() {
        let json = """
        {"cards": [{"term": "only term"}]}
        """
        #expect(throws: PackJSONError.noCards) {
            try PackJSONParser.parse(json)
        }
    }

    @Test("Throws unexpectedRoot for a JSON array whose elements aren't objects")
    func throwsOnUnexpectedRoot() {
        let json = "[1, 2, 3]"
        #expect(throws: PackJSONError.unexpectedRoot) {
            try PackJSONParser.parse(json)
        }
    }

    @Test("Throws invalidEncoding for empty input")
    func throwsOnEmptyInput() {
        #expect(throws: (any Error).self) {
            try PackJSONParser.parse("   ")
        }
    }

    @Test("Extracts JSON object from surrounding prose")
    func extractsJSONFromProse() throws {
        let raw = """
        Sure, here you go:
        {"title": "Prose", "cards": [{"term": "a", "translation": "b"}]}
        Hope that helps!
        """
        let draft = try PackJSONParser.parse(raw)
        #expect(draft.title == "Prose")
        #expect(draft.cards.count == 1)
    }

    @Test("notebookPrompt asks for JSON-only vocabulary terms")
    func notebookPromptShape() {
        let prompt = PackJSONParser.notebookPrompt
        #expect(prompt.contains("\"term\""))
        #expect(prompt.contains("\"translation\""))
        #expect(prompt.contains("20") || prompt.contains("25") || prompt.contains("16"))
        #expect(prompt.contains("LEARNING") || prompt.contains("learning"))
    }

    @Test("generationSystemPrompt pins L2 terms and L1 glosses")
    func generationPromptPinsLanguages() {
        let prompt = PackJSONParser.generationSystemPrompt(
            learningLanguage: "ja", nativeLanguage: "ru"
        )
        #expect(prompt.contains("Japanese"))
        #expect(prompt.contains("Russian"))
        #expect(prompt.contains("FORBIDDEN") || prompt.contains("Max"))
    }

    @Test("sanitizeVocabularyCards drops sentences and wrong-script terms")
    func sanitizeDropsBadTerms() {
        let cards = [
            PackCardDraft(term: "空港", translation: "аэропорт", context: "空港に行きます。"),
            PackCardDraft(
                term: "What time does the flight leave tomorrow morning?",
                translation: "когда вылет",
                context: nil
            ),
            PackCardDraft(term: "случайная фраза", translation: "oops", context: nil),
            PackCardDraft(term: "搭乗券", translation: "посадочный талон", context: nil),
        ]
        let kept = PackJSONParser.sanitizeVocabularyCards(cards, learningLanguage: "ja")
        #expect(kept.count == 2)
        #expect(kept.map(\.term) == ["空港", "搭乗券"])
    }
}
