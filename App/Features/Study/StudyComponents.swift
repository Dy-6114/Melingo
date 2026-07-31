import SwiftUI

// MARK: - Feedback state for drill inputs

enum StudyAnswerFeedback: Equatable {
    case idle
    case correct
    case nearMiss(kind: NearMissKind, expected: String)
    case incorrect(expected: String, detail: String? = nil)
    case skipped(expected: String)

    enum NearMissKind: Equatable {
        case accent
        case form
    }

    var showsNext: Bool {
        switch self {
        case .idle: return false
        case .correct, .nearMiss, .incorrect, .skipped: return true
        }
    }
}

// MARK: - Thin session progress

struct StudyProgressBar: View {
    @Environment(\.theme) private var theme
    var progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.muted.opacity(0.85))
                Capsule()
                    .fill(theme.primary)
                    .frame(width: max(4, geo.size.width * min(max(progress, 0), 1)))
                    .animation(.easeInOut(duration: 0.25), value: progress)
            }
        }
        .frame(height: 4)
        .accessibilityLabel(AppL10n.t("study.progress"))
        .accessibilityValue("\(Int((progress * 100).rounded()))%")
    }
}

// MARK: - Blank prompt with brand underline on ____

struct StudyBlankPrompt: View {
    @Environment(\.theme) private var theme
    let text: String
    var font: Font = .title3

    var body: some View {
        blankText
            .font(font)
            .foregroundStyle(theme.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.22), lineWidth: 1)
            }
    }

    private var blankText: Text {
        let parts = text.components(separatedBy: "____")
        var result = Text("")
        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                result = result + Text(part)
            }
            if index < parts.count - 1 {
                result = result + Text("____")
                    .foregroundColor(theme.primary)
                    .underline(true, color: theme.primary)
                    .fontWeight(.semibold)
            }
        }
        return result
    }
}

// MARK: - Hint chip (collapsible)

struct StudyHintChip: View {
    @Environment(\.theme) private var theme
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Label(
                    isExpanded ? AppL10n.t("study.hint.hide") : AppL10n.t("study.hint.show"),
                    systemImage: isExpanded ? "lightbulb.fill" : "lightbulb"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.primary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(theme.vocabAccent)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(theme.foreground)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.muted.opacity(0.7), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Answer field with inline feedback

struct StudyAnswerField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var text: String
    var feedback: StudyAnswerFeedback
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused(isFocused)
                .disabled(feedback != .idle)
                .onSubmit {
                    if feedback == .idle { onSubmit() }
                }

            trailingIcon
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: OKRadius.field, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.field, style: .continuous)
                .strokeBorder(borderColor, lineWidth: feedback == .idle ? 1 : 1.5)
        }
        .offset(x: shakeOffset)
        .animation(.easeInOut(duration: 0.12), value: feedback)
        .onChange(of: feedback) { _, newValue in
            switch newValue {
            case .incorrect, .nearMiss, .skipped:
                triggerShake()
            default:
                break
            }
        }
        .accessibilityLabel(placeholder)
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch feedback {
        case .idle:
            EmptyView()
        case .correct:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.explained)
                .transition(.scale.combined(with: .opacity))
        case .nearMiss(_, let expected):
            Text(expected)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .lineLimit(1)
        case .incorrect(let expected, _), .skipped(let expected):
            Text(expected)
                .font(.callout.weight(.semibold))
                .foregroundStyle(theme.destructive)
                .lineLimit(1)
        }
    }

    private var backgroundFill: Color {
        switch feedback {
        case .idle: return theme.card
        case .correct: return theme.explained.opacity(0.18)
        case .nearMiss: return Color(nsColor: .systemOrange).opacity(0.14)
        case .incorrect, .skipped: return theme.destructive.opacity(0.14)
        }
    }

    private var borderColor: Color {
        switch feedback {
        case .idle: return theme.border.opacity(0.45)
        case .correct: return theme.explained.opacity(0.7)
        case .nearMiss: return Color(nsColor: .systemOrange).opacity(0.7)
        case .incorrect, .skipped: return theme.destructive.opacity(0.65)
        }
    }

    private func triggerShake() {
        withAnimation(.default) {
            shakeOffset = 8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.default) { shakeOffset = -8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.default) { shakeOffset = 5 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.default) { shakeOffset = 0 }
        }
    }
}

/// Rich feedback line under the answer field (near-miss / skipped / phrase gloss).
struct StudyFeedbackBanner: View {
    @Environment(\.theme) private var theme
    var feedback: StudyAnswerFeedback
    var phraseContext: String? = nil

