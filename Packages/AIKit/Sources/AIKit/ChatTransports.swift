import Foundation
import Domain

/// Shared JSON → GrammarBreakdown parser (remote + MLX structured prompts).
public enum LLMJSONExtractor {
    public static func parseGrammarBreakdown(from raw: String) throws -> GrammarBreakdown {
        let json = extractJSONObject(from: raw) ?? raw
        guard let data = json.data(using: .utf8) else {
            throw LanguageModelError.malformedResponse
        }
        let decoded = try JSONDecoder().decode(ExplainDTO.self, from: data)
        return GrammarBreakdown(
            translation: decoded.translation,
            summary: decoded.explanation,
            readingText: decoded.reading,
            notes: (decoded.grammar_points ?? []).map {
                GrammarNote(point: $0.point, explanation: $0.explanation, example: $0.example)
            },
            vocabulary: (decoded.vocabulary ?? []).map {
                VocabularyItem(
                    word: $0.word,
                    meaning: $0.meaning,
                    usage: $0.usage,
                    example: $0.example,
                    reading: $0.reading
                )
            },
            culturalContext: decoded.cultural_context,
            difficultyLevel: decoded.difficulty_level,
            learningTips: decoded.learning_tips
        )
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}")
        else { return nil }
        return String(text[start...end])
    }

    private struct ExplainDTO: Decodable {
        var translation: String
        var explanation: String
        var reading: String?
        var vocabulary: [VocabDTO]?
        var grammar_points: [GrammarDTO]?
        var cultural_context: String?
        var difficulty_level: String?
        var learning_tips: String?
    }

    private struct VocabDTO: Decodable {
        var word: String
        var meaning: String
        var usage: String?
        var example: String?
        var reading: String?
    }

    private struct GrammarDTO: Decodable {
        var point: String
        var explanation: String
        var example: String?
    }
}

