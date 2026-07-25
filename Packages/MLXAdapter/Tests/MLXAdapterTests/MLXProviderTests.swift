import Foundation
import Testing
@testable import MLXAdapter
import Domain
import AIKit

@Suite("MLXProvider")
struct MLXProviderTests {
    @Test("unconfigured provider reports unavailable")
    func unconfigured() async {
        MLXConfigStorage.save(MLXConfigStorage.Config())
        MLXProvider.sharedEngine = nil
        let provider = MLXProvider()
        #expect(!provider.isReady)
        await #expect(throws: LanguageModelError.providerUnavailable) {
            _ = try await provider.translate(
                TextSegment(documentID: UUID(), order: 0, text: "hello"),
                to: "en"
            )
        }
    }
}
