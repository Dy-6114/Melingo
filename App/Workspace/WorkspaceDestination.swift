import Foundation

/// Sidebar / command-palette destinations (Revu `SidebarItem` idea, Melingo-shaped).
enum WorkspaceDestination: Hashable {
    case study
    case newCard
    case history
    case stats
    case vocabulary
    case library
    case myPacks
    case smart(SmartFilter)
    case tag(UUID)
    case pinnedPack(UUID)

    var breadcrumbTitle: String {
        switch self {
        case .study: AppL10n.t("sidebar.study")
        case .newCard: AppL10n.t("sidebar.newCard")
        case .history: AppL10n.t("sidebar.history")
        case .stats: AppL10n.t("sidebar.stats")
        case .vocabulary: AppL10n.t("sidebar.vocabulary")
        case .library: AppL10n.t("sidebar.articles")
        case .myPacks: AppL10n.t("sidebar.myPacks")
        case .smart(let filter): AppL10n.t(filter.titleKey)
        case .tag, .pinnedPack: AppL10n.t("sidebar.myPacks")
        }
    }
}
