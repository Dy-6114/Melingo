import Foundation

enum QuickCommandAction: Hashable {
    case go(WorkspaceDestination)
    case openSettings
    case openPack(UUID)
    case openVocabulary(UUID)
    case startReview
}

struct QuickCommandResult: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let badge: String?
    let action: QuickCommandAction
}
