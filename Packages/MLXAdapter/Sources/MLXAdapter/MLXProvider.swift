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
///
/// Already-complete folders under Models/ are adopted without re-downloading so Melingo
/// (and other tools pointing at the same path) can reuse weights.
public enum MLXModelDownloader {
    public struct Progress: Sendable {
        public var fraction: Double
        public var detail: String

        public init(fraction: Double, detail: String) {
            self.fraction = fraction
            self.detail = detail
        }
    }

    public static let defaultFileNames: [String] = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "model.safetensors",
        "weights.safetensors",
        "model.safetensors.index.json",
    ]

    public static func folderName(for modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "__")
    }

    /// True when `config.json` exists and weights are present (single file or all index shards).
    public static func isCompleteModelDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        let config = url.appendingPathComponent("config.json")
        guard nonEmptyFileExists(config, fm: fm) else { return false }

        if nonEmptyFileExists(url.appendingPathComponent("model.safetensors"), fm: fm)
            || nonEmptyFileExists(url.appendingPathComponent("weights.safetensors"), fm: fm)
        {
            return true
        }

        let indexURL = url.appendingPathComponent("model.safetensors.index.json")
        guard nonEmptyFileExists(indexURL, fm: fm) else { return false }
        let shards = shardFileNames(inIndexAt: indexURL)
        guard !shards.isEmpty else { return false }
        return shards.allSatisfy { nonEmptyFileExists(url.appendingPathComponent($0), fm: fm) }
    }

    /// Registers config for an already-complete local folder. Returns folder name, or nil.
    @discardableResult
    public static func adoptIfPresent(
        modelID: String,
        modelsRoot: URL? = nil
    ) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let root = modelsRoot ?? MLXProvider.modelsDirectory()
        let name = folderName(for: trimmed)
        let dest = root.appendingPathComponent(name, isDirectory: true)
        guard isCompleteModelDirectory(dest) else { return nil }
        MLXConfigStorage.save(
            MLXConfigStorage.Config(modelID: trimmed, localRelativePath: name)
        )
        return name
    }

    /// Picks the sole complete model folder under `modelsRoot` and adopts it.
    /// If `preferredModelID` matches a complete folder, that wins. Returns adopted model ID.
    @discardableResult
    public static func adoptExistingIfUnconfigured(
        preferredModelID: String? = nil,
        modelsRoot: URL? = nil
    ) -> String? {
        let existing = MLXConfigStorage.load()
        if existing.isConfigured,
           let relative = existing.localRelativePath
        {
            let root = modelsRoot ?? MLXProvider.modelsDirectory()
            let dest = root.appendingPathComponent(relative, isDirectory: true)
            if isCompleteModelDirectory(dest) { return existing.modelID }
        }

        let root = modelsRoot ?? MLXProvider.modelsDirectory()
        if let preferred = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           adoptIfPresent(modelID: preferred, modelsRoot: root) != nil
        {
            return preferred
        }

        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let complete = kids.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
                && isCompleteModelDirectory(url)
        }
        guard complete.count == 1, let only = complete.first else { return nil }
        let folder = only.lastPathComponent
        let modelID = folder.replacingOccurrences(of: "__", with: "/")
        MLXConfigStorage.save(
            MLXConfigStorage.Config(modelID: modelID, localRelativePath: folder)
        )
        return modelID
    }

    public static func download(
        modelID: String,
        fileNames: [String] = defaultFileNames,
        modelsRoot: URL? = nil,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LanguageModelError.malformedResponse }
        let root = modelsRoot ?? MLXProvider.modelsDirectory()
        let name = folderName(for: trimmed)
        let dest = root.appendingPathComponent(name, isDirectory: true)

        if let adopted = adoptIfPresent(modelID: trimmed, modelsRoot: root) {
            onProgress(Progress(fraction: 1, detail: "Already on disk"))
            return adopted
        }

        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        var pending = fileNames
        let indexPath = dest.appendingPathComponent("model.safetensors.index.json")
        if nonEmptyFileExists(indexPath) {
            for shard in shardFileNames(inIndexAt: indexPath) where !pending.contains(shard) {
                pending.append(shard)
            }
        }

        let total = Double(max(pending.count, 1))
        for (index, fileName) in pending.enumerated() {
            let target = dest.appendingPathComponent(fileName)
            if nonEmptyFileExists(target) {
                onProgress(Progress(fraction: Double(index + 1) / total, detail: "Skip \(fileName)"))
                continue
            }
            onProgress(Progress(fraction: Double(index) / total, detail: fileName))
            if try await fetchHuggingFaceFile(modelID: trimmed, fileName: fileName, to: target) {
                // After index lands, queue any missing shards for this same pass.
                if fileName == "model.safetensors.index.json" {
                    let shards = shardFileNames(inIndexAt: target)
                    for shard in shards where !pending.contains(shard) {
                        pending.append(shard)
                    }
                }
            }
        }

        // Second pass for shards discovered after index download (total may have grown).
        let lateShards = shardFileNames(inIndexAt: dest.appendingPathComponent("model.safetensors.index.json"))
            .filter { !nonEmptyFileExists(dest.appendingPathComponent($0)) }
        if !lateShards.isEmpty {
            let lateTotal = Double(lateShards.count)
            for (index, shard) in lateShards.enumerated() {
                onProgress(Progress(fraction: Double(index) / lateTotal, detail: shard))
                let target = dest.appendingPathComponent(shard)
                _ = try await fetchHuggingFaceFile(modelID: trimmed, fileName: shard, to: target)
            }
        }

        guard isCompleteModelDirectory(dest) else {
            throw LanguageModelError.underlying(
                "Download incomplete — could not fetch a complete model for \(trimmed).")
        }
        onProgress(Progress(fraction: 1, detail: "Done"))
        MLXConfigStorage.save(
            MLXConfigStorage.Config(modelID: trimmed, localRelativePath: name)
        )
        return name
    }

    // MARK: - Internals

    private static func nonEmptyFileExists(_ url: URL, fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    /// Unique shard filenames from a Hugging Face safetensors index `weight_map`.
    public static func shardFileNames(inIndexAt url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let map = (json["weight_map"] as? [String: String]) ?? [:]
        var seen = Set<String>()
        var ordered: [String] = []
        for name in map.values {
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    private static func fetchHuggingFaceFile(
        modelID: String,
        fileName: String,
        to target: URL
    ) async throws -> Bool {
        let encoded = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        let urlString = "https://huggingface.co/\(encoded)/resolve/main/\(fileName)"
        guard let url = URL(string: urlString) else { return false }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: temp, to: target)
            return nonEmptyFileExists(target, fm: fm)
        } catch {
            return false
        }
    }
}
