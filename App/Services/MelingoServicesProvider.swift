import AppKit
import Foundation

/// macOS Services: “Add Card to Melingo” / «Добавить карточку в Melingo» from any selection.
@MainActor
final class MelingoServicesProvider: NSObject {
    static let shared = MelingoServicesProvider()

    weak var store: AppLibraryStore?

    func register() {
        NSApp.servicesProvider = self
        // Refresh the Services menu so a newly built/installed app shows up.
        NSUpdateDynamicServices()
    }

    /// Services entry point (`NSMessage` = `addToMelingoCard`).
    @objc func addToMelingoCard(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let text = extractText(from: pboard)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            error?.pointee = "No text selected." as NSString
            return
        }

        // Bring Melingo to the front even if it was accessory / menu-bar only.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MenuBarAgent.shared.showMainWindow()

        MelingoServicesInbox.shared.enqueue(text: text)
        NotificationCenter.default.post(name: .melingoOpenNewCardFromService, object: text)
    }

    private func extractText(from pboard: NSPasteboard) -> String? {
        if let s = pboard.string(forType: .string), !s.isEmpty { return s }
        let types: [NSPasteboard.PasteboardType] = [
            .init("public.utf8-plain-text"),
            .init("public.plain-text"),
            .init("public.utf16-plain-text"),
        ]
        for type in types {
            if let s = pboard.string(forType: type), !s.isEmpty { return s }
        }
        return nil
    }
}

/// Holds pending service text until NewCardView / store is ready.
@MainActor
final class MelingoServicesInbox {
    static let shared = MelingoServicesInbox()
    private(set) var pendingText: String?

    func enqueue(text: String) {
        pendingText = text
    }

    func consume() -> String? {
        defer { pendingText = nil }
        return pendingText
    }
}

extension Notification.Name {
    static let melingoOpenNewCardFromService = Notification.Name("melingo.openNewCardFromService")
}
