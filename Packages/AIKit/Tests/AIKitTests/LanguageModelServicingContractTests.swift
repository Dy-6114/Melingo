import Foundation
import Testing
import Domain
import AIKit
import SharedTestSupport

/// Contract suite for `LanguageModelServicing` — same cases against Mock + URLProtocol remote.
@Suite("LanguageModelServicing contract")
struct LanguageModelServicingContractTests {
    private let pair = LanguagePair(source: "ja", target: "en")
    private let segment = TextSegment(
        documentID: UUID(),
        order: 0,
        text: "古池や蛙飛び込む水の音"
    )

    private func fixtureBreakdown() -> GrammarBreakdown {
        GrammarBreakdown(
            translation: "An old pond; a frog jumps in — the sound of water.",
            summary: "Classic Basho haiku.",
            readingText: "ふるいけや かわず とびこむ みずのおと",
            vocabulary: [
                VocabularyItem(word: "蛙", meaning: "frog", reading: "かえる")
            ]
        )
    }

    private func mockService() -> MockLanguageModelService {
        let breakdown = fixtureBreakdown()
        return MockLanguageModelService(
            explainWordHandler: { _, _ in AIExplanation(breakdown: breakdown) },
            analyzeHandler: { _, _ in breakdown },
            answerHandler: { q, _, _ in AIAnswer(text: "Answer to: \(q)") },
            translateHandler: { _, _ in breakdown.translation },
            readingHandler: { _, _ in breakdown.readingText ?? "" }
        )
    }

    @Test("mock analyzeGrammar returns required fields")
    func mockAnalyze() async throws {
        let model = mockService()
        let result = try await model.analyzeGrammar(of: segment, languagePair: pair)
        #expect(!result.translation.isEmpty)
        #expect(!result.summary.isEmpty)
        #expect(result.vocabulary.contains(where: { $0.word == "蛙" }))
    }

    @Test("mock translate is non-empty")
    func mockTranslate() async throws {
        let model = mockService()
        let text = try await model.translate(segment, to: pair.target)
        #expect(!text.isEmpty)
    }

    @Test("mock answerStream yields at least one chunk")
    func mockStream() async throws {
        let model = mockService()
        var chunks: [String] = []
        for try await chunk in model.answerStream(
            question: "What is 蛙?", about: segment, languagePair: pair
        ) {
            chunks.append(chunk)
        }
        #expect(!chunks.isEmpty)
        #expect(chunks.joined().contains("蛙") || chunks.joined().contains("Answer"))
    }

    @Test("router OfflineOnly never auto-picks remote without opt-in")
    func routerOfflineOnly() async {
        let remote = RemoteAPIProvider(
            settingsProvider: { RemoteAISettings(enabled: false) },
            apiKeyProvider: { _ in nil }
        )
        let profile = UserProfile(
            preferredLanguagePair: pair,
            remoteAIEnabled: false,
            activeAIProviderID: AIProviderID.remote.rawValue,
            aiFallbackMode: .offlineOnly
        )
        let router = LanguageModelRouter(
            foundation: nil,
            mlx: nil,
            remote: remote,
            profileProvider: { profile }
        )
        await #expect(throws: LanguageModelError.self) {
            _ = try await router.translate(segment, to: "en")
        }
    }

    @Test("router Ask emits fallbackConsentRequired")
    func routerAskConsent() async throws {
        let failing = MockLanguageModelService(
            capabilities: LanguageModelCapabilities(
                supportsStreaming: false,
                supportsOffline: true,
                maxContextTokens: 100,
                providerID: AIProviderID.foundationModels.rawValue
            )
        )
        let mlxOK = mockService()
        let remote = RemoteAPIProvider(
            settingsProvider: { RemoteAISettings(enabled: false) },
            apiKeyProvider: { _ in nil }
        )
        let profile = UserProfile(
            preferredLanguagePair: pair,
            remoteAIEnabled: false,
            activeAIProviderID: AIProviderID.foundationModels.rawValue,
            aiFallbackMode: .ask
        )
        let router = LanguageModelRouter(
            foundation: failing,
            mlx: mlxOK,
            remote: remote,
            profileProvider: { profile }
        )
        do {
            _ = try await router.translate(segment, to: "en")
            Issue.record("Expected fallbackConsentRequired")
        } catch let error as LanguageModelError {
            guard case .fallbackConsentRequired(let preferred, let fallback) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(preferred == AIProviderID.foundationModels.rawValue)
            #expect(fallback == AIProviderID.mlx.rawValue)
            router.allowFallback(to: fallback)
            let text = try await router.translate(segment, to: "en")
            #expect(!text.isEmpty)
        }
    }

    @Test("remote URLProtocol stub completes translate")
    func remoteStub() async throws {
        let stub = URLProtocolStub()
        stub.responseJSON = """
        {"choices":[{"message":{"content":"An old pond."}}]}
        """
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: config)
        let client = ChatTransportClient(session: session)
        let modelConfig = ModelConfig(
            name: "Test",
            apiProvider: .openAICompatible,
            model: "test",
            baseURL: "https://example.test/v1",
            isDefault: true
        )
        let provider = RemoteAPIProvider(
            client: client,
            settingsProvider: {
                RemoteAISettings(enabled: true, configs: [modelConfig])
            },
            apiKeyProvider: { _ in "test-key" }
        )
        let text = try await provider.translate(segment, to: "en")
        #expect(text == "An old pond.")
        _ = stub
    }
}

/// Deterministic HTTP stub for contract tests (not product mock content).
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var sharedResponseJSON: String = #"{"choices":[{"message":{"content":"ok"}}]}"#
    var responseJSON: String {
        get { Self.sharedResponseJSON }
        set { Self.sharedResponseJSON = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.sharedResponseJSON.data(using: .utf8) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
