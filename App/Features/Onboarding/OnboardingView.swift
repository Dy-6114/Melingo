import SwiftUI
import AppKit
import Domain
import AIKit
import MLXAdapter
import UniformTypeIdentifiers

/// First-launch wizard aligned with macOS HIG: short steps, clear primary action,
/// optional skips, and locked controls while a model download is in flight.
struct OnboardingView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    private enum Step: Int, CaseIterable {
        case welcome, profile, languages, intelligence, remoteAPI, goals, tips
    }

    /// On-device strategy chosen on the intelligence step.
    private enum IntelligenceChoice: String {
        case apple
        case smartMix
        case mlx
    }

    @State private var step: Step = .welcome
    @State private var learningLanguage = "ja"
    @State private var nativeLanguage = "en"
    @State private var displayName = ""
    @State private var avatarData: Data?
    @State private var avatarImage: NSImage?
    @State private var intelligenceChoice: IntelligenceChoice = .apple
    @State private var selectedModelID = ""
    @State private var downloadProgress: Double?
    @State private var downloadNote: String?
    @State private var downloadedModelID: String?
    @State private var goalPreset = "media"
    @State private var customGoal = ""
    @State private var tipIndex = 0
    @State private var isSaving = false
    @State private var hardware = MacHardwareProfile.current()
    /// Forces view refresh when UI locale changes mid-wizard.
    @State private var localeTick = 0

    // Optional remote API (registration / Keychain)
    @State private var enableRemoteAPI = false
    @State private var remoteProvider: RemoteProviderID = .openai
    @State private var remoteModel = "gpt-4o-mini"
    @State private var remoteAPIKey = ""

    private var isDownloading: Bool { downloadProgress != nil }
    private var appleAvailable: Bool { FoundationModelsProvider.isAvailable }
    private var mlxReady: Bool {
        downloadedModelID != nil || MLXConfigStorage.load().isConfigured
    }

    private static let languageCodes = [
        "ja", "en", "zh", "ko", "es", "fr", "de", "it", "pt", "ru", "vi", "th",
    ]

    private static func languageName(for code: String) -> String {
        let locale = Locale(identifier: AppL10n.code)
        return locale.localizedString(forLanguageCode: code)
            ?? Locale(identifier: "en").localizedString(forLanguageCode: code)
            ?? code
    }

    private var tips: [(symbol: String, titleKey: String, bodyKey: String)] {
        [
            ("books.vertical", "onboarding.tip.import.title", "onboarding.tip.import.body"),
            ("character.textbox", "onboarding.tip.tap.title", "onboarding.tip.tap.body"),
            ("magnifyingglass", "onboarding.tip.quickFind.title", "onboarding.tip.quickFind.body"),
            ("rectangle.stack", "onboarding.tip.smartReview.title", "onboarding.tip.smartReview.body"),
            ("brain", "onboarding.tip.privacy.title", "onboarding.tip.privacy.body"),
        ]
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            LinearGradient(
                colors: [
                    theme.primary.opacity(0.06),
                    theme.muted.opacity(0.35),
                    theme.background.opacity(0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                progressHeader
                ScrollView {
                    stepContent
                        .padding(.horizontal, DesignTokens.Spacing.xl)
                        .padding(.vertical, DesignTokens.Spacing.lg)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .id(localeTick)
                        .animation(DesignTokens.Animation.snappy, value: step)
                        .animation(DesignTokens.Animation.snappy, value: tipIndex)
                }
                footerBar
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .onAppear(perform: bootstrap)
        .onChange(of: nativeLanguage) { _, newValue in
            applyUILocale(newValue)
        }
    }

    // MARK: - Chrome

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text("Melingo")
                    .font(DesignTokens.Typography.subheading)
                    .foregroundStyle(theme.foreground)
                Spacer()
                Text(stepLabel)
                    .font(DesignTokens.Typography.captionMedium)
                    .foregroundStyle(theme.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.muted.opacity(0.55), in: Capsule())
                    .accessibilityLabel(
                        String(
                            format: AppL10n.t("onboarding.stepA11y"),
                            step.rawValue + 1,
                            Step.allCases.count
                        )
                    )
            }
            WorkspaceChrome.ProgressBar(progress: progress)
                .accessibilityValue("\(Int(progress * 100)) percent")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .background(theme.card.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(height: 1)
        }
    }

    private var stepLabel: String {
        switch step {
        case .welcome: AppL10n.t("onboarding.step.welcome")
        case .profile: AppL10n.t("onboarding.step.profile")
        case .languages: AppL10n.t("onboarding.step.languages")
        case .intelligence: AppL10n.t("onboarding.step.intelligence")
        case .remoteAPI: AppL10n.t("onboarding.step.remoteAPI")
        case .goals: AppL10n.t("onboarding.step.goals")
        case .tips: AppL10n.t("onboarding.step.tips")
        }
    }

    private var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    private var footerBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if step != .welcome {
                Button(AppL10n.t("onboarding.back")) { goBack() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDownloading || isSaving)
            }
            if canSkipCurrent {
                Button(AppL10n.t("onboarding.skip")) { Task { await skipCurrent() } }
                    .disabled(isDownloading || isSaving)
            }
            Spacer()
            Button {
                Task { await goForward() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else if isDownloading {
                    Text(AppL10n.t("onboarding.downloading"))
                } else {
                    Text(primaryButtonTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .controlSize(.large)
            .disabled(!canAdvance || isSaving || isDownloading)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(theme.card.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border.opacity(0.55))
                .frame(height: 1)
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .tips:
            tipIndex < tips.count - 1
                ? AppL10n.t("onboarding.nextTip")
                : AppL10n.t("onboarding.getStarted")
        case .remoteAPI where !enableRemoteAPI:
            AppL10n.t("onboarding.continueNoAPI")
        default:
            AppL10n.t("onboarding.continue")
        }
    }

    private var canSkipCurrent: Bool {
        switch step {
        case .profile, .remoteAPI: true
        case .intelligence where appleAvailable || mlxReady: true
        default: false
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome, .profile, .tips:
            return true
        case .languages:
            return learningLanguage != nativeLanguage
        case .intelligence:
            switch intelligenceChoice {
            case .apple, .smartMix:
                return appleAvailable
            case .mlx:
                return !selectedModelID.isEmpty
            }
        case .remoteAPI:
            guard enableRemoteAPI else { return true }
            let keyOK = !remoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ProviderCapability.capability(for: remoteProvider).allowsEmptyKey
            let modelOK = !remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return keyOK && modelOK
        case .goals:
            if goalPreset != "custom" { return true }
            return !customGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .profile: profileStep
        case .languages: languagesStep
        case .intelligence: intelligenceStep
        case .remoteAPI: remoteAPIStep
        case .goals: goalsStep
        case .tips: tipsStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Melingo")
                    .font(DesignTokens.Typography.hero)
                    .foregroundStyle(theme.foreground)
                Text(AppL10n.t("onboarding.welcome.title"))
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(theme.foreground)
                Text(AppL10n.t("onboarding.welcome.body"))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                welcomeFeature(
                    symbol: "books.vertical",
                    title: AppL10n.t("onboarding.welcome.feature.read")
                )
                welcomeFeature(
                    symbol: "rectangle.stack",
                    title: AppL10n.t("onboarding.welcome.feature.cards")
                )
                welcomeFeature(
                    symbol: "lock.shield",
                    title: AppL10n.t("onboarding.welcome.feature.private")
                )
            }

            onboardingCard {
                languagePicker(AppL10n.t("onboarding.welcome.nativeLabel"), selection: $nativeLanguage)
            }

            tipCard(AppL10n.t("onboarding.welcome.tip"))
        }
    }

    private func welcomeFeature(symbol: String, title: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 40, height: 40)
                .background(theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            Text(title)
                .font(DesignTokens.Typography.captionMedium)
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepTitle(
                AppL10n.t("onboarding.profile.title"),
                subtitle: AppL10n.t("onboarding.profile.subtitle")
            )
            onboardingCard {
                HStack(spacing: DesignTokens.Spacing.md) {
                    avatarView
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        TextField(AppL10n.t("settings.displayName"), text: $displayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        Button(AppL10n.t("settings.choosePhoto")) { pickPhoto() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var languagesStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepTitle(
                AppL10n.t("onboarding.languages.title"),
                subtitle: String(
                    format: AppL10n.t("onboarding.languages.subtitle"),
                    Self.languageName(for: nativeLanguage)
                )
            )
            onboardingCard {
                languagePicker(AppL10n.t("onboarding.languages.learningLabel"), selection: $learningLanguage)
            }
            if learningLanguage == nativeLanguage {
                Label(AppL10n.t("onboarding.languages.mismatch"), systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.destructive)
            }
            tipCard(AppL10n.t("onboarding.languages.tip"))
        }
    }

    private var intelligenceStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepTitle(
                AppL10n.t("onboarding.ai.title"),
                subtitle: appleAvailable
                    ? AppL10n.t("onboarding.ai.subtitle.apple")
                    : AppL10n.t("onboarding.ai.subtitle.noApple")
            )

            hardwareBanner

            VStack(spacing: DesignTokens.Spacing.xs) {
                if appleAvailable {
                    providerChoice(
                        title: AppL10n.t("onboarding.ai.apple.title"),
                        detail: String(
                            format: AppL10n.t("onboarding.ai.apple.detail"),
                            FoundationModelsProvider.availabilityDescription
                        ),
                        symbol: "sparkles",
                        selected: intelligenceChoice == .apple,
                        enabled: !isDownloading
                    ) {
                        withAnimation(DesignTokens.Animation.snappy) { intelligenceChoice = .apple }
                    }

                    providerChoice(
                        title: AppL10n.t("onboarding.ai.smartMix.title"),
                        detail: AppL10n.t("onboarding.ai.smartMix.detail"),
                        symbol: "arrow.triangle.branch",
                        selected: intelligenceChoice == .smartMix,
                        enabled: !isDownloading
                    ) {
                        withAnimation(DesignTokens.Animation.snappy) { intelligenceChoice = .smartMix }
                    }
                }

                providerChoice(
                    title: AppL10n.t("onboarding.ai.mlx.title"),
                    detail: hardware.isAppleSilicon
                        ? AppL10n.t("onboarding.ai.mlx.detail")
                        : AppL10n.t("onboarding.ai.mlx.needsSilicon"),
                    symbol: "cpu",
                    selected: intelligenceChoice == .mlx,
                    enabled: hardware.isAppleSilicon && !isDownloading
                ) {
                    withAnimation(DesignTokens.Animation.snappy) { intelligenceChoice = .mlx }
                }
            }

            if intelligenceChoice == .mlx || intelligenceChoice == .smartMix {
                mlxModelList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let downloadNote {
                Text(downloadNote)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
                    .accessibilityLabel(downloadNote)
            }
            if let downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    WorkspaceChrome.ProgressBar(progress: downloadProgress)
                    Text(
                        String(
                            format: AppL10n.t("onboarding.ai.progressLocked"),
                            Int((downloadProgress * 100).rounded())
                        )
                    )
                    .font(DesignTokens.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.mutedForeground)
                }
            }
        }
    }

    private var remoteAPIStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepTitle(
                AppL10n.t("onboarding.remote.title"),
                subtitle: AppL10n.t("onboarding.remote.subtitle")
            )

            onboardingCard {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Toggle(isOn: $enableRemoteAPI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppL10n.t("onboarding.remote.enable"))
                            Text(AppL10n.t("onboarding.remote.enableDetail"))
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(theme.mutedForeground)
                        }
                    }
                    .tint(theme.primary)
                    .toggleStyle(.switch)

                    if enableRemoteAPI {
                        Picker(AppL10n.t("onboarding.remote.provider"), selection: $remoteProvider) {
                            ForEach(ProviderCapability.all.filter { !$0.isLocalProvider }) { cap in
                                Text(cap.displayName).tag(cap.providerID)
                            }
                        }
                        .pickerStyle(.menu)

                        TextField(AppL10n.t("onboarding.remote.model"), text: $remoteModel)
                            .textFieldStyle(.roundedBorder)

                        SecureField(AppL10n.t("onboarding.remote.apiKey"), text: $remoteAPIKey)
                            .textFieldStyle(.roundedBorder)

                        if let privacy = ProviderCapability.capability(for: remoteProvider).privacyPolicyURL {
                            Link(AppL10n.t("onboarding.remote.privacy"), destination: privacy)
                                .font(DesignTokens.Typography.caption)
                        }
                    }
                }
            }

            if enableRemoteAPI {
                tipCard(AppL10n.t("onboarding.remote.tip"))
            }
        }
        .animation(DesignTokens.Animation.snappy, value: enableRemoteAPI)
    }

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepTitle(
                AppL10n.t("onboarding.goals.title"),
                subtitle: AppL10n.t("onboarding.goals.subtitle")
            )
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignTokens.Spacing.sm) {
                ForEach(OnboardingPrefs.goalPresetIDs, id: \.id) { preset in
                    Button {
                        withAnimation(DesignTokens.Animation.snappy) { goalPreset = preset.id }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: preset.symbol)
                                .font(.title2)
                                .foregroundStyle(goalPreset == preset.id ? theme.primary : theme.mutedForeground)
                                .symbolRenderingMode(.hierarchical)
                            Text(OnboardingPrefs.goalTitle(for: preset.id))
                                .font(DesignTokens.Typography.bodyMedium)
                                .foregroundStyle(theme.foreground)
                                .multilineTextAlignment(.leading)
                            Text(OnboardingPrefs.goalDetail(for: preset.id))
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(theme.mutedForeground)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(DesignTokens.Spacing.sm)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                                .strokeBorder(
                                    goalPreset == preset.id ? theme.primary : theme.border.opacity(0.45),
                                    lineWidth: goalPreset == preset.id ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(goalPreset == preset.id ? 1.02 : 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: goalPreset)
                    .accessibilityAddTraits(goalPreset == preset.id ? .isSelected : [])
                }
            }
            if goalPreset == "custom" {
                TextField(AppL10n.t("onboarding.goals.customPlaceholder"), text: $customGoal, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var tipsStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepTitle(
                AppL10n.t("onboarding.tips.title"),
                subtitle: AppL10n.t("onboarding.tips.subtitle")
            )
            let tip = tips[tipIndex]
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: tip.symbol)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(theme.primary)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .background(theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                Text(AppL10n.t(tip.titleKey))
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(theme.foreground)
                Text(AppL10n.t(tip.bodyKey))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
            }
            .id(tipIndex)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                )
            )
            .accessibilityElement(children: .combine)

            HStack(spacing: 6) {
                ForEach(tips.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == tipIndex ? theme.primary : theme.muted)
                        .frame(width: i == tipIndex ? 18 : 7, height: 7)
                        .animation(DesignTokens.Animation.snappy, value: tipIndex)
                }
                Spacer()
                Text("\(tipIndex + 1) / \(tips.count)")
                    .font(DesignTokens.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    // MARK: - Pieces

    private var hardwareBanner: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: hardware.isAppleSilicon ? "laptopcomputer" : "xmark.octagon")
                .foregroundStyle(theme.primary)
                .frame(width: 28, height: 28)
                .background(theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(hardware.chipName)
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundStyle(theme.foreground)
                Text(String(format: AppL10n.t("onboarding.ai.memory"), hardware.totalMemoryGB))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
            Spacer()
        }
        .padding(DesignTokens.Spacing.sm)
        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
        }
    }

    private var mlxModelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppL10n.t("onboarding.ai.modelsHeader"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)

            if isDownloading {
                Label(AppL10n.t("onboarding.ai.locked"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }

            ForEach(GemmaModelCatalog.models(for: hardware), id: \.model.id) { row in
                let selected = selectedModelID == row.model.huggingFaceID
                let locked = isDownloading
                Button {
                    guard !locked else { return }
                    withAnimation(DesignTokens.Animation.snappy) { selectedModelID = row.model.huggingFaceID }
                } label: {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.fits ? theme.primary : theme.mutedForeground)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.model.displayName)
                                    .font(DesignTokens.Typography.bodyMedium)
                                    .foregroundStyle(theme.foreground)
                                if row.recommended {
                                    Text(AppL10n.t("onboarding.ai.recommended"))
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(theme.primary.opacity(0.15), in: Capsule())
                                        .foregroundStyle(theme.primary)
                                }
                                if downloadedModelID == row.model.huggingFaceID ||
                                    (MLXConfigStorage.load().modelID == row.model.huggingFaceID
                                     && MLXConfigStorage.load().isConfigured) {
                                    Text(AppL10n.t("onboarding.ai.downloaded"))
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(theme.srsStrong)
                                }
                                if !row.fits {
                                    Text(AppL10n.t("onboarding.ai.tightFit"))
                                        .font(.caption2)
                                        .foregroundStyle(theme.destructive)
                                }
                            }
                            Text(row.model.blurb)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(theme.mutedForeground)
                            Text(String(format: AppL10n.t("onboarding.ai.sizeNeeds"),
                                         row.model.approxDiskGB, row.model.minMemoryGB))
                                .font(.caption2)
                                .foregroundStyle(theme.mutedForeground)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(DesignTokens.Spacing.sm)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                            .strokeBorder(
                                selected ? theme.primary : theme.border.opacity(0.45),
                                lineWidth: selected ? 2 : 1
                            )
                    }
                    .opacity(row.fits && !locked ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!row.fits || locked)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            Button {
                Task { await downloadSelectedModel() }
            } label: {
                Label(
                    intelligenceChoice == .smartMix
                        ? AppL10n.t("onboarding.ai.downloadSmartMix")
                        : AppL10n.t("onboarding.ai.downloadSelected"),
                    systemImage: "arrow.down.circle"
                )
            }
            .buttonStyle(.bordered)
            .disabled(selectedModelID.isEmpty || isDownloading || !hardware.isAppleSilicon)

            if intelligenceChoice == .smartMix, !mlxReady, !isDownloading {
                Text(AppL10n.t("onboarding.ai.smartMixNote"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private var avatarView: some View {
        Group {
            if let avatarImage {
                Image(nsImage: avatarImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    theme.muted
                    Image(systemName: "person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.mutedForeground)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(theme.border, lineWidth: 1) }
        .accessibilityLabel(AppL10n.t("onboarding.profile.photoA11y"))
    }

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(theme.foreground)
            Text(subtitle)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tipCard(_ text: String) -> some View {
        Label(text, systemImage: "lightbulb")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(theme.mutedForeground)
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
            }
    }

    private func onboardingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
            }
    }

    private func languagePicker(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(DesignTokens.Typography.captionMedium)
                .foregroundStyle(theme.mutedForeground)
            Picker(label, selection: selection) {
                ForEach(Self.languageCodes, id: \.self) { code in
                    Text(Self.languageName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func providerChoice(
        title: String,
        detail: String,
        symbol: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(enabled ? theme.primary : theme.mutedForeground)
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(theme.primary)
                    .frame(width: 24)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundStyle(theme.foreground)
                    Text(detail)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? theme.primary : theme.border.opacity(0.45),
                        lineWidth: selected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || selected ? 1 : 0.45)
        .scaleEffect(selected ? 1.01 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Actions

    private func applyUILocale(_ code: String) {
        AppL10n.setCode(code)
        localeTick &+= 1
    }

    private func bootstrap() {
        nativeLanguage = AppL10n.defaultUILocale()
        applyUILocale(nativeLanguage)
        // Prefer a learning language different from native when possible.
        if learningLanguage == nativeLanguage {
            learningLanguage = nativeLanguage == "ja" ? "en" : "ja"
        }
        let rec = GemmaModelCatalog.recommended(for: hardware)
        selectedModelID = rec.huggingFaceID
        if appleAvailable {
            intelligenceChoice = .smartMix
        } else if hardware.isAppleSilicon {
            intelligenceChoice = .mlx
        } else {
            intelligenceChoice = .apple
        }
        if MLXConfigStorage.load().isConfigured {
            downloadedModelID = MLXConfigStorage.load().modelID
            selectedModelID = MLXConfigStorage.load().modelID
        }
    }

    private func goBack() {
        guard !isDownloading else { return }
        if step == .tips, tipIndex > 0 {
            withAnimation(.snappy) { tipIndex -= 1 }
            return
        }
        if let prev = Step(rawValue: step.rawValue - 1) {
            withAnimation(.snappy) { step = prev }
        }
    }

    private func skipCurrent() async {
        guard canSkipCurrent, !isDownloading else { return }
        if step == .remoteAPI {
            enableRemoteAPI = false
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation(.snappy) { step = next }
        }
    }

    private func goForward() async {
        guard !isDownloading else { return }
        if step == .tips {
            if tipIndex < tips.count - 1 {
                withAnimation(.snappy) { tipIndex += 1 }
                return
            }
            await finish()
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation(.snappy) { step = next }
        }
    }

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.title = AppL10n.t("onboarding.profile.photoPanel")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        avatarData = data
        avatarImage = NSImage(data: data)
    }

    private func downloadSelectedModel() async {
        guard !selectedModelID.isEmpty, !isDownloading else { return }
        let modelLocked = selectedModelID
        downloadProgress = 0
        downloadNote = String(format: AppL10n.t("onboarding.ai.downloading"), modelLocked)
        defer { downloadProgress = nil }
        do {
            _ = try await MLXModelDownloader.download(modelID: modelLocked) { progress in
                Task { @MainActor in
                    guard selectedModelID == modelLocked else { return }
                    downloadProgress = progress.fraction
                    downloadNote = progress.detail
                }
            }
            downloadedModelID = modelLocked
            downloadNote = AppL10n.t("onboarding.ai.downloadedOK")
        } catch {
            downloadNote = error.localizedDescription
        }
    }

    private func finish() async {
        isSaving = true
        defer { isSaving = false }
        if let avatarData {
            await store.saveAvatarImage(avatarData)
        }
        let goal: String = {
            if goalPreset == "custom" {
                return customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return goalPreset
        }()
        OnboardingPrefs.learningGoal = goal
        OnboardingPrefs.hasCompletedTips = true

        var profile = store.profile
        profile.preferredLanguagePair = LanguagePair(source: learningLanguage, target: nativeLanguage)
        profile.uiLocale = nativeLanguage
        profile.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch intelligenceChoice {
        case .apple:
            profile.activeAIProviderID = AIProviderID.foundationModels.rawValue
            profile.aiFallbackMode = .offlineOnly
        case .smartMix:
            profile.activeAIProviderID = AIProviderID.hybrid.rawValue
            profile.aiFallbackMode = .offlineOnly
        case .mlx:
            profile.activeAIProviderID = AIProviderID.mlx.rawValue
            profile.aiFallbackMode = .offlineOnly
            profile.remoteAIEnabled = false
        }

        if enableRemoteAPI {
            let config = ModelConfig(
                name: ProviderCapability.capability(for: remoteProvider).displayName,
                apiProvider: remoteProvider,
                model: remoteModel.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: ProviderCapability.capability(for: remoteProvider).defaultEndpoint?
                    .absoluteString
                    .replacingOccurrences(of: "/chat/completions", with: "")
                    .replacingOccurrences(of: "/v1/messages", with: ""),
                isDefault: true
            )
            var settings = store.remoteSettings
            settings.enabled = true
            settings.configs = [config]
            store.remoteSettings = settings
            profile.remoteAIEnabled = true
            let key = remoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try? APIKeyStore.save(key, account: APIKeyStore.account(for: config.id))
            }
        }

        profile.hasCompletedOnboarding = true
        await store.saveProfile(profile)
    }
}
