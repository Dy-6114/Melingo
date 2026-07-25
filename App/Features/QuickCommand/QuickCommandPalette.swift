import SwiftUI

/// ⌘K palette — Revu QuickCommandPalette shape, Melingo tokens/actions.
struct QuickCommandPalette: View {
    @Bindable var controller: QuickCommandController
    let onSelect: (QuickCommandResult) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var highlightedIndex = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.mutedForeground)
                TextField(AppL10n.t("quick.placeholder"), text: $controller.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { commitSelection() }
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(AppL10n.t("common.cancel"))
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(theme.card.opacity(0.9))
            )

            Divider()

            if controller.results.isEmpty {
                WorkspaceChrome.EmptyState(
                    systemImage: "magnifyingglass",
                    title: controller.query.isEmpty
                        ? AppL10n.t("quick.empty.title")
                        : AppL10n.t("quick.empty.none"),
                    message: controller.query.isEmpty
                        ? AppL10n.t("quick.empty.hint")
                        : AppL10n.t("quick.empty.try")
                )
                .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, result in
                            QuickCommandRow(result: result, isHighlighted: index == highlightedIndex)
                                .onTapGesture {
                                    highlightedIndex = index
                                    commitSelection()
                                }
                                .onHover { hovering in
                                    if hovering { highlightedIndex = index }
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 520)
        .padding(DesignTokens.Spacing.lg)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .onAppear {
            highlightedIndex = 0
            isSearchFocused = true
        }
        .onChange(of: controller.results) { _, newResults in
            if newResults.isEmpty {
                highlightedIndex = 0
            } else {
                highlightedIndex = min(highlightedIndex, newResults.count - 1)
            }
        }
        .onMoveCommand { direction in
            guard !controller.results.isEmpty else { return }
            switch direction {
            case .down:
                highlightedIndex = min(highlightedIndex + 1, controller.results.count - 1)
            case .up:
                highlightedIndex = max(highlightedIndex - 1, 0)
            default:
                break
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    private func commitSelection() {
        guard highlightedIndex < controller.results.count else { return }
        onSelect(controller.results[highlightedIndex])
    }
}

private struct QuickCommandRow: View {
    @Environment(\.theme) private var theme
    let result: QuickCommandResult
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: result.icon)
                .imageScale(.medium)
                .foregroundStyle(isHighlighted ? theme.primary : theme.mutedForeground)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(isHighlighted ? DesignTokens.Typography.bodyMedium : DesignTokens.Typography.body)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let badge = result.badge {
                Text(badge)
                    .font(DesignTokens.Typography.captionMedium)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.primary.opacity(0.12)))
                    .foregroundStyle(theme.primary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(isHighlighted ? theme.primary.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
