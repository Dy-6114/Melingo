import SwiftUI
import Domain

/// Fill-the-blank using a due/deck card. Shows a local blank first, then may upgrade via MLX.
struct ContextFillModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var queue: [VocabularyEntry] = []
    @State private var prompt = ""
    @State private var expected = ""
    @State private var answer = ""
    @State private var feedback: StudyAnswerFeedback = .idle
    @State private var lastMatch: StudyAI.MatchResult = .incorrect
    @State private var nextEnabled = false
    @State private var isLoading = true
    @State private var isRefreshingAI = false
    @State private var usedAI = false
    @State private var stats = StudySessionStats()
    @State private var answeredCount = 0
    @State private var initialCount = 0
    @State private var showHint = false
    @State private var showHelp = false
    @FocusState private var answerFocused: Bool

    private var current: VocabularyEntry? { queue.first }
    private var sessionProgress: Double {
        guard initialCount > 0 else { return 0 }
        return Double(answeredCount) / Double(initialCount)
    }
    private var isDirty: Bool { answeredCount > 0 || !answer.isEmpty || feedback != .idle }

    /// Soft hint: length + reading — not the full L1 gloss (avoids cloze giveaway).
    private func softHint(for entry: VocabularyEntry) -> String {
        var parts: [String] = [
            String(format: AppL10n.t("study.context.hintLetters"), entry.word.count),
        ]
        if let reading = entry.reading, !reading.isEmpty {
            parts.append(reading)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        StudyScreen(mode: .context) {
            if isLoading {
                ProgressView(AppL10n.t("study.prep"))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if let entry = current {
                drill(entry)
                    .id(entry.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else if stats.answered > 0 {
                StudySessionSummaryView(stats: stats)
            } else {
                ContentUnavailableView(
                    AppL10n.t("study.noCards"),
                    systemImage: "checkmark.circle",
                    description: Text(AppL10n.t("study.context.empty"))
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .navigationTitle(AppL10n.t("study.context.title"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help(AppL10n.t("study.context.howTo"))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isLoading, current != nil {
                StudyProgressBar(progress: sessionProgress)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(theme.background)
            }
        }
        .alert(AppL10n.t("study.context.title"), isPresented: $showHelp) {
            Button(AppL10n.t("study.exitConfirm.stay"), role: .cancel) {}
        } message: {
            Text(AppL10n.t("study.context.howTo"))
        }
        .studyExitGuard(isDirty: isDirty && current != nil)
        .task { await bootstrap() }
    }

    private func drill(_ entry: VocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                usedAI
                    ? AppL10n.t("study.context.aiSentence")
                    : AppL10n.t("study.context.fromCard")
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.mutedForeground)

            Group {
                if prompt.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    StudyBlankPrompt(text: prompt, font: .title3)
                }
            }

            StudyHintChip(text: softHint(for: entry), isExpanded: $showHint)

            StudyAnswerField(
                placeholder: AppL10n.t("study.context.placeholder"),
                text: $answer,
                feedback: feedback,
                isFocused: $answerFocused,
                onSubmit: check
            )

            StudyFeedbackBanner(
                feedback: feedback,
                phraseContext: feedback == .idle ? nil : "\(entry.word) — \(entry.meaning)"
            )

            StudyDrillActions(
                canCheck: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                feedback: feedback,
                nextEnabled: nextEnabled,
                onCheck: check,
                onSkip: skip,
                onNext: { Task { await advance() } }
            )

            if isRefreshingAI {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            answerFocused = true
        }
    }

    private func bootstrap() async {
        queue = StudyAI.pickStudyCards(store: store)
        initialCount = queue.count
        isLoading = false
        await loadPrompt()
    }

    private func loadPrompt() async {
        guard let entry = current else { return }
        answer = ""
        feedback = .idle
        lastMatch = .incorrect
        nextEnabled = false
        showHint = false
        usedAI = false

        let fallback = StudyAI.blankSentence(for: entry)
        prompt = fallback.prompt
        expected = fallback.answer

        // Rotate a previously saved AI sentence when available.
        if let rotated = StudyLearnerPrefs.pickRotatedContext(for: entry.id, excluding: prompt),
           rotated.contains("____") {
            prompt = rotated
            expected = entry.word
            usedAI = true
        }

        isRefreshingAI = true
        defer { isRefreshingAI = false }

        let pair = entry.languagePair
        let aiPrompt = """
        Create ONE short sentence in language "\(pair.source)" that naturally uses the word "\(entry.word)" \
        (meaning: \(entry.meaning)). Replace that word with ____ (four underscores).
        \(StudyAI.generationQualityClause)
        The blank must be UNGUESSABLE from grammar alone; several words could fit syntactically, \
        but only the target word fits the intended meaning. Avoid patterns like "Je ____ français" for "parle".
        Reply with ONLY the sentence, no quotes.
        """
        if let sentence = await StudyAI.ask(aiPrompt, store: store, preferMLX: true),
           sentence.contains("____") {
            let cleaned = StudyAI.sanitize(sentence)
            prompt = cleaned
            expected = entry.word
            usedAI = true
            StudyLearnerPrefs.rememberContext(cleaned, for: entry.id)
        }

        answerFocused = true
    }

    private func check() {
        guard let entry = current, feedback == .idle else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let result = StudyAI.grade(
            answer,
            expected: expected,
            acceptForms: StudyAI.acceptForms(for: entry),
            language: entry.languagePair.source
        )
        lastMatch = result
        switch result {
        case .correct:
            feedback = .correct
        case .nearMissAccent:
            feedback = .nearMiss(kind: .accent, expected: expected)
        case .nearMissForm:
            feedback = .nearMiss(kind: .form, expected: expected)
        case .incorrect:
            feedback = .incorrect(expected: expected, detail: nil)
        }
        nextEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            nextEnabled = true
        }
    }

    private func skip() {
        guard feedback == .idle else { return }
        feedback = .skipped(expected: expected)
        lastMatch = .incorrect
        nextEnabled = true
    }

    private func advance() async {
        stats.record(feedback)
        if let entry = current {
            let skipped = {
                if case .skipped = feedback { return true }
                return false
            }()
            await StudyAI.applyDrillReview(entry, outcome: lastMatch, skipped: skipped, store: store)
        }
        answeredCount += 1
        if !queue.isEmpty { queue.removeFirst() }
        withAnimation(.easeInOut(duration: 0.15)) {}
        await loadPrompt()
    }
}
