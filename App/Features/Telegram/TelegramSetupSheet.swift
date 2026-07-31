import SwiftUI
import TelegramKit

/// Lightweight Telegram sign-in sheet — shared session via api_id / api_hash.
struct TelegramSetupSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable private var controller = TelegramSession.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppL10n.t("import.telegram.setupTitle"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                Spacer()
                Button(AppL10n.t("common.done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AppL10n.t("import.telegram.setupHelp"))
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)

                    if controller.showSetup || controller.needsSetup || !controller.client.isReady {
                        setupCard
                    }
                    authCard

                    if !controller.progressText.isEmpty {
                        Text(controller.progressText)
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
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
                        Text(localizedPhase(controller.client.phase))
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 420, height: 560)
        .background(theme.background)
        .task {
            // Resume saved login automatically — no extra tap.
            await controller.ensureConnected()
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppL10n.t("import.telegram.keys"))
                .font(.headline)
                .foregroundStyle(theme.foreground)
            Text(AppL10n.t("import.telegram.keysHelp"))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            TelegramAppsHelp.OpenLinkButton()
            field(AppL10n.t("import.telegram.apiId"), text: $controller.apiIdText)
            field(AppL10n.t("import.telegram.apiHash"), text: $controller.apiHashText)
            Button(AppL10n.t("import.telegram.saveKeys")) {
                Task { await controller.saveCredentialsAndStart() }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(
                controller.isBusy
                    || controller.apiIdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || controller.apiHashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
    }

    @ViewBuilder
    private var authCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.client.phase {
            case .waitPhoneNumber, .idle, .waitCredentials, .closed:
                Text(AppL10n.t("import.telegram.phone"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                field(AppL10n.t("import.telegram.phone.placeholder"), text: $controller.phone)
                Button(AppL10n.t("import.telegram.sendCode")) {
                    Task { await controller.startThenPhone() }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(controller.phone.isEmpty || controller.isBusy || controller.needsSetup)
            case .waitCode:
                Text(AppL10n.t("import.telegram.code"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                field(AppL10n.t("import.telegram.code"), text: $controller.code)
                Button(AppL10n.t("import.telegram.confirm")) {
                    Task { await controller.submitCode() }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(controller.code.isEmpty || controller.isBusy)
            case .waitPassword:
                Text(AppL10n.t("import.telegram.password"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                SecureField(AppL10n.t("import.telegram.password"), text: $controller.password)
                    .textFieldStyle(.roundedBorder)
                Button(AppL10n.t("import.telegram.confirm")) {
                    Task { await controller.submitPassword() }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(controller.password.isEmpty || controller.isBusy)
            case .ready:
                Label(AppL10n.t("import.telegram.signedIn"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.primary)
                    .font(.callout.weight(.medium))
                Button(AppL10n.t("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
            case .waitRegistration:
                Text(AppL10n.t("import.telegram.needRegistration"))
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
                Button(AppL10n.t("import.telegram.saveKeys")) {
                    Task { await controller.saveCredentialsAndStart() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func localizedPhase(_ phase: TelegramAuthPhase) -> String {
        switch phase {
        case .idle, .waitCredentials: return AppL10n.t("import.telegram.phase.setup")
        case .waitPhoneNumber: return AppL10n.t("import.telegram.phase.phone")
        case .waitCode: return AppL10n.t("import.telegram.phase.code")
        case .waitPassword: return AppL10n.t("import.telegram.phase.password")
        case .waitRegistration: return AppL10n.t("import.telegram.phase.registration")
        case .ready: return AppL10n.t("import.telegram.phase.ready")
        case .closed: return AppL10n.t("import.telegram.phase.closed")
        case .error: return AppL10n.t("import.telegram.phase.error")
        }
    }
}