    var body: some View {
        if let message {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(color)
                if let phraseContext, !phraseContext.isEmpty {
                    Text(phraseContext)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
            }
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }

    private var message: String? {
        switch feedback {
        case .idle, .correct:
            return nil
        case .nearMiss(.accent, _):
            return AppL10n.t("study.feedback.nearMissAccent")
        case .nearMiss(.form, _):
            return AppL10n.t("study.feedback.nearMissForm")
        case .incorrect(_, let detail):
            return detail ?? AppL10n.t("study.feedback.incorrect")
        case .skipped:
            return AppL10n.t("study.feedback.skipped")
        }
    }

    private var color: Color {
        switch feedback {
        case .nearMiss: return Color(nsColor: .systemOrange)
        default: return theme.destructive
        }
    }
}

// MARK: - Check / Skip / Next actions

struct StudyDrillActions: View {
    @Environment(\.theme) private var theme
    var canCheck: Bool
    var feedback: StudyAnswerFeedback
    var nextEnabled: Bool
    var onCheck: () -> Void
    var onSkip: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if feedback == .idle {
                Button(AppL10n.t("study.context.check")) { onCheck() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.large)
                    .disabled(!canCheck)

                Button(AppL10n.t("study.context.skip")) { onSkip() }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .foregroundStyle(theme.mutedForeground)
            } else if feedback.showsNext {
                Button(AppL10n.t("study.next")) { onNext() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.large)
                    .disabled(!nextEnabled)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Exit confirmation for mid-session leave

struct StudyExitGuardModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var isDirty: Bool
    @State private var showConfirm = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showConfirm = true
                        } label: {
                            Label(AppL10n.t("study.exitConfirm.back"), systemImage: "chevron.left")
                        }
                    }
                }
            }
            .confirmationDialog(
                AppL10n.t("study.exitConfirm.title"),
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(AppL10n.t("study.exitConfirm.leave"), role: .destructive) {
                    dismiss()
                }
                Button(AppL10n.t("study.exitConfirm.stay"), role: .cancel) {}
            } message: {
                Text(AppL10n.t("study.exitConfirm.body"))
            }
    }
}

extension View {
    func studyExitGuard(isDirty: Bool) -> some View {
        modifier(StudyExitGuardModifier(isDirty: isDirty))
    }
}

// MARK: - Dialogue loading skeleton

struct DialogueSkeletonView: View {
    @Environment(\.theme) private var theme
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            skeletonBubble(alignLeading: true, width: 0.72)
            skeletonBubble(alignLeading: false, width: 0.58)
            skeletonBubble(alignLeading: true, width: 0.65)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func skeletonBubble(alignLeading: Bool, width: CGFloat) -> some View {
        HStack {
            if !alignLeading { Spacer(minLength: 48) }
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.muted.opacity(0.55 + 0.25 * phase))
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .padding(alignLeading ? .trailing : .leading, 80 * (1 - width))
            if alignLeading { Spacer(minLength: 48) }
        }
    }
}

// MARK: - Session summary

struct StudySessionStats: Equatable {
    var correct = 0
    var nearMiss = 0
    var incorrect = 0
    var skipped = 0

    var answered: Int { correct + nearMiss + incorrect + skipped }

    mutating func record(_ feedback: StudyAnswerFeedback) {
        switch feedback {
        case .idle: break
        case .correct: correct += 1
        case .nearMiss: nearMiss += 1
        case .incorrect: incorrect += 1
        case .skipped: skipped += 1
        }
    }
}

struct StudySessionSummaryView: View {
    @Environment(\.theme) private var theme
    var stats: StudySessionStats
    var title: String = AppL10n.t("study.summary.title")

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(theme.srsStrong)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.foreground)
            Text(String(format: AppL10n.t("study.summary.score"), stats.correct, max(stats.answered, 1)))
                .font(.title3.monospacedDigit())
                .foregroundStyle(theme.foreground)
            HStack(spacing: 16) {
                summaryChip(AppL10n.t("study.summary.correct"), stats.correct, theme.explained)
                summaryChip(AppL10n.t("study.summary.nearMiss"), stats.nearMiss, Color(nsColor: .systemOrange))
                summaryChip(AppL10n.t("study.summary.miss"), stats.incorrect + stats.skipped, theme.destructive)
            }
            Text(AppL10n.t("study.summary.nearMissNote"))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(20)
    }

    private func summaryChip(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
        }
    }
}

// MARK: - Mode icon tint helpers

extension StudyDestination {
    var iconTint: Color {
        switch self {
        case .review: Color(nsColor: .systemPink)
        case .context: Color(nsColor: .systemBlue)
        case .collocations: Color(nsColor: .systemTeal)
        case .production: Color(nsColor: .systemPurple)
        case .dictation: Color(nsColor: .systemBrown)
        case .challenge: Color(nsColor: .systemOrange)
        case .recognizeText: Color(nsColor: .systemIndigo)
        case .miniDialogue: Color(nsColor: .systemMint)
        case .contextMix: Color(nsColor: .systemCyan)
        case .voiceMix: Color(nsColor: .systemGreen)
        }
    }
}
