import Foundation

public struct ExplainSelectedTextUseCase: Sendable {
    private let model: any LanguageModelServicing

    public init(model: any LanguageModelServicing) {
        self.model = model
    }

    public func callAsFunction(word: String, context: TextContext) async throws -> AIExplanation {
        try await model.explainWord(word, in: context)
    }
}
