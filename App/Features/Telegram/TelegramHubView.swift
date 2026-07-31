import SwiftUI
import TelegramKit

/// Melingo surface for signing in and opening a channel (same theme as the rest of the app).
struct TelegramHubView: View {
    @Environment(\.theme) private var theme
    @Environment(AppLibraryStore.self) private var store
    @Bindable private var controller = TelegramSession.shared
    @AppStorage(TelegramChannelLibraryImport.pendingUsernameKey) private var pendingUsername = ""

    var body: some View {
        HSplitView {
            controlPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
            detailPane
                .frame(minWidth: 480)
        }
        .background(theme.background)
        .navigationTitle("Telegram")
        .onAppear {
            if controller.channelUsername.isEmpty, !pendingUsername.isEmpty {
                controller.channelUsername = pendingUsername
            }
        }
        .task {
            await controller.ensureConnected()
        }
    }

    private var controlPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppL10n.t("telegram.hub.title"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                    Text(AppL10n.t("telegram.hub.subtitle"))
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.showSetup || controller.needsSetup {
                    setupCard
                }

                authCard

                if controller.client.isReady {
                    openChannelCard
                }

                otherMacCard

                if !controller.progressText.isEmpty {
                    Text(controller.progressText)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .textSelection(.enabled)
                }
                if let sync = controller.lastSyncMessage {
                    Text(sync)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.client.isReady ? Color.green.opacity(0.85) : theme.mutedForeground.opacity(0.45))
                        .frame(width: 7, height: 7)
                    Text(controller.localizedStatus(for: controller.client.phase))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                    Spacer()
                    if !controller.showSetup, TelegramCredentialStore.load() != nil {
                        Button(AppL10n.t("telegram.hub.setupButton")) { controller.showSetup = true }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
            }
            .padding(20)
        }
        .background(theme.background)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppL10n.t("telegram.hub.setup"))
                .font(.headline)
                .foregroundStyle(theme.foreground)
            Text(AppL10n.t("telegram.hub.setupHelp"))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            TelegramAppsHelp.OpenLinkButton()
            calmField(AppL10n.t("import.telegram.apiId"), text: $controller.apiIdText)
            calmField(AppL10n.t("import.telegram.apiHash"), text: $controller.apiHashText)
            Button(AppL10n.t("telegram.hub.save")) {
                Task { await controller.startClient() }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(controller.apiIdText.isEmpty || controller.apiHashText.isEmpty || controller.isBusy)
        }
        .melingoCard(theme: theme)
    }

    @ViewBuilder
    private var authCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.client.phase {
            case .waitPhoneNumber, .idle, .waitCredentials, .closed:
                if !controller.needsSetup || !controller.showSetup {
                    Text(AppL10n.t("telegram.hub.signIn"))
                        .font(.headline)
                        .foregroundStyle(theme.foreground)
                    calmField(AppL10n.t("telegram.hub.phone"), text: $controller.phone)
                    HStack {
                        Button(AppL10n.t("telegram.hub.continue")) { Task { await controller.startThenPhone() } }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.primary)
                            .disabled(controller.phone.isEmpty || controller.isBusy)
                    }
                }
            case .waitCode:
                Text(AppL10n.t("telegram.hub.verification"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                Text(AppL10n.t("telegram.hub.codeSent"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                calmField(AppL10n.t("telegram.hub.code"), text: $controller.code)
                Button(AppL10n.t("telegram.hub.confirm")) { Task { await controller.submitCode() } }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .disabled(controller.code.isEmpty || controller.isBusy)
            case .waitPassword:
                Text(AppL10n.t("telegram.hub.password"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                SecureField(AppL10n.t("telegram.hub.passwordField"), text: $controller.password)
                    .textFieldStyle(.roundedBorder)
                Button(AppL10n.t("telegram.hub.confirm")) { Task { await controller.submitPassword() } }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .disabled(controller.password.isEmpty || controller.isBusy)
            case .ready:
                Label(AppL10n.t("telegram.hub.signedIn"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.primary)
                    .font(.callout.weight(.medium))
            case .waitRegistration:
                Text(AppL10n.t("telegram.hub.needRegistration"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
            case .error:
                Text(controller.friendlyMessage(controller.client.lastError))
                    .font(.callout)
                    .foregroundStyle(theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.needsSetup || controller.showSetup {
                    TelegramAppsHelp.OpenLinkButton()
                }
            }
        }
    }

    private var openChannelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppL10n.t("telegram.hub.openChannel"))
                .font(.headline)
                .foregroundStyle(theme.foreground)
            calmField(AppL10n.t("telegram.hub.username"), text: $controller.channelUsername)
            Button {
                Task { await openChannelAndSave() }
            } label: {
                Label(
                    controller.isBusy ? AppL10n.t("telegram.hub.loading") : AppL10n.t("telegram.hub.openAdd"),
                    systemImage: "arrow.down.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(
                controller.isBusy
                    || controller.channelUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .melingoCard(theme: theme)
    }

    private var otherMacCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppL10n.t("telegram.hub.otherMacHelp"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                calmField(AppL10n.t("telegram.hub.sharedName"), text: $controller.sessionKey)
                HStack {
                    Button(AppL10n.t("telegram.hub.saveLogin")) { Task { await controller.pushSession() } }
                    Button(AppL10n.t("telegram.hub.restoreLogin")) { Task { await controller.pullSession() } }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(AppL10n.t("telegram.hub.otherMac"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.foreground)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let doc = controller.exportDocument {
            TelegramInteractiveChannelView(document: doc, mediaRoot: controller.exportDirectory)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(theme.mutedForeground)
                Text(AppL10n.t("telegram.hub.emptyTitle"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                Text(AppL10n.t("telegram.hub.emptyBody"))
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
        }
    }

    private func calmField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private extension TelegramHubView {
    func openChannelAndSave() async {
        pendingUsername = ""
        do {
            _ = try await TelegramChannelLibraryImport.importChannel(
                username: controller.channelUsername,
                store: store,
                controller: controller
            )
        } catch {
            // Progress / errors surface via controller.progressText
        }
    }
}

private extension View {
    func melingoCard(theme: ThemeTokens) -> some View {
        self
            .padding(14)
            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
            }
    }
}
