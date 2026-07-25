import Foundation
import Domain

/// Remote vendor id — mirrors iOS `ProviderID` / desktop `api_provider`.
public enum RemoteProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case openai
    case deepseek
    case openrouter
    case siliconflow
    case ai302 = "302ai"
    case google
    case anthropic
    case moonshot
    case kimi
    case ollama
    case lmstudio
    case openAICompatible = "openai-compatible"

    public var id: String { rawValue }
}

public enum RemoteProviderKind: Sendable, Equatable {
    case openAICompatible
    case anthropic
    case gemini
}

public struct ProviderCapability: Sendable, Equatable, Identifiable {
    public var id: RemoteProviderID { providerID }
    public let providerID: RemoteProviderID
    public let displayName: String
    public let kind: RemoteProviderKind
    public let defaultEndpoint: URL?
    public let requiresCustomBaseURL: Bool
    public let isLocalProvider: Bool
    public let allowsEmptyKey: Bool
    public let forcesTemperatureOne: Bool
    public let privacyPolicyURL: URL?
    public let supportsStreaming: Bool

    public init(
        providerID: RemoteProviderID,
        displayName: String,
        kind: RemoteProviderKind,
        defaultEndpoint: String?,
        requiresCustomBaseURL: Bool = false,
        isLocalProvider: Bool = false,
        forcesTemperatureOne: Bool = false,
        privacyPolicyURL: String? = nil,
        supportsStreaming: Bool = true
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.kind = kind
        self.defaultEndpoint = defaultEndpoint.flatMap(URL.init(string:))
        self.requiresCustomBaseURL = requiresCustomBaseURL
        self.isLocalProvider = isLocalProvider
        self.allowsEmptyKey = isLocalProvider
        self.forcesTemperatureOne = forcesTemperatureOne
        self.privacyPolicyURL = privacyPolicyURL.flatMap(URL.init(string:))
        self.supportsStreaming = supportsStreaming
    }

    public static let all: [ProviderCapability] = [
        .init(providerID: .openai, displayName: "OpenAI", kind: .openAICompatible,
              defaultEndpoint: "https://api.openai.com/v1/chat/completions",
              privacyPolicyURL: "https://openai.com/policies/privacy-policy"),
        .init(providerID: .deepseek, displayName: "DeepSeek", kind: .openAICompatible,
              defaultEndpoint: "https://api.deepseek.com/v1/chat/completions",
              privacyPolicyURL: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"),
        .init(providerID: .openrouter, displayName: "OpenRouter", kind: .openAICompatible,
              defaultEndpoint: "https://openrouter.ai/api/v1/chat/completions",
              privacyPolicyURL: "https://openrouter.ai/privacy"),
        .init(providerID: .siliconflow, displayName: "SiliconFlow", kind: .openAICompatible,
              defaultEndpoint: "https://api.siliconflow.cn/v1/chat/completions",
              privacyPolicyURL: "https://siliconflow.cn/zh-cn/privacy-policy"),
        .init(providerID: .ai302, displayName: "302.AI", kind: .openAICompatible,
              defaultEndpoint: "https://api.302.ai/v1/chat/completions",
              privacyPolicyURL: "https://302.ai/privacy/"),
        .init(providerID: .google, displayName: "Google Gemini", kind: .gemini,
              defaultEndpoint: nil,
              privacyPolicyURL: "https://ai.google.dev/gemini-api/terms"),
        .init(providerID: .anthropic, displayName: "Anthropic", kind: .anthropic,
              defaultEndpoint: "https://api.anthropic.com/v1/messages",
              privacyPolicyURL: "https://www.anthropic.com/legal/privacy"),
        .init(providerID: .moonshot, displayName: "Moonshot (Kimi CN)", kind: .openAICompatible,
              defaultEndpoint: "https://api.moonshot.cn/v1/chat/completions",
              forcesTemperatureOne: true,
              privacyPolicyURL: "https://platform.moonshot.cn/docs/agreement/privacy"),
        .init(providerID: .kimi, displayName: "Kimi (Global)", kind: .openAICompatible,
              defaultEndpoint: "https://api.moonshot.ai/v1/chat/completions",
              forcesTemperatureOne: true,
              privacyPolicyURL: "https://platform.moonshot.ai/docs/agreement/privacy"),
        .init(providerID: .ollama, displayName: "Ollama", kind: .openAICompatible,
              defaultEndpoint: "http://localhost:11434/v1/chat/completions",
              requiresCustomBaseURL: true, isLocalProvider: true),
        .init(providerID: .lmstudio, displayName: "LM Studio", kind: .openAICompatible,
              defaultEndpoint: "http://localhost:1234/v1/chat/completions",
              requiresCustomBaseURL: true, isLocalProvider: true),
        .init(providerID: .openAICompatible, displayName: "OpenAI Compatible", kind: .openAICompatible,
              defaultEndpoint: nil, requiresCustomBaseURL: true),
    ]

    public static func capability(for id: RemoteProviderID) -> ProviderCapability {
        all.first { $0.providerID == id } ?? all[0]
    }
}

/// Remote model slot (API key lives in Keychain by `id`).
public struct ModelConfig: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var apiProvider: RemoteProviderID
    public var model: String
    public var baseURL: String?
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        apiProvider: RemoteProviderID,
        model: String,
        baseURL: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.apiProvider = apiProvider
        self.model = model
        self.baseURL = baseURL
        self.isDefault = isDefault
    }

    public var capability: ProviderCapability {
        ProviderCapability.capability(for: apiProvider)
    }
}

/// Persisted remote AI settings (multi-config).
public struct RemoteAISettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var configs: [ModelConfig]

    public init(enabled: Bool = false, configs: [ModelConfig] = []) {
        self.enabled = enabled
        self.configs = configs
    }

    public var defaultConfig: ModelConfig? {
        configs.first(where: \.isDefault) ?? configs.first
    }
}

/// Legacy single-config shape (bridged for older UserDefaults).
public struct RemoteModelConfig: Codable, Sendable, Equatable {
    public var displayName: String
    public var model: String
    public var baseURL: String
    public var enabled: Bool
    public var providerRaw: String

    public init(
        displayName: String = "OpenAI Compatible",
        model: String = "gpt-4o-mini",
        baseURL: String = "https://api.openai.com/v1",
        enabled: Bool = false,
        providerRaw: String = RemoteProviderID.openAICompatible.rawValue
    ) {
        self.displayName = displayName
        self.model = model
        self.baseURL = baseURL
        self.enabled = enabled
        self.providerRaw = providerRaw
    }

    public var providerID: RemoteProviderID {
        RemoteProviderID(rawValue: providerRaw) ?? .openAICompatible
    }

    public func asModelConfig() -> ModelConfig {
        ModelConfig(
            name: displayName,
            apiProvider: providerID,
            model: model,
            baseURL: baseURL,
            isDefault: true
        )
    }
}
