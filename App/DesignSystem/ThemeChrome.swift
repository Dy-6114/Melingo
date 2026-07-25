import SwiftUI

/// Compact reusable pieces styled by `theme` environment.
enum ThemeChrome {
    /// Section label — never force uppercase (breaks CJK / looks wrong in Russian).
    static func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Large, rounded input used on New Card and similar forms.
struct OKFieldModifier: ViewModifier {
    @Environment(\.theme) private var theme
    var minHeight: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.field, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
            }
    }
}

extension View {
    func okField(minHeight: CGFloat = 44) -> some View {
        modifier(OKFieldModifier(minHeight: minHeight))
    }
}

struct MemoryRing: View {
    @Environment(\.theme) private var theme
    let strength: Double

    var body: some View {
        let color = theme.srsColor(for: strength)
        ZStack {
            Circle()
                .stroke(theme.muted, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(strength, 0.04), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: strength)
        }
        .accessibilityLabel(String(format: AppL10n.t("srs.memoryPercent"), Int(strength * 100)))
    }
}

struct SentenceStateChip: View {
    @Environment(\.theme) private var theme
    let text: String
    let reading: String?
    let showReading: Bool
    let fontSize: CGFloat
    let isSelected: Bool
    let hasTranslation: Bool
    var hasExplanation: Bool = false
    let action: () -> Void

    var body: some View {
        // onTapGesture (not Button): macOS ScrollView often drops Button actions
        // on rows after the first.
        VStack(alignment: .leading, spacing: 2) {
            if showReading, let reading, !reading.isEmpty {
                Text(reading)
                    .font(.system(size: fontSize * 0.55).monospaced())
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(2)
            }
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.primary.opacity(0.18) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? theme.primary.opacity(0.55) : .clear,
                    lineWidth: 1.5
                )
        }
        .overlay(alignment: .leading) {
            if hasExplanation || hasTranslation || isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(borderColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityLabel(text)
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityStatus: String {
        if hasExplanation { return AppL10n.t("reader.statusExplained") }
        if hasTranslation { return AppL10n.t("reader.statusTranslated") }
        return AppL10n.t("reader.statusUnread")
    }

    private var borderColor: Color {
        if isSelected { return theme.primary }
        if hasExplanation { return theme.explained.opacity(0.7) }
        if hasTranslation { return theme.translatedHint.opacity(0.65) }
        return .clear
    }
}
