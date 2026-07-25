import Foundation

/// Lightweight preferences collected during onboarding (avoids SwiftData migration).
enum OnboardingPrefs {
    private static let goalKey = "onboarding.learningGoal"
    private static let tipsKey = "onboarding.hasCompletedTips"

    /// Stored as preset id (`travel`, `work`, …) or free-text for `custom`.
    static var learningGoal: String {
        get { UserDefaults.standard.string(forKey: goalKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: goalKey) }
    }

    static var hasCompletedTips: Bool {
        get { UserDefaults.standard.bool(forKey: tipsKey) }
        set { UserDefaults.standard.set(newValue, forKey: tipsKey) }
    }

    static let goalPresetIDs: [(id: String, symbol: String)] = [
        ("travel", "airplane"),
        ("work", "briefcase"),
        ("media", "book"),
        ("exam", "graduationcap"),
        ("custom", "pencil"),
    ]

    static func goalTitle(for id: String) -> String {
        switch id {
        case "travel": return AppL10n.t("onboarding.goal.travel.title")
        case "work": return AppL10n.t("onboarding.goal.work.title")
        case "media": return AppL10n.t("onboarding.goal.media.title")
        case "exam": return AppL10n.t("onboarding.goal.exam.title")
        case "custom": return AppL10n.t("onboarding.goal.custom.title")
        default: return id
        }
    }

    static func goalDetail(for id: String) -> String {
        switch id {
        case "travel": return AppL10n.t("onboarding.goal.travel.detail")
        case "work": return AppL10n.t("onboarding.goal.work.detail")
        case "media": return AppL10n.t("onboarding.goal.media.detail")
        case "exam": return AppL10n.t("onboarding.goal.exam.detail")
        case "custom": return AppL10n.t("onboarding.goal.custom.detail")
        default: return ""
        }
    }

    /// Localized label for Settings / UI (resolves stored id or shows custom text).
    static var localizedLearningGoal: String {
        let raw = learningGoal
        guard !raw.isEmpty else { return "" }
        let known = Set(goalPresetIDs.map(\.id))
        if known.contains(raw) { return goalTitle(for: raw) }
        return raw
    }
}