/// Multi-provider chat complete + SSE stream (OpenAI / Anthropic / Gemini).
public struct ChatTransportClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        remoteEnabled: Bool,
        temperature: Double = 0.3,
        timeout: TimeInterval = 120
    ) async throws -> String {
        guard remoteEnabled else { throw LanguageModelError.remoteOptInRequired }
        let cap = config.capability
        let temp = cap.forcesTemperatureOne ? 1.0 : temperature
        switch cap.kind {
        case .openAICompatible:
            return try await openAIComplete(
                systemPrompt: systemPrompt, userMessage: userMessage,
                config: config, apiKey: apiKey, temperature: temp, timeout: timeout, stream: false
            )
        case .anthropic:
            return try await anthropicComplete(
                systemPrompt: systemPrompt, userMessage: userMessage,
                config: config, apiKey: apiKey, temperature: temp, timeout: timeout
            )
        case .gemini:
            return try await geminiComplete(
                systemPrompt: systemPrompt, userMessage: userMessage,
                config: config, apiKey: apiKey, temperature: temp, timeout: timeout
            )
        }
    }

    public func stream(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        remoteEnabled: Bool,
        temperature: Double = 0.3,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard remoteEnabled else { throw LanguageModelError.remoteOptInRequired }
                    let cap = config.capability
                    let temp = cap.forcesTemperatureOne ? 1.0 : temperature
                    switch cap.kind {
                    case .openAICompatible:
                        try await openAIStream(
                            systemPrompt: systemPrompt, userMessage: userMessage,
                            config: config, apiKey: apiKey, temperature: temp,
                            timeout: timeout, continuation: continuation
                        )
                    case .anthropic:
                        try await anthropicStream(
                            systemPrompt: systemPrompt, userMessage: userMessage,
                            config: config, apiKey: apiKey, temperature: temp,
                            timeout: timeout, continuation: continuation
                        )
                    case .gemini:
                        // Gemini stream via SSE generateContent; fall back to one-shot if needed.
                        let text = try await geminiComplete(
                            systemPrompt: systemPrompt, userMessage: userMessage,
                            config: config, apiKey: apiKey, temperature: temp, timeout: timeout
                        )
                        continuation.yield(text)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - OpenAI compatible

    private func openAIEndpoint(_ config: ModelConfig) throws -> URL {
        let cap = config.capability
        if let custom = config.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let base = custom.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if base.hasSuffix("/chat/completions") {
                guard let url = URL(string: base) else { throw LanguageModelError.malformedResponse }
                return url
            }
            guard let url = URL(string: base + "/chat/completions") else {
                throw LanguageModelError.malformedResponse
            }
            return url
        }
        guard let url = cap.defaultEndpoint else {
            throw LanguageModelError.malformedResponse
        }
        return url
    }

    private func openAIComplete(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        temperature: Double,
        timeout: TimeInterval,
        stream: Bool
    ) async throws -> String {
        let request = try openAIRequest(
            systemPrompt: systemPrompt, userMessage: userMessage,
            config: config, apiKey: apiKey, temperature: temperature,
            timeout: timeout, stream: false
        )
        let (data, response) = try await perform(request)
        try throwIfHTTPError(response)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LanguageModelError.malformedResponse }
        return content
    }

    private func openAIStream(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        temperature: Double,
        timeout: TimeInterval,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let request = try openAIRequest(
            systemPrompt: systemPrompt, userMessage: userMessage,
            config: config, apiKey: apiKey, temperature: temperature,
            timeout: timeout, stream: true
        )
        let (bytes, response) = try await session.bytes(for: request)
        try throwIfHTTPError(response)
        for try await line in bytes.lines {
            if Task.isCancelled { throw LanguageModelError.cancelled }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty
            else { continue }
            continuation.yield(content)
        }
        continuation.finish()
    }

    private func openAIRequest(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        temperature: Double,
        timeout: TimeInterval,
        stream: Bool
    ) throws -> URLRequest {
        let endpoint = try openAIEndpoint(config)
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        let cap = config.capability
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else if !cap.allowsEmptyKey {
            throw LanguageModelError.unauthorized
        }
        let body: [String: Any] = [
            "model": config.model,
            "temperature": temperature,
            "stream": stream,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Anthropic

    private func anthropicComplete(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        temperature: Double,
        timeout: TimeInterval
    ) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw LanguageModelError.unauthorized }
        let url = config.baseURL.flatMap(URL.init(string:))
            ?? config.capability.defaultEndpoint
            ?? URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
            "temperature": temperature,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await perform(request)
        try throwIfHTTPError(response)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else { throw LanguageModelError.malformedResponse }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LanguageModelError.malformedResponse }
        return text
    }

    private func anthropicStream(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        temperature: Double,
        timeout: TimeInterval,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let apiKey, !apiKey.isEmpty else { throw LanguageModelError.unauthorized }
        let url = config.baseURL.flatMap(URL.init(string:))
            ?? config.capability.defaultEndpoint
            ?? URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
            "temperature": temperature,
            "stream": true,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        try throwIfHTTPError(response)
        for try await line in bytes.lines {
            if Task.isCancelled { throw LanguageModelError.cancelled }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = root["type"] as? String
            else { continue }
            if type == "content_block_delta",
               let delta = root["delta"] as? [String: Any],
               let text = delta["text"] as? String,
               !text.isEmpty {
                continuation.yield(text)
            }
            if type == "message_stop" { break }
        }
        continuation.finish()
    }

    // MARK: - Gemini

    private func geminiComplete(
        systemPrompt: String,
        userMessage: String,
        config: ModelConfig,
        apiKey: String?,
        temperature: Double,
        timeout: TimeInterval
    ) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw LanguageModelError.unauthorized }
        let model = config.model.isEmpty ? "gemini-2.0-flash" : config.model
        let urlString: String
        if let custom = config.baseURL, !custom.isEmpty {
            urlString = custom
        } else {
            urlString =
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        }
        guard let url = URL(string: urlString) else { throw LanguageModelError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": userMessage]]]],
            "generationConfig": ["temperature": temperature],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await perform(request)
        try throwIfHTTPError(response)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { throw LanguageModelError.malformedResponse }
        return text
    }

    // MARK: - Shared

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw LanguageModelError.cancelled
        } catch {
            throw LanguageModelError.networkUnreachable
        }
    }

    private func throwIfHTTPError(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw LanguageModelError.unauthorized
        case 429: throw LanguageModelError.rateLimited
        default: throw LanguageModelError.underlying("HTTP \(http.statusCode)")
        }
    }
}

/// Legacy name kept for call sites that still construct OpenAICompatibleClient.
public typealias OpenAICompatibleClient = ChatTransportClient
