import Foundation
import Domain
import AIKit

/// Local open-weight provider. Never ships weights — user must download a model first.
///
/// Inference backend: when `mlx-swift-lm` is linked into the app target (optional),
/// set `MLXProvider.sharedEngine` to a real engine. Until then, configured models
/// still download to `~/Documents/Melingo/Models`, and generate throws `providerUnavailable`
/// (no fabricated text).
public final class MLXProvider: LanguageModelServicing, @unchecked Sendable {
    nonisolated(unsafe) public static var sharedEngine: (any MLXInferenceEngining)?

    private let configProvider: @Sendable () -> MLXConfigStorage.Config
    private let modelsRoot: URL

    public init(
        configProvider: @escaping @Sendable () -> MLXConfigStorage.Config = { MLXConfigStorage.load() },
        modelsRoot: URL? = nil
    ) {
        self.configProvider = configProvider
        if let modelsRoot {
            self.modelsRoot = modelsRoot
        } else {
            self.modelsRoot = Self.modelsDirectory()
        }
    }

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(
            supportsStreaming: true,
            supportsOffline: true,
            maxContextTokens: 8_192,
            providerID: AIProviderID.mlx.rawValue
        )
    }

    public var isReady: Bool {
        let config = configProvider()
        guard config.isConfigured, let relative = config.localRelativePath else { return false }
        let url = modelsRoot.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path)
            && Self.sharedEngine != nil
    }

    public var hasDownloadedWeights: Bool {
        let config = configProvider()
        guard let relative = config.localRelativePath else { return false }
        return FileManager.default.fileExists(
            atPath: modelsRoot.appendingPathComponent(relative).path)
    }

    public static func modelsDirectory() -> URL {
        MelingoPaths.ensureRoot()
        return MelingoPaths.models
    }

    /// Clears Keychain/UserDefaults config and deletes downloaded weight folders on disk.
    @discardableResult
    public func clearModel(deleteFiles: Bool = true) -> Bool {
        let config = configProvider()
        var removed = false
        if deleteFiles {
            let fm = FileManager.default
            if let relative = config.localRelativePath {
                let url = modelsRoot.appendingPathComponent(relative)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                    removed = true
                }
            }
            // Also wipe any leftover folders under Models/ (re-download clean slate).
            if fm.fileExists(atPath: modelsRoot.path) {
                if let kids = try? fm.contentsOfDirectory(
                    at: modelsRoot, includingPropertiesForKeys: nil
                ) {
                    for kid in kids where kid.hasDirectoryPath {
                        try? fm.removeItem(at: kid)
                        removed = true
                    }
                }
            }
        }
        MLXConfigStorage.save(MLXConfigStorage.Config())
        return removed || !config.modelID.isEmpty
    }

    public func explainWord(_ word: String, in context: TextContext) async throws -> AIExplanation {
        let breakdown = try await analyzeGrammar(
            of: context.segment, languagePair: context.languagePair)
        let filtered = GrammarBreakdown(
            translation: breakdown.translation,
            summary: breakdown.summary,
            readingText: breakdown.readingText,
            notes: breakdown.notes,
            vocabulary: breakdown.vocabulary.filter {
                $0.word.localizedCaseInsensitiveContains(word)
                    || word.localizedCaseInsensitiveContains($0.word)
            },
            culturalContext: breakdown.culturalContext,
            difficultyLevel: breakdown.difficultyLevel,
            learningTips: breakdown.learningTips
        )
        return AIExplanation(breakdown: filtered.isEmptyVocabFallback(word: word, from: breakdown))
    }

    public func analyzeGrammar(of segment: TextSegment, languagePair: LanguagePair) async throws -> GrammarBreakdown {
        let raw = try await complete(
            system: PromptLibrary.segmentExplainSystemPrompt(
                text: segment.text, targetLanguage: languagePair.target),
            user: PromptLibrary.analyzeUserMessage(
                text: segment.text, targetLanguage: languagePair.target)
        )
        return try LLMJSONExtractor.parseGrammarBreakdown(from: raw)
    }

    public func answer(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> AIAnswer {
        let text = try await complete(
            system: PromptLibrary.tutorSystemPrompt(
                nativeLanguage: languagePair.target,
                segmentText: segment.text
            ),
            user: PromptLibrary.clipForContext(question, maxChars: PromptLibrary.answerMaxInputChars)
        )
        return AIAnswer(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func translate(_ segment: TextSegment, to targetLanguage: String) async throws -> String {
        try await complete(
            system: PromptLibrary.segmentTranslateSystemPrompt(targetLanguage: targetLanguage),
            user: segment.text
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        try await complete(system: systemPrompt, user: userMessage)
    }

    public func generateReadingLine(
        for segment: TextSegment,
        languagePair: LanguagePair
    ) async throws -> String {
        if let local = ReadingLineBuilder.localReading(
            for: segment.text, sourceLanguage: languagePair.source
        ) {
            return local
        }
        return try await complete(
            system: PromptLibrary.segmentReadingSystemPrompt(sourceLanguage: languagePair.source),
            user: segment.text
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func answerStream(
        question: String,
        about segment: TextSegment,
        languagePair: LanguagePair
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let engine = Self.sharedEngine, hasDownloadedWeights else {
                        throw LanguageModelError.providerUnavailable
                    }
                    let config = configProvider()
                    guard let relative = config.localRelativePath else {
                        throw LanguageModelError.providerUnavailable
                    }
                    let modelURL = modelsRoot.appendingPathComponent(relative)
                    let system = PromptLibrary.tutorSystemPrompt(
                        nativeLanguage: languagePair.target,
                        segmentText: segment.text
                    )
                    let clipped = PromptLibrary.clipForContext(
                        question, maxChars: PromptLibrary.answerMaxInputChars
                    )
                    for try await chunk in engine.stream(
                        system: system, user: clipped, modelDirectory: modelURL
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func complete(system: String, user: String) async throws -> String {
        guard let engine = Self.sharedEngine, hasDownloadedWeights else {
            throw LanguageModelError.providerUnavailable
        }
        let config = configProvider()
        guard let relative = config.localRelativePath else {
            throw LanguageModelError.providerUnavailable
        }
        let modelURL = modelsRoot.appendingPathComponent(relative)
        let text = try await engine.complete(system: system, user: user, modelDirectory: modelURL)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LanguageModelError.malformedResponse }
        return trimmed
    }
}

/// Pluggable MLX runtime (implemented in App when mlx-swift-lm is linked).
public protocol MLXInferenceEngining: Sendable {
    func complete(system: String, user: String, modelDirectory: URL) async throws -> String
    func stream(system: String, user: String, modelDirectory: URL) -> AsyncThrowingStream<String, Error>
}

/// Downloads an MLX Hugging Face repo into `~/Documents/Melingo/Models` (user-initiated only).
public enum MLXModelDownloader {
    public struct Progress: Sendable {
        public var fraction: Double
        public var detail: String

        public init(fraction: Double, detail: String) {
            self.fraction = fraction
            self.detail = detail
        }
    }

    public static func download(
        modelID: String,
        fileNames: [String] = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "model.safetensors",
            "weights.safetensors",
            "model.safetensors.index.json",
        ],
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LanguageModelError.malformedResponse }
        let root = MLXProvider.modelsDirectory()
        let folderName = trimmed.replacingOccurrences(of: "/", with: "__")
        let dest = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let total = Double(max(fileNames.count, 1))
        var savedAny = false
        for (index, name) in fileNames.enumerated() {
            onProgress(Progress(fraction: Double(index) / total, detail: name))
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
            let urlString = "https://huggingface.co/\(encoded)/resolve/main/\(name)"
            guard let url = URL(string: urlString) else { continue }
            do {
                let (temp, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continue
                }
                let target = dest.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temp, to: target)
                savedAny = true
            } catch {
                continue
            }
        }
        let configPath = dest.appendingPathComponent("config.json")
        guard savedAny, FileManager.default.fileExists(atPath: configPath.path) else {
            throw LanguageModelError.underlying(
                "Download incomplete — could not fetch config.json for \(trimmed).")
        }
        onProgress(Progress(fraction: 1, detail: "Done"))
        MLXConfigStorage.save(
            MLXConfigStorage.Config(modelID: trimmed, localRelativePath: folderName)
        )
        return folderName
    }
}
