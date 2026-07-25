import SwiftUI
import Domain

/// Revu-style card inspector: SRS + language fields + actions (Melingo vocabulary).
struct VocabularyEntryInspector: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    let entryID: UUID
    var onEdit: () -> Void = {}
    var onDismiss: (() -> Void)? = nil

    @State private var speech = SpeechService()
    @State private var reviewLog: [ReviewResult] = []
    @State private var isLoadingLog = false

    private var entry: VocabularyEntry? {
        store.vocabulary.first { $0.id == entryID }
    }

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        header(entry)
                        fieldBlock(AppL10n.t("inspector.word"), entry.word)
                        if let reading = entry.reading, !reading.isEmpty {
                            fieldBlock(AppL10n.t("inspector.reading"), reading)
                        }
                        fieldBlock(AppL10n.t("inspector.meaning"), entry.meaning)
                        if let example = entry.example, !example.isEmpty {
                            fieldBlock(AppL10n.t("inspector.example"), example)
                        }
                        tagsSection(entry)
                        srsSection(entry)
                        reviewLogSection
                        actions(entry)
                    }
                    .padding(DesignTokens.Spacing.md)
                }
                .task(id: entryID) {
                    await loadReviewLog()
                }
            } else {
                WorkspaceChrome.EmptyState(
                    systemImage: "character.book.closed",
                    title: AppL10n.t("inspector.missing"),
                    message: AppL10n.t("inspector.missingHint")
                )
            }
        }
        .background(theme.muted.opacity(0.35))
    }

    private func header(_ entry: VocabularyEntry) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            MemoryRing(strength: VocabularyScheduling.currentRetrievability(entry))
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.word)
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundStyle(theme.foreground)
                Text("\(entry.languagePair.source) → \(entry.languagePair.target)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
                if entry.suspendedAt != nil {
                    Label(AppL10n.t("vocab.filter.paused"), systemImage: "pause.circle.fill")
                        .font(DesignTokens.Typography.captionMedium)
                        .foregroundStyle(theme.srsFading)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fieldBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)
                .tracking(0.4)
            Text(value)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
        }
    }

    private func tagsSection(_ entry: VocabularyEntry) -> some View {
        let packs = store.packs.filter { entry.packIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(AppL10n.t("inspector.packs").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)
                .tracking(0.4)
            if packs.isEmpty {
                Text(AppL10n.t("inspector.noPacks"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
            } else {
                InspectorPackChips(items: packs.map(\.name))
            }
        }
    }

    private func srsSection(_ entry: VocabularyEntry) -> some View {
        let retention = VocabularyScheduling.currentRetrievability(entry)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(AppL10n.t("inspector.srs").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)
                .tracking(0.4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                WorkspaceChrome.StatCard(
                    title: AppL10n.t("inspector.stat.state"),
                    value: srsStateLabel(entry),
                    systemImage: "circle.hexagongrid.fill"
                )
                WorkspaceChrome.StatCard(
                    title: AppL10n.t("inspector.stat.retention"),
                    value: String(format: "%.0f%%", retention * 100),
                    systemImage: "brain.head.profile"
                )
                WorkspaceChrome.StatCard(
                    title: AppL10n.t("inspector.stat.reviews"),
                    value: "\(entry.reviewCount)",
                    systemImage: "arrow.counterclockwise"
                )
                WorkspaceChrome.StatCard(
                    title: AppL10n.t("inspector.stat.due"),
                    value: entry.dueDate.isEmpty ? "—" : entry.dueDate,
                    systemImage: "calendar"
                )
            }
            HStack {
                Text(String(format: AppL10n.t("inspector.stat.stability"), entry.stability))
                Spacer()
                Text(String(format: AppL10n.t("inspector.stat.difficulty"), entry.difficulty))
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(theme.mutedForeground)
        }
    }

    private var reviewLogSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(AppL10n.t("inspector.reviewLog").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)
                .tracking(0.4)
            if isLoadingLog {
                ProgressView()
                    .controlSize(.small)
            } else if reviewLog.isEmpty {
                Text(AppL10n.t("inspector.reviewLog.empty"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(reviewLog.enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Text(gradeLabel(event.grade))
                                .font(DesignTokens.Typography.captionMedium)
                                .foregroundStyle(gradeColor(event.grade))
                                .frame(width: 52, alignment: .leading)
                            Text(event.reviewedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(theme.mutedForeground)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                    }
                }
            }
        }
    }

    private func actions(_ entry: VocabularyEntry) -> some View {
        VStack(spacing: 8) {
            Button {
                speech.speak(entry.word, reading: entry.reading, language: entry.languagePair.source)
            } label: {
                Label(AppL10n.t("review.speak"), systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button(AppL10n.t("vocab.edit"), action: onEdit)
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .frame(maxWidth: .infinity)
            Button(entry.suspendedAt == nil ? AppL10n.t("vocab.pause") : AppL10n.t("vocab.resume")) {
                Task { await store.suspendVocabulary(entry.id, suspend: entry.suspendedAt == nil) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private func srsStateLabel(_ entry: VocabularyEntry) -> String {
        if entry.suspendedAt != nil { return AppL10n.t("vocab.filter.paused") }
        switch entry.srsState {
        case .new: return AppL10n.t("vocab.filter.new")
        case .learning: return AppL10n.t("vocab.filter.learning")
        case .review: return AppL10n.t("vocab.filter.review")
        }
    }

    private func loadReviewLog() async {
        isLoadingLog = true
        reviewLog = await store.fetchReviewLog(for: entryID, limit: 12)
        isLoadingLog = false
    }

    private func gradeLabel(_ grade: Int) -> String {
        switch grade {
        case 1: AppL10n.t("review.again")
        case 2: AppL10n.t("review.hard")
        case 3: AppL10n.t("review.good")
        case 4: AppL10n.t("review.easy")
        default: "\(grade)"
        }
    }

    private func gradeColor(_ grade: Int) -> Color {
        switch grade {
        case 1: theme.srsWeak
        case 2: theme.srsFading
        case 3: theme.srsStrong
        case 4: theme.primary
        default: theme.mutedForeground
        }
    }
}

/// Compact wrap chips for pack names in the inspector.
private struct InspectorPackChips: View {
    @Environment(\.theme) private var theme
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { name in
                    chip(name)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { name in
                    chip(name)
                }
            }
        }
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(DesignTokens.Typography.captionMedium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.primary.opacity(0.12), in: Capsule())
            .foregroundStyle(theme.primary)
    }
}
