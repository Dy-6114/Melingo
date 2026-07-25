import Foundation

public struct AnswerAboutSegmentUseCase: Sendable {
    private let model: any LanguageModelServicing

    public init(model: any LanguageModelServicing) {
        self.model = model
    }

    public func callAsFunction(
        question: String,
        segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> AIAnswer {
        try await model.answer(question: question, about: segment, languagePair: languagePair)
    }
}
