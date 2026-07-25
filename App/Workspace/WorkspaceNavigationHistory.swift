import Foundation

/// Back/forward stack for sidebar destinations (Revu `WorkspaceNavigationHistory`).
@MainActor
@Observable
final class WorkspaceNavigationHistory {
    private(set) var stack: [WorkspaceDestination] = [.study]
    private(set) var cursor: Int = 0

    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { cursor < stack.count - 1 }

    var current: WorkspaceDestination {
        guard cursor >= 0, cursor < stack.count else { return .study }
        return stack[cursor]
    }

    func push(_ item: WorkspaceDestination) {
        if current == item { return }
        if cursor < stack.count - 1 {
            stack = Array(stack[0...cursor])
        }
        stack.append(item)
        cursor = stack.count - 1
        if stack.count > 64 {
            let drop = stack.count - 64
            stack.removeFirst(drop)
            cursor -= drop
        }
    }

    func goBack() -> WorkspaceDestination? {
        guard canGoBack else { return nil }
        cursor -= 1
        return stack[cursor]
    }

    func goForward() -> WorkspaceDestination? {
        guard canGoForward else { return nil }
        cursor += 1
        return stack[cursor]
    }

    var crumbs: [WorkspaceDestination] {
        guard cursor >= 0 else { return [] }
        let start = max(0, cursor - 3)
        return Array(stack[start...cursor])
    }
}
