import SwiftUI
import AppKit
import DataKit

@main
struct MelingoMacApp: App {
    @NSApplicationDelegateAdaptor(MelingoAppDelegate.self) private var appDelegate
    @State private var store: AppLibraryStore?
    @State private var themeManager = ThemeManager()
    @State private var router = WorkspaceRouter()
    @State private var commandCenter = WorkspaceCommandCenter()
    @State private var bootError: String?
    /// Prevents re-entrant boot when SwiftUI recreates the loading branch (theme / scheme churn).
    @State private var didStartBoot = false
    @State private var showShortcutsHelp = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    if store.profile.hasCompletedOnboarding {
                        RootSidebarView()
                            .environment(store)
                            .environment(router)
                            .environment(commandCenter)
                            .environment(PackOrderStore.shared)
                    } else {
                        OnboardingView()
                            .environment(store)
                    }
                } else if let bootError {
                    ContentUnavailableView(
                        AppL10n.t("boot.openFailed"),
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(bootError)
                    )
                    .padding(24)
                    .frame(maxWidth: 560)
                } else {
                    ProgressView(AppL10n.t("boot.opening"))
                }
            }
            .frame(minWidth: 1020, minHeight: 680)
            .modifier(ThemeRootModifier(themeManager: themeManager))
            .task { await bootOnce() }
            .sheet(isPresented: $showShortcutsHelp) {
                ShortcutsHelpView()
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(AppL10n.t("sidebar.newCard")) {
                    router.destination = .newCard
                    MenuBarAgent.shared.showMainWindow()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .appSettings) {
                Button(AppL10n.t("quick.find")) {
                    commandCenter.openQuickFind()
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button(AppL10n.t("quick.action.review")) {
                    router.openStudy(.review)
                    MenuBarAgent.shared.showMainWindow()
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button(AppL10n.t("quick.action.reviewWindow")) {
                    commandCenter.openReviewWindow()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(after: .help) {
                Button(AppL10n.t("help.shortcuts")) {
                    showShortcutsHelp = true
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
            CommandGroup(after: .appInfo) {
                Button(AppL10n.t("help.global.readingMode")) {
                    ReadingModeController.shared.toggle()
                }
            }
        }

        WindowGroup(id: MelingoWindowID.review) {
            ReviewWindowRoot(themeManager: themeManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 640)

        Settings {
            Group {
                if let store {
                    SettingsView()
                        .environment(store)
                        .modifier(ThemeRootModifier(themeManager: themeManager))
                } else {
                    ProgressView()
                        .frame(minWidth: 320, minHeight: 200)
                }
            }
            .frame(minWidth: 640, minHeight: 480)
        }
    }

    @MainActor
    private func bootOnce() async {
        guard !didStartBoot else { return }
        didStartBoot = true
        do {
            let stack = try await Task.detached(priority: .userInitiated) {
                try DataKitStack.makePersistent()
            }.value
            let store = AppLibraryStore(stack: stack)
            await store.load()
            self.store = store
            MelingoServicesProvider.shared.store = store
            IINABridgeController.shared.store = store
            AppL10n.sync(from: store.profile)
            ReadingModeController.shared.languagePairProvider = { [weak store] in
                store?.profile.preferredLanguagePair ?? .init(source: "en", target: "en")
            }
            await ReviewReminderService.reschedule(dueCountHint: store.dueCount)
        } catch {
            bootError = error.localizedDescription
            didStartBoot = false
        }
    }
}

/// Menu-bar agent + reading-mode hotkey; keep running when the main window closes.
@MainActor
final class MelingoAppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarAgent.shared.install()
        ReadingModeController.shared.bootstrap()
        MelingoServicesProvider.shared.register()
        IINABridgeController.shared.bootstrap()
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
            // willClose fires before the window leaves NSApp.windows — defer the check.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MenuBarAgent.shared.resignToAccessoryIfNeeded()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MenuBarAgent.shared.showMainWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

/// Injects system tokens + accent tint; appearance follows macOS System Settings.
private struct ThemeRootModifier: ViewModifier {
    @Bindable var themeManager: ThemeManager
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let tokens = themeManager.tokens(for: systemScheme)
        content
            .environment(themeManager)
            .environment(\.theme, tokens)
            .tint(tokens.primary)
            .preferredColorScheme(nil)
    }
}
