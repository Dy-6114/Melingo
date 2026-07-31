import SwiftUI

/// Shared copy + link for first-time Telegram developer keys.
enum TelegramAppsHelp {
    static let appsURL = URL(string: "https://my.telegram.org/apps")!

    /// Button that opens Telegram’s apps page in the browser.
    struct OpenLinkButton: View {
        @Environment(\.theme) private var theme
        @Environment(\.openURL) private var openURL

        var body: some View {
            Button {
                openURL(appsURL)
            } label: {
                Label(AppL10n.t("import.telegram.openApps"), systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(theme.primary)
            .help(AppL10n.t("import.telegram.openApps.help"))
            .accessibilityHint(AppL10n.t("import.telegram.openApps.help"))
        }
    }
}
