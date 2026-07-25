import AppKit

/// Expands the main window sideways so reader + inspector fit comfortably.
enum ReaderWindowSizing {
    static let preferredWidth: CGFloat = 1380
    static let preferredHeight: CGFloat = 860

    @MainActor
    static func expandForReader(animated: Bool = true) {
        guard let window = NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })
        else { return }

        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        var frame = window.frame

        let targetW = min(max(frame.width, preferredWidth), visible.width - 24)
        let targetH = min(max(frame.height, preferredHeight), visible.height - 24)
        guard targetW > frame.width + 1 || targetH > frame.height + 1 else { return }

        // Grow primarily to the right / down; clamp into the visible screen.
        let extraW = targetW - frame.width
        frame.size.width = targetW
        frame.size.height = targetH
        if frame.maxX > visible.maxX {
            frame.origin.x = max(visible.minX + 12, visible.maxX - frame.width - 12)
        } else if extraW > 0 {
            // keep left edge stable (expand sideways)
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = max(visible.minY + 12, visible.maxY - frame.height - 12)
        }

        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }
}
