import SwiftUI

/// Lightweight Notion-style chrome pieces (Revu pattern) — Melingo-themed.
enum WorkspaceChrome {
    struct EmptyState: View {
        @Environment(\.theme) private var theme
        let systemImage: String
        let title: String
        let message: String

        var body: some View {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(theme.mutedForeground)
                Text(title)
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(theme.foreground)
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.lg)
        }
    }

        struct ProgressBar: View {
        @Environment(\.theme) private var theme
        let progress: Double

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.muted)
                    Capsule()
                        .fill(theme.primary)
                        .frame(width: max(4, geo.size.width * min(max(progress, 0), 1)))
                        .animation(DesignTokens.Animation.snappy, value: progress)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    struct StatCard: View {
        @Environment(\.theme) private var theme
        let title: String
        let value: String
        let systemImage: String

        var body: some View {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.primary)
                    .frame(width: 28, height: 28)
                    .background(theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(DesignTokens.Typography.heading)
                        .foregroundStyle(theme.foreground)
                        .monospacedDigit()
                    Text(title)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
            }
        }
    }
}
