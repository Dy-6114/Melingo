import Foundation

public struct TranslateSegmentUseCase: Sendable {
    private let model: any LanguageModelServicing

    public init(model: any LanguageModelServicing) {
        self.model = model
    }

    public func callAsFunction(_ segment: TextSegment, to targetLanguage: String) async throws -> String {
        try await model.translate(segment, to: targetLanguage)
    }
}
