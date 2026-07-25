import Foundation

/// Single source of truth for main-window navigation (avoids god RootView).
@MainActor
@Observable
final class WorkspaceRouter {
    private var suppressHistoryPush = false

    var destination: WorkspaceDestination = .study {
        didSet {
            if !suppressHistoryPush, oldValue != destination {
                history.push(destination)
            }
        }
    }

    let history = WorkspaceNavigationHistory()

    /// Optional vocab highlight after Quick Find → card.
    var focusedVocabularyID: UUID?
    /// Consumed by `StudyHubView` to push a mode (e.g. Review from ⌘K / menu).
    var pendingStudyMode: StudyDestination?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var breadcrumbs: [WorkspaceDestination] { history.crumbs }

    func navigate(to dest: WorkspaceDestination) {
        focusedVocabularyID = nil
        destination = dest
    }

    func goBack() {
        guard let item = history.goBack() else { return }
        focusedVocabularyID = nil
        suppressHistoryPush = true
        destination = item
        suppressHistoryPush = false
    }

    func goForward() {
        guard let item = history.goForward() else { return }
        focusedVocabularyID = nil
        suppressHistoryPush = true
        destination = item
        suppressHistoryPush = false
    }

    func openStudy(_ mode: StudyDestination? = nil) {
        navigate(to: .study)
        pendingStudyMode = mode
    }

    func openSmart(_ filter: SmartFilter) {
        navigate(to: .smart(filter))
    }
}
