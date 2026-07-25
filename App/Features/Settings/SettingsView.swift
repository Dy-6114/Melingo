import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Domain
import DataKit
import AIKit
import MLXAdapter

/// Categorized Settings (HIG): tab groups so Profile / Appearance / Languages / AI stay clear.
struct SettingsView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    private enum Category: String, CaseIterable, Identifiable {
        case general, appearance, languages, appleIntelligence, mlx, remote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: AppL10n.t("settings.cat.general")
            case .appearance: AppL10n.t("settings.cat.appearance")
            case .languages: AppL10n.t("settings.cat.languages")
            case .appleIntelligence: AppL10n.t("settings.cat.apple")
            case .mlx: AppL10n.t("settings.cat.mlx")
            case .remote: AppL10n.t("settings.cat.remote")
            }
        }
        var symbol: String {
            switch self {
            case .general: "person.crop.circle"
            case .appearance: "paintpalette"
            case .languages: "globe"
            case .appleIntelligence: "sparkles"
            case .mlx: "cpu"
            case .remote: "cloud"
            }
        }
    }

    @State private var category: Category = .general
    @State private var apiKey = ""
    @State private var sourceLang = ""
    @State private var targetLang = ""
    @State private var displayName = ""
    @State private var status = ""
    @State private var mlxModelID = ""
    @State private var mlxDownloadProgress: MLXModelDownloader.Progress?
    @State private var selectedRemoteProvider: RemoteProviderID = .openAICompatible
    @State private var hardware = MacHardwareProfile.current()
    @State private var confirmRestore = false
    @State private var remindersOn = ReviewReminderService.isEnabled

    var body: some View {
        HSplitView {
            categoryList
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)
            detailPane
                .frame(minWidth: 400)
        }
        .background(theme.background)
        .navigationTitle(AppL10n.t("sidebar.settings"))
        .onAppear { hydrate() }
    }

    private var categoryList: some View {
        List(selection: $category) {
            Section(AppL10n.t("settings.cat.general")) {
                ForEach([Category.general, .appearance, .languages]) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            Section(AppL10n.t("settings.cat.apple")) {
                ForEach([Category.appleIntelligence, .mlx, .remote]) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.background)
    }

    @ViewBuilder
    private var detailPane: some View {
        Form {
            switch category {
            case .general: generalSections
            case .appearance: appearanceSections
            case .languages: languagesSections
            case .appleIntelligence: appleSections
            case .mlx: mlxSections
            case .remote: remoteSections
            }
            if !status.isEmpty {
                Section {
                    Text(status).foregroundStyle(theme.mutedForeground)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .padding()
    }

    // MARK: - General

    @ViewBuilder
    private var generalSections: some View {
        Section {
            HStack(spacing: 16) {
                avatarThumb
                VStack(alignment: .leading, spacing: 8) {
                    TextField(AppL10n.t("settings.displayName"), text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(theme.foreground)
                    HStack {
                        Button(AppL10n.t("settings.choosePhoto")) { pickAvatar() }
                        Button(AppL10n.t("settings.saveName")) { Task { await saveDisplayName() } }
                    }
                }
            }
        } header: {
            Text(AppL10n.t("settings.profile"))
        } footer: {
            if !OnboardingPrefs.localizedLearningGoal.isEmpty {
                Text("\(AppL10n.t("settings.learningGoal")): \(OnboardingPrefs.localizedLearningGoal)")
            }
        }

        Section {
            Picker(AppL10n.t("settings.cefr"), selection: Binding(
                get: { StudyLearnerPrefs.learnerCEFR },
                set: { StudyLearnerPrefs.learnerCEFR = $0 }
            )) {
                ForEach(StudyLearnerPrefs.cefrLevels, id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            Toggle(AppL10n.t("settings.ignoreAccents"), isOn: Binding(
                get: { StudyLearnerPrefs.ignoreAccents },
                set: { StudyLearnerPrefs.ignoreAccents = $0 }
            ))
            Picker(AppL10n.t("settings.reviewDirection"), selection: Binding(
                get: { StudyLearnerPrefs.reviewDirection },
                set: { StudyLearnerPrefs.reviewDirection = $0 }
            )) {
                Text(AppL10n.t("settings.reviewDirection.mix")).tag(StudyLearnerPrefs.ReviewDirection.mix)
                Text(AppL10n.t("settings.reviewDirection.recognition")).tag(StudyLearnerPrefs.ReviewDirection.recognition)
                Text(AppL10n.t("settings.reviewDirection.production")).tag(StudyLearnerPrefs.ReviewDirection.production)
            }
        } header: {
            Text(AppL10n.t("settings.studyLevel"))
        } footer: {
            Text(AppL10n.t("settings.studyLevel.footer"))
        }

        Section {
            HStack {
                Text(AppL10n.t("settings.srs.retention"))
                Spacer()
                Text(String(format: "%.0f%%", SRSPrefs.desiredRetention * 100))
                    .foregroundStyle(theme.mutedForeground)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { SRSPrefs.desiredRetention },
                    set: { SRSPrefs.desiredRetention = $0 }
                ),
                in: 0.70...0.97,
                step: 0.01
            )
            Stepper(
                value: Binding(
                    get: { SRSPrefs.dailyNewLimit },
                    set: { SRSPrefs.dailyNewLimit = $0 }
                ),
                in: 1...100
            ) {
                Text(String(format: AppL10n.t("settings.srs.newLimit"), SRSPrefs.dailyNewLimit))
            }
            Stepper(
                value: Binding(
                    get: { SRSPrefs.dailyReviewLimit },
                    set: { SRSPrefs.dailyReviewLimit = $0 }
                ),
                in: 10...500,
                step: 10
            ) {
                Text(String(format: AppL10n.t("settings.srs.reviewLimit"), SRSPrefs.dailyReviewLimit))
            }
        } header: {
            Text(AppL10n.t("settings.srs"))
        } footer: {
            Text(AppL10n.t("settings.srs.footer"))
        }

        Section {
            Toggle(AppL10n.t("settings.reminders.toggle"), isOn: $remindersOn)
                .onChange(of: remindersOn) { _, enabled in
                    Task {
                        if enabled {
                            let ok = await ReviewReminderService.enable(dueCountHint: store.dueCount)
                            if !ok { remindersOn = false }
                        } else {
                            await ReviewReminderService.disable()
                        }
                    }
                }
        } header: {
            Text(AppL10n.t("settings.reminders"))
        } footer: {
            Text(AppL10n.t("settings.reminders.footer"))
        }

        Section {
            LabeledContent(AppL10n.t("settings.version")) {
                Text(Self.appVersionLabel)
                    .foregroundStyle(theme.mutedForeground)
                    .textSelection(.enabled)
            }
        } footer: {
            Text(AppL10n.t("settings.versionFooter"))
        }

        Section {
            Button(AppL10n.t("settings.backup.export")) {
                exportBackup()
            }
            Button(AppL10n.t("settings.backup.import")) {
                confirmRestore = true
            }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        } header: {
            Text(AppL10n.t("settings.backup"))
        } footer: {
            Text(AppL10n.t("settings.backup.footer"))
        }
        .confirmationDialog(
            AppL10n.t("settings.backup.importConfirm"),
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button(AppL10n.t("settings.backup.import"), role: .destructive) {
                importBackup()
            }
            Button(AppL10n.t("study.exitConfirm.stay"), role: .cancel) {}
        }

        Section {
            LabeledContent(AppL10n.t("settings.accessibility.status")) {
                Text(
                    AccessibilityPermission.isTrusted
                        ? AppL10n.t("settings.accessibility.granted")
                        : AppL10n.t("settings.accessibility.needed")
                )
                .foregroundStyle(
                    AccessibilityPermission.isTrusted ? theme.mutedForeground : theme.primary
                )
            }
            if !AccessibilityPermission.isTrusted {
                Button(AppL10n.t("settings.accessibility.open")) {
                    AccessibilityPermission.requestIfNeeded()
                    AccessibilityPermission.openSystemSettings()
                }
            }
            Button(AppL10n.t("settings.readingMode.toggle")) {
                ReadingModeController.shared.toggle()
            }
        } header: {
            Text(AppL10n.t("settings.readingMode"))
        } footer: {
            Text(AppL10n.t("settings.readingMode.footer"))
        }

        Section(AppL10n.t("settings.aiRouting")) {
            Picker(AppL10n.t("settings.preferredProvider"), selection: Binding(
                get: { store.profile.preferredAIProvider },
                set: { id in
                    Task {
                        var profile = store.profile
                        profile.activeAIProviderID = id.rawValue
                        if id == .remote {
                            profile.remoteAIEnabled = true
                            var settings = store.remoteSettings
                            settings.enabled = true
                            store.remoteSettings = settings
                        }
                        await store.saveProfile(profile)
                        status = "Provider: \(id.displayName)"
                    }
                }
            )) {
                ForEach(AIProviderID.allCases) { id in
                    Text(id.displayName).tag(id)
                }
            }
            Picker(AppL10n.t("settings.fallback"), selection: Binding(
                get: { store.profile.aiFallbackMode },
                set: { mode in
                    Task {
                        var profile = store.profile
                        profile.aiFallbackMode = mode
                        await store.saveProfile(profile)
                    }
                }
            )) {
                ForEach(AIFallbackMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    private var avatarThumb: some View {
        Group {
            if let url = store.absoluteAvatarURL(), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    theme.muted
                    Image(systemName: "person.fill").foregroundStyle(theme.mutedForeground)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(theme.border, lineWidth: 1) }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSections: some View {
        Section {
            LabeledContent(AppL10n.t("settings.appearanceMode")) {
                Text(AppL10n.t("settings.followsSystem"))
                    .foregroundStyle(theme.mutedForeground)
            }
            LabeledContent(AppL10n.t("settings.accentColor")) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.primary)
                        .frame(width: 14, height: 14)
                    Text(AppL10n.t("settings.systemAccent"))
                        .foregroundStyle(theme.mutedForeground)
                }
            }
        } header: {
            Text(AppL10n.t("settings.lookFeel"))
        } footer: {
            Text(AppL10n.t("settings.appearanceFooter"))
        }
    }

    // MARK: - Languages

    private var languagesSections: some View {
        Section("Language pair") {
            Picker("Content language", selection: $sourceLang) {
                ForEach(Self.languageOptions, id: \.code) { Text("\($0.name) (\($0.code))").tag($0.code) }
            }
            Picker("Explanation language", selection: $targetLang) {
                ForEach(Self.languageOptions, id: \.code) { Text("\($0.name) (\($0.code))").tag($0.code) }
            }
            Button("Save languages") {
                Task {
                    var profile = store.profile
                    profile.preferredLanguagePair = LanguagePair(source: sourceLang, target: targetLang)
                    await store.saveProfile(profile)
                    status = "Languages saved."
                }
            }
            .tint(theme.primary)
        }
    }

    private static let languageOptions: [(code: String, name: String)] = [
        ("ja", "Japanese"), ("en", "English"), ("zh", "Chinese"), ("ko", "Korean"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ru", "Russian"), ("vi", "Vietnamese"), ("th", "Thai"),
    ]

    // MARK: - Apple Intelligence

    private var appleSections: some View {
        Section {
            LabeledContent("Status") {
                Text(FoundationModelsProvider.availabilityDescription)
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.trailing)
            }
            Button("Use as preferred provider") {
                Task {
                    var profile = store.profile
                    profile.activeAIProviderID = AIProviderID.foundationModels.rawValue
                    await store.saveProfile(profile)
                    status = "Preferred: Apple Intelligence"
                }
            }
        } header: {
            Text("On-device")
        } footer: {
            Text("Foundation Models on macOS 26+. No API key. Never fabricates answers when unavailable.")
        }
    }

    // MARK: - MLX

    private var mlxSections: some View {
        Section {
            Text("\(hardware.chipName) · \(hardware.totalMemoryGB) GB")
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)

            ForEach(GemmaModelCatalog.models(for: hardware), id: \.model.id) { row in
                Button {
                    guard mlxDownloadProgress == nil else { return }
                    mlxModelID = row.model.huggingFaceID
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.model.displayName).font(.body.weight(.medium))
                                if row.recommended {
                                    Text("Recommended")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(theme.primary)
                                }
                            }
                            Text(row.model.blurb).font(.caption).foregroundStyle(theme.mutedForeground)
                        }
                        Spacer()
                        if mlxModelID == row.model.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!row.fits || mlxDownloadProgress != nil)
                .opacity(row.fits && mlxDownloadProgress == nil ? 1 : 0.45)
            }

            TextField("Or Hugging Face model id", text: $mlxModelID)
                .textFieldStyle(.roundedBorder)
                .disabled(mlxDownloadProgress != nil)
            if let progress = mlxDownloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text("\(Int((progress.fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(theme.primary)
                        if !progress.detail.isEmpty {
                            Text(progress.detail)
                                .font(.caption)
                                .foregroundStyle(theme.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                }
            }
            let cfg = MLXConfigStorage.load()
            let mlxProvider = MLXProvider()
            if cfg.isConfigured || mlxProvider.hasDownloadedWeights {
                if cfg.isConfigured {
                    Text("Downloaded: \(cfg.modelID)")
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
                if mlxProvider.hasDownloadedWeights, !mlxProvider.isReady {
                    Text(AppL10n.t("settings.mlx.engineMissing"))
                        .font(.caption)
                        .foregroundStyle(theme.destructive)
                }
                Button("Remove downloaded model", role: .destructive) {
                    _ = MLXProvider().clearModel(deleteFiles: true)
                    mlxModelID = ""
                    status = "MLX model removed. You can download again."
                }
            }
            Button("Download model") { Task { await downloadMLX() } }
                .disabled(mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || mlxDownloadProgress != nil)
            Button("Use MLX as preferred") {
                Task {
                    var profile = store.profile
                    profile.activeAIProviderID = AIProviderID.mlx.rawValue
                    await store.saveProfile(profile)
                    status = "Preferred: MLX"
                }
            }
        } header: {
            Text("Gemma / MLX")
        } footer: {
            Text("Weights download into Documents/Melingo/Models. Nothing is bundled.")
        }
    }

    // MARK: - Remote

    private var remoteSections: some View {
        Section {
            Toggle("Enable remote AI", isOn: Binding(
                get: { store.profile.remoteAIEnabled },
                set: { enabled in
                    Task {
                        var profile = store.profile
                        profile.remoteAIEnabled = enabled
                        if enabled { profile.activeAIProviderID = AIProviderID.remote.rawValue }
                        await store.saveProfile(profile)
                        var settings = store.remoteSettings
                        settings.enabled = enabled
                        if settings.configs.isEmpty {
                            settings.configs = [
                                ModelConfig(
                                    name: "Default",
                                    apiProvider: selectedRemoteProvider,
                                    model: "gpt-4o-mini",
                                    isDefault: true
                                )
                            ]
                        }
                        store.remoteSettings = settings
                    }
                }
            ))
            .tint(theme.primary)

            Picker("Vendor", selection: $selectedRemoteProvider) {
                ForEach(ProviderCapability.all) { cap in
                    Text(cap.displayName).tag(cap.providerID)
                }
            }
            .onChange(of: selectedRemoteProvider) { _, newValue in
                updateDefaultConfig { cfg in
                    cfg.apiProvider = newValue
                    if let endpoint = ProviderCapability.capability(for: newValue).defaultEndpoint {
                        cfg.baseURL = endpoint.absoluteString
                            .replacingOccurrences(of: "/chat/completions", with: "")
                            .replacingOccurrences(of: "/v1/messages", with: "")
                    }
                }
            }

            TextField("Display name", text: Binding(
                get: { store.remoteSettings.defaultConfig?.name ?? "" },
                set: { name in updateDefaultConfig { $0.name = name } }
            ))
            TextField("Model", text: Binding(
                get: { store.remoteSettings.defaultConfig?.model ?? "" },
                set: { model in updateDefaultConfig { $0.model = model } }
            ))
            TextField("Base URL", text: Binding(
                get: { store.remoteSettings.defaultConfig?.baseURL ?? "" },
                set: { url in updateDefaultConfig { $0.baseURL = url.isEmpty ? nil : url } }
            ))
            SecureField("API Key (Keychain)", text: $apiKey)
            Button("Save API Key") {
                guard let id = store.remoteSettings.defaultConfig?.id else {
                    status = "Add a remote model first."
                    return
                }
                do {
                    let account = APIKeyStore.account(for: id)
                    if apiKey.isEmpty {
                        APIKeyStore.clear(account: account)
                        status = "API key cleared."
                    } else {
                        try APIKeyStore.save(apiKey, account: account)
                        status = "API key saved to Keychain."
                        apiKey = ""
                    }
                } catch {
                    status = error.localizedDescription
                }
            }
            if let privacy = ProviderCapability.capability(for: selectedRemoteProvider).privacyPolicyURL {
                Link("Privacy policy", destination: privacy)
            }
        } header: {
            Text("Cloud providers")
        } footer: {
            Text("Off by default. Content leaves the device when enabled.")
        }
    }

    // MARK: - Helpers

    private func hydrate() {
        sourceLang = store.profile.preferredLanguagePair.source
        targetLang = store.profile.preferredLanguagePair.target
        displayName = store.profile.displayName ?? ""
        mlxModelID = MLXConfigStorage.load().modelID
        if mlxModelID.isEmpty {
            mlxModelID = GemmaModelCatalog.recommended(for: hardware).huggingFaceID
        }
        if let cfg = store.remoteSettings.defaultConfig {
            selectedRemoteProvider = cfg.apiProvider
        }
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.title = "Choose Profile Photo"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        Task {
            await store.saveAvatarImage(data)
            status = "Photo updated."
        }
    }

    private func saveDisplayName() async {
        var profile = store.profile
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.displayName = trimmed.isEmpty ? nil : trimmed
        await store.saveProfile(profile)
        status = "Name saved."
    }

    private func updateDefaultConfig(_ mutate: (inout ModelConfig) -> Void) {
        var settings = store.remoteSettings
        if settings.configs.isEmpty {
            settings.configs = [
                ModelConfig(
                    name: "Default",
                    apiProvider: selectedRemoteProvider,
                    model: "gpt-4o-mini",
                    isDefault: true
                )
            ]
        }
        guard var cfg = settings.defaultConfig,
              let idx = settings.configs.firstIndex(where: { $0.id == cfg.id })
        else { return }
        mutate(&cfg)
        settings.configs[idx] = cfg
        store.remoteSettings = settings
    }

    private func downloadMLX() async {
        mlxDownloadProgress = MLXModelDownloader.Progress(fraction: 0, detail: "Starting…")
        defer { mlxDownloadProgress = nil }
        do {
            _ = try await MLXModelDownloader.download(modelID: mlxModelID) { progress in
                Task { @MainActor in mlxDownloadProgress = progress }
            }
            status = "MLX model downloaded."
        } catch {
            status = error.localizedDescription
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = AppL10n.t("settings.backup.export")
        panel.nameFieldStringValue = "Melingo-backup.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MelingoBackupService.exportZIP(to: url, appVersion: Self.appVersionLabel)
            status = AppL10n.t("settings.backup.exportOK")
        } catch {
            status = error.localizedDescription
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = AppL10n.t("settings.backup.import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MelingoBackupService.importZIP(from: url)
            status = AppL10n.t("settings.backup.importOK")
        } catch {
            status = error.localizedDescription
        }
    }

    private static var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
