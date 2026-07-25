import SwiftUI
import Domain

/// Pack-level inspector: counts, progress, pin — Revu CardDetail vibe for WordPack.
struct PackInspector: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    let packID: UUID
    var onOpen: () -> Void = {}
    var onDismiss: (() -> Void)? = nil

    private var pack: WordPack? {
        store.packs.first { $0.id == packID }
    }

    var body: some View {
        Group {
            if let pack {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        header(pack)
                        let progress = store.packLearningProgress(for: pack)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            WorkspaceChrome.StatCard(
                                title: AppL10n.t("inspector.pack.cards"),
                                value: "\(progress.total)",
                                systemImage: "rectangle.stack"
                            )
                            WorkspaceChrome.StatCard(
                                title: AppL10n.t("inspector.pack.learned"),
                                value: "\(progress.learned)",
                                systemImage: "checkmark.circle"
                            )
                        }
                        WorkspaceChrome.ProgressBar(
                            progress: Double(progress.learned) / Double(max(progress.total, 1))
                        )
                        .padding(.vertical, 4)
                        if let description = pack.packDescription, !description.isEmpty {
                            Text(description)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(theme.mutedForeground)
                        }
                        VStack(spacing: 8) {
                            Button(action: onOpen) {
                                Label(AppL10n.t("inspector.pack.open"), systemImage: "arrow.right.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.primary)
                            Button(pack.isPinned ? AppL10n.t("packs.unpin") : AppL10n.t("packs.pin")) {
                                Task { await store.setPackPinned(pack.id, pinned: !pack.isPinned) }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            } else {
                WorkspaceChrome.EmptyState(
                    systemImage: "square.stack.3d.up",
                    title: AppL10n.t("inspector.pack.missing"),
                    message: AppL10n.t("inspector.missingHint")
                )
            }
        }
        .background(theme.muted.opacity(0.35))
    }

    private func header(_ pack: WordPack) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: pack.kind == .tag ? "tag.fill" : "square.stack.3d.up.fill")
                .foregroundStyle(theme.primary)
                .frame(width: 36, height: 36)
                .background(theme.primary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.name)
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundStyle(theme.foreground)
                Text(pack.kind == .tag ? AppL10n.t("quick.subtitle.tag") : AppL10n.t("quick.subtitle.pack"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
                if pack.isPinned {
                    Label(AppL10n.t("packs.pin"), systemImage: "pin.fill")
                        .font(DesignTokens.Typography.captionMedium)
                        .foregroundStyle(theme.primary)
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
}
