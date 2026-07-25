import SwiftUI

/// Standalone Review window — uses the shared store from Services (same DB as main window).
/// HiddenTitleBar focus surface: no workspace chrome, just the session.
struct ReviewWindowRoot: View {
    @Bindable var themeManager: ThemeManager
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Group {
            if let store = MelingoServicesProvider.shared.store {
                ReviewSessionView(presentsAsNavigation: false)
                    .environment(store)
            } else {
                ProgressView(AppL10n.t("boot.opening"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(themeManager.tokens(for: systemScheme).background)
        .environment(themeManager)
        .environment(\.theme, themeManager.tokens(for: systemScheme))
        .tint(themeManager.tokens(for: systemScheme).primary)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
