import SwiftUI
import Domain

/// Dictation drill: see one side of the card, type the other.
/// Direction is random per item — write in the learning language or in the native language.
struct DictationModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    private enum WriteSide: Equatable {
        /// Prompt is native (L1); answer in learning language (L2).
        case learning
        /// Prompt is learning (L2); answer in native language (L1).
        case native
    }

    @State private var queue: [VocabularyEntry] = []
    @State private var writeSide: WriteSide = .learning
    @State private var promptText = ""
    @State private var expected = ""
    @State private var answerLanguageCode = ""
    @State private var acceptForms: [String] = []
    @State private var answer = ""
    @State private var feedback: StudyAnswerFeedback = .idle
    @State private var lastMatch: StudyAI.MatchResult = .incorrect
    @State private var nextEnabled = false
    @State private var isLoading = true
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

    private var writeLanguageName: String {
        localizedLanguageName(answerLanguageCode)
    }

    var body: some View {
        StudyScreen(mode: .dictation) {
            if isLoading {
                ProgressView(AppL10n.t("study.prep"))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if let entry = current {
                drill(entry)
                    .id("\(entry.id)-\(writeSide)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else if stats.answered > 0 {
                StudySessionSummaryView(stats: stats, title: AppL10n.t("study.dictation.doneTitle"))
            } else {
                ContentUnavailableView(
                    AppL10n.t("study.noCards"),
                    systemImage: "text.cursor",
                    description: Text(AppL10n.t("study.dictation.empty"))
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .navigationTitle(AppL10n.t("study.dictation.title"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help(AppL10n.t("study.dictation.howTo"))
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
        .alert(AppL10n.t("study.dictation.title"), isPresented: $showHelp) {
            Button(AppL10n.t("study.exitConfirm.stay"), role: .cancel) {}
        } message: {
            Text(AppL10n.t("study.dictation.howTo"))
        }
        .studyExitGuard(isDirty: isDirty && current != nil)
        .task { await bootstrap() }
    }

    private func drill(_ entry: VocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text(String(format: AppL10n.t("study.dictation.writeIn"), writeLanguageName))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.primary.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
            }

            Text(promptText)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)

            StudyHintChip(text: softHint(for: entry), isExpanded: $showHint)

            StudyAnswerField(
                placeholder: String(format: AppL10n.t("study.dictation.placeholder"), writeLanguageName),
                text: $answer,
                feedback: feedback,
                isFocused: $answerFocused,
                onSubmit: check
            )

            StudyFeedbackBanner(
                feedback: feedback,
                phraseContext: feedback == .idle
                    ? nil
                    : "\(entry.word) — \(entry.meaning)"
            )

            StudyDrillActions(
                canCheck: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                feedback: feedback,
                nextEnabled: nextEnabled,
                onCheck: check,
                onSkip: skip,
                onNext: { Task { await advance() } }
            )
        }
        .onAppear { answerFocused = true }
    }

    private func softHint(for entry: VocabularyEntry) -> String {
        var parts: [String] = [
            String(format: AppL10n.t("study.context.hintLetters"), expected.count),
        ]
        if writeSide == .learning, let reading = entry.reading, !reading.isEmpty {
            parts.append(reading)
        }
        return parts.joined(separator: " · ")
    }

    private func bootstrap() async {
        queue = StudyAI.pickStudyCards(store: store)
        initialCount = queue.count
        isLoading = false
        loadPrompt()
    }

    private func loadPrompt() {
        guard let entry = current else { return }
        answer = ""
        feedback = .idle
        lastMatch = .incorrect
        nextEnabled = false
        showHint = false

        let sides = lexicalSides(for: entry)
        writeSide = Bool.random() ? .learning : .native

        switch writeSide {
        case .learning:
            promptText = sides.native
            expected = sides.learning
            answerLanguageCode = entry.languagePair.source
            acceptForms = StudyAI.acceptForms(for: entry).filter {
                StudyAI.normalizePreserving($0) != StudyAI.normalizePreserving(sides.native)
            }
            if !acceptForms.contains(where: {
                StudyAI.normalizePreserving($0) == StudyAI.normalizePreserving(sides.learning)
            }) {
                acceptForms.insert(sides.learning, at: 0)
            }
        case .native:
            promptText = sides.learning
            expected = sides.native
            answerLanguageCode = entry.languagePair.target
            acceptForms = meaningAlternates(sides.native)
        }

        answerFocused = true
    }

    /// Resolve L2 / L1 strings regardless of forward vs reverse card layout.
    private func lexicalSides(for entry: VocabularyEntry) -> (learning: String, native: String) {
        if entry.direction == .reverse {
            return (learning: entry.meaning, native: entry.word)
        }
        return (learning: entry.word, native: entry.meaning)
    }

    private func meaningAlternates(_ meaning: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";,/;|/；、")
        var forms = meaning
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if forms.isEmpty { forms = [meaning] }
        return forms
    }

    private func localizedLanguageName(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let locale = Locale(identifier: AppL10n.code)
        if let name = locale.localizedString(forLanguageCode: base), !name.isEmpty {
            return name.capitalized(with: locale)
        }
        return PackJSONParser.languageDisplayName(code)
    }

    private func check() {
        guard current != nil, feedback == .idle else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let result = StudyAI.grade(
            answer,
            expected: expected,
            acceptForms: acceptForms,
            language: answerLanguageCode
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
        loadPrompt()
    }
}
