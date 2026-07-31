import SwiftUI
import UniformTypeIdentifiers
import Domain

struct StudyHubView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    @State private var path = NavigationPath()
    @State private var pendingOCRURL: URL?
    @State private var lockedToast: String?

    private let secondaryColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    private var secondaryModes: [StudyDestination] {
        StudyDestination.allCases.filter { $0 != .review }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hubStatStrip
                    priorityReviewCard
                    secondarySection
                }
                .padding(28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle(AppL10n.t("study.title"))
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(for: StudyDestination.self) { mode in
                destination(mode)
                    .environment(store)
                    .environment(\.theme, theme)
            }
            .overlay(alignment: .bottom) {
                if let lockedToast {
                    Text(lockedToast)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.cardForeground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
                        }
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onPasteCommand(of: [.image, .png, .tiff, .jpeg, .heic]) { providers in
                Task { await handleImagePaste(providers: providers) }
            }
            .onAppear { consumePendingStudyMode() }
            .onChange(of: router.pendingStudyMode) { _, _ in
                consumePendingStudyMode()
            }
        }
    }

    private func consumePendingStudyMode() {
        guard let mode = router.pendingStudyMode else { return }
        router.pendingStudyMode = nil
        path.append(mode)
    }

    // MARK: - Priority CTA

    private var hubStatStrip: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            WorkspaceChrome.StatCard(
                title: AppL10n.t("study.streak.due"),
                value: "\(store.dueCount)",
                systemImage: "rectangle.stack"
            )
            WorkspaceChrome.StatCard(
                title: AppL10n.t("stats.hours.today"),
                value: "\(store.reviewedTodayCount)",
                systemImage: "checkmark.circle"
            )
            WorkspaceChrome.StatCard(
                title: AppL10n.t("vocab.filter.new"),
                value: "\(store.newDueCount)",
                systemImage: "sparkles"
            )
        }
    }

    private var priorityReviewCard: some View {
        let due = store.dueCount
        let doneToday = store.reviewedTodayCount
        let totalToday = max(due + doneToday, 1)
        let progress = Double(doneToday) / Double(totalToday)
        let minutes = max(1, Int((Double(due) * 0.45).rounded(.up)))

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        due == 0
                            ? AppL10n.t("study.priority.caughtUp")
                            : String(format: AppL10n.t("study.priority.title"), due)
                    )
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.foreground)

                    Text(
                        due == 0
                            ? AppL10n.t("study.priority.caughtUpBody")
                            : String(format: AppL10n.t("study.priority.eta"), minutes)
                    )
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
                }
                Spacer(minLength: 12)
                Image(systemName: StudyDestination.review.systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.mutedForeground)
                    .frame(width: 52, height: 52)
                    .background(theme.muted.opacity(0.55), in: Circle())
            }

            if due > 0 || doneToday > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    StudyProgressBar(progress: progress)
                    Text(String(format: AppL10n.t("study.priority.progress"), doneToday, doneToday + due))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .monospacedDigit()
                }
            }

            if due > 0 {
                HStack(spacing: 10) {
                    Button {
                        path.append(StudyDestination.review)
                    } label: {
                        Text(AppL10n.t("study.priority.start"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.large)

                    Button {
                        openWindow(id: MelingoWindowID.review)
                    } label: {
                        Image(systemName: "macwindow.badge.plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(AppL10n.t("quick.action.reviewWindow"))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.28), lineWidth: 1.5)
        }
        .shadow(color: theme.primary.opacity(0.08), radius: 12, y: 4)
    }

    // MARK: - Secondary modes

    private var secondarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppL10n.t("study.modes.section"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)

            LazyVGrid(columns: secondaryColumns, spacing: 14) {
                ForEach(secondaryModes) { mode in
                    let available = isAvailable(mode)
                    Button {
                        if available {
                            path.append(mode)
                        } else {
                            showLockedToast(for: mode)
                        }
                    } label: {
                        modeCard(mode, available: available)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func modeCard(_ mode: StudyDestination, available: Bool) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(available ? theme.foreground : theme.mutedForeground)
                    .frame(width: 40, height: 40)
                    .background(
                        theme.muted.opacity(available ? 0.55 : 0.35),
                        in: Circle()
                    )
                Spacer(minLength: 0)
                if !available {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mutedForeground)
                }
            }

            Text(mode.localizedTitle)
                .font(.headline)
                .foregroundStyle(available ? theme.foreground : theme.mutedForeground)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Text(mode.subtitle)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = unavailableReason(mode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.t("study.locked.howTo"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.mutedForeground)
                    Text(reason)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.primary.opacity(0.9))
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            available ? theme.card : theme.muted.opacity(0.55),
            in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.border.opacity(available ? 0.22 : 0.35), lineWidth: 1)
        }
        .opacity(available ? 1 : 0.72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.localizedTitle)
        .accessibilityHint(available ? mode.subtitle : (unavailableReason(mode) ?? mode.subtitle))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Navigation / availability

    @ViewBuilder
    private func destination(_ mode: StudyDestination) -> some View {
        switch mode {
        case .review:
            ReviewSessionView(presentsAsNavigation: true)
        case .context:
            ContextFillModeView()
        case .collocations:
            CollocationsModeView()
        case .production:
            ProductionModeView()
        case .dictation:
            DictationModeView()
        case .challenge:
            ChallengeModeView()
        case .recognizeText:
            RecognizeTextModeView(initialImageURL: pendingOCRURL)
                .onDisappear { pendingOCRURL = nil }
        case .miniDialogue:
            MiniDialogueModeView()
        case .contextMix:
            ContextMixModeView()
        case .voiceMix:
            VoiceMixModeView()
        }
    }

    private func handleImagePaste(providers: [NSItemProvider]) async {
        _ = providers
        if let url = StudyPasteboard.tempImageURLFromClipboard() {
            pendingOCRURL = url
            path.append(StudyDestination.recognizeText)
        }
    }

    private func isAvailable(_ mode: StudyDestination) -> Bool {
        unavailableReason(mode) == nil
    }

    private func unavailableReason(_ mode: StudyDestination) -> String? {
        switch mode {
        case .review:
            return nil
        case .context, .collocations, .production, .dictation, .challenge, .miniDialogue:
            return store.vocabulary.isEmpty ? AppL10n.t("study.needCards") : nil
        case .recognizeText:
            return nil
        case .contextMix:
            let tags = StudyAI.tagsWithCards(store: store)
            return tags.count < 3 ? AppL10n.t("study.needTags") : nil
        case .voiceMix:
            // Always available once there are ≥2 cards (TTS fallback if no recordings).
            return store.vocabulary.count < 2 ? AppL10n.t("study.needCards") : nil
        }
    }

    private func showLockedToast(for mode: StudyDestination) {
        // Same copy as the tile reason — never contradict unlock rules (e.g. Voice Mix ≥2 cards).
        let message = unavailableReason(mode) ?? AppL10n.t("study.needCards")
        withAnimation(.snappy) { lockedToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            withAnimation(.snappy) {
                if lockedToast == message { lockedToast = nil }
            }
        }
    }
}
