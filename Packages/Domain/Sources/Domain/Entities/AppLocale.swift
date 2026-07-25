import Foundation

/// System-locale helpers shared by profile defaults (no UI bundle coupling).
public enum AppLocale {
    /// Best-effort UI locale from the system preferred languages.
    public static func defaultUILocale() -> String {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let base = preferred.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        switch base {
        case "zh", "cn": return "zh"
        case "jp": return "ja"
        default: return base
        }
    }
}
