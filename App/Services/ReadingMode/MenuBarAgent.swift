import AppKit
import SwiftUI

/// Keeps Melingo alive in the menu bar when the main window is closed.
@MainActor
final class MenuBarAgent: NSObject {
    static let shared = MenuBarAgent()

    private var statusItem: NSStatusItem?
    private var readingModeObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "book.closed.fill",
                accessibilityDescription: "Melingo"
            )
            button.image?.isTemplate = true
            button.toolTip = "Melingo"
        }
        item.menu = buildMenu()
        statusItem = item

        readingModeObserver = NotificationCenter.default.addObserver(
            forName: .readingModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusItem?.menu = self?.buildMenu()
            }
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // No windows — open a new one via the SwiftUI scene by posting reopen.
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        if NSApp.windows.isEmpty {
            // Fallback: toggle activation so SwiftUI recreates WindowGroup if needed.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func resignToAccessoryIfNeeded() {
        let visibleMain = NSApp.windows.contains { window in
            guard !(window is NSPanel) else { return false }
            guard window.frame.width > 200 else { return false }
            return window.isVisible && (window.canBecomeMain || window.isMainWindow)
        }
        if !visibleMain {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: AppL10n.t("menuBar.openMelingo"),
            action: #selector(openApp(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let readingTitle = ReadingModeController.shared.isReadingModeActive
            ? AppL10n.t("menuBar.stopReadingMode")
            : AppL10n.t("menuBar.startReadingMode")
        let readingItem = NSMenuItem(
            title: readingTitle,
            action: #selector(toggleReadingMode(_:)),
            keyEquivalent: ""
        )
        readingItem.target = self
        menu.addItem(readingItem)

        if !AccessibilityPermission.isTrusted {
            let axItem = NSMenuItem(
                title: AppL10n.t("menuBar.grantAccessibility"),
                action: #selector(openAccessibility(_:)),
                keyEquivalent: ""
            )
            axItem.target = self
            menu.addItem(axItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: AppL10n.t("menuBar.quit"),
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openApp(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func toggleReadingMode(_ sender: Any?) {
        ReadingModeController.shared.toggle()
        statusItem?.menu = buildMenu()
    }

    @objc private func openAccessibility(_ sender: Any?) {
        AccessibilityPermission.requestIfNeeded()
        AccessibilityPermission.openSystemSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        ReadingModeController.shared.stop()
        NSApp.terminate(nil)
    }
}
