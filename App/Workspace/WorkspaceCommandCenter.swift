import Foundation

/// Bridges menu-bar Commands → in-window overlays (Revu `WorkspaceCommandCenter` pattern).
@MainActor
@Observable
final class WorkspaceCommandCenter {
    private(set) var quickFindToken: Int = 0
    private(set) var openReviewWindowToken: Int = 0

    func openQuickFind() {
        quickFindToken &+= 1
    }

    func openReviewWindow() {
        openReviewWindowToken &+= 1
    }
}
