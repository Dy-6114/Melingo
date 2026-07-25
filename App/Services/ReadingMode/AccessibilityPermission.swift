import ApplicationServices
import AppKit
import Foundation

/// Stable Accessibility (TCC) checks. Trust sticks across app updates when Bundle ID
/// (`com.melingo.mac`) and Developer Team ID stay the same.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts only when not already trusted. Safe to call repeatedly — macOS will not
    /// re-prompt after the user has granted access for this code-signed identity.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Literal key avoids Swift 6 shared-mutable warning on `kAXTrustedCheckOptionPrompt`.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        // macOS 13+ Privacy → Accessibility pane
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
