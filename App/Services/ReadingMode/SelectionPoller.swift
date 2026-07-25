import ApplicationServices
import AppKit
import Foundation

/// Detects selected text in other apps while reading mode is active.
/// Primary: Accessibility selected-text. Fallback on mouse-up: Cmd+C + pasteboard peek.
@MainActor
final class SelectionPoller {
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var lastEmitted = ""
    private var copyInFlight = false
    var onSelection: ((String) -> Void)?

    func start(interval: TimeInterval = 0.25) {
        stop()
        lastEmitted = ""
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickAX()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            Task { @MainActor in
                // Let the host app finish updating its selection first.
                try? await Task.sleep(nanoseconds: 80_000_000)
                self?.captureAfterMouseUp()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func tickAX() {
        guard AccessibilityPermission.isTrusted else { return }
        guard let text = Self.readSelectedText() else { return }
        emit(text)
    }

    private func captureAfterMouseUp() {
        guard AccessibilityPermission.isTrusted else { return }
        if let text = Self.readSelectedText() {
            emit(text)
            return
        }
        // Browsers / Electron often omit AX selected text — peek via Cmd+C once.
        guard !copyInFlight else { return }
        copyInFlight = true
        Task { @MainActor in
            defer { copyInFlight = false }
            if let text = await Self.readViaTransientCopy() {
                emit(text)
            }
        }
    }

    private func emit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= 120 else { return }
        // Ignore Melingo’s own hint if somehow copied.
        guard trimmed != lastEmitted else { return }
        lastEmitted = trimmed
        onSelection?(trimmed)
    }

    // MARK: - Accessibility

    /// Reads selected text from the frontmost non-Melingo app.
    nonisolated static func readSelectedText() -> String? {
        if let text = readFromFocusedElement() { return text }
        if let text = readFromFocusedApplication() { return text }
        return nil
    }

    nonisolated private static func readFromFocusedElement() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedStatus == .success, let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement
        if let text = selectedText(from: focused) { return text }

        var current: AXUIElement? = focused
        for _ in 0..<8 {
            guard let el = current else { break }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) != .success {
                break
            }
            guard let parentRef else { break }
            let parent = parentRef as! AXUIElement
            if let text = selectedText(from: parent) { return text }
            current = parent
        }
        return nil
    }

    nonisolated private static func readFromFocusedApplication() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        ) == .success, let appRef else { return nil }
        let app = appRef as! AXUIElement

        // Skip Melingo itself (HUD / main window focused).
        var pid: pid_t = 0
        if AXUIElementGetPid(app, &pid) == .success,
           pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef {
            if let text = selectedText(from: focusedRef as! AXUIElement) { return text }
        }
        return selectedText(from: app)
    }

    nonisolated private static func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success, let value {
            if let string = value as? String, !string.isEmpty { return string }
        }
        // Fallback: value + selected range (common in text fields).
        return textFromSelectedRange(element)
    }

    nonisolated private static func textFromSelectedRange(_ element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef else { return nil }

        // Preferred: parameterized string-for-range.
        var paramResult: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeRef,
            &paramResult
        ) == .success, let string = paramResult as? String, !string.isEmpty {
            return string
        }

        var fullRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &fullRef
        ) == .success, let full = fullRef as? String, !full.isEmpty else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range),
              range.length > 0,
              range.location >= 0,
              range.location + range.length <= full.utf16.count
        else { return nil }

        let start = full.utf16.index(full.utf16.startIndex, offsetBy: range.location)
        let end = full.utf16.index(start, offsetBy: range.length)
        guard let from = String.Index(start, within: full),
              let to = String.Index(end, within: full)
        else { return nil }
        let slice = String(full[from..<to])
        return slice.isEmpty ? nil : slice
    }

    // MARK: - Clipboard peek

    /// Briefly copies the current selection, reads it, restores the pasteboard.
    nonisolated private static func readViaTransientCopy() async -> String? {
        let board = NSPasteboard.general
        let previousChange = board.changeCount
        let backupTypes = board.types
        var backup: [NSPasteboard.PasteboardType: Data] = [:]
        if let backupTypes {
            for type in backupTypes {
                if let data = board.data(forType: type) {
                    backup[type] = data
                }
            }
        }

        await MainActor.run {
            Self.postCommandC()
        }
        // Wait for the target app to place text on the pasteboard.
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if board.changeCount != previousChange {
                break
            }
        }

        let copied = board.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Restore previous clipboard.
        board.clearContents()
        if !backup.isEmpty {
            board.writeObjects([]) // ensure cleared
            for (type, data) in backup {
                board.setData(data, forType: type)
            }
        }

        guard let copied, !copied.isEmpty, copied.count <= 120 else { return nil }
        return copied
    }

    nonisolated private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
