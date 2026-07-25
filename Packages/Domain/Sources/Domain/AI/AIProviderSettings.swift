import Foundation

/// Preferred on-device / remote AI backend id (Settings + router).
public enum AIProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case foundationModels = "foundation-models"
    /// Apple Intelligence for snappy lookups; MLX for deeper analysis when both are ready.
    case hybrid = "hybrid"
    case mlx = "mlx"
    case remote = "remote"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .foundationModels: "Apple Intelligence"
        case .hybrid: "Smart Mix (Apple + MLX)"
        case .mlx: "MLX (Local)"
        case .remote: "Remote API"
        }
    }
}

/// Fallback when preferred provider is unavailable (TECHNICAL_DECISIONS §4).
public enum AIFallbackMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case offlineOnly
    case ask

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .offlineOnly: "Offline only"
        case .ask: "Ask"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            "Use only the preferred provider. Show an error if it fails."
        case .offlineOnly:
            "If Apple Intelligence fails, try MLX. Never call remote automatically."
        case .ask:
            "If the preferred provider fails, ask before trying another offline provider."
        }
    }
}
