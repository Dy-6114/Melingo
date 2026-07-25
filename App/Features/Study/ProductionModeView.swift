import SwiftUI
import Domain

/// Active production: write an original sentence using the target word; LLM grades.
struct ProductionModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var queue: [VocabularyEntry] = []
    @State private var sentence = ""
    @State private var feedback: StudyAnswerFeedback = .idle
    @State private var lastMatch: StudyAI.MatchResult = .incorrect
    @State private var coachNote: String?
    @State private var corrected: String?
    @State private var nextEnabled = false
    @State private var isLoading = true
    @State private var isGrading = false
    @State private var stats = StudySessionStats()
    @State private var answeredCount = 0
    @State private var initialCount = 0
    @FocusState private var focused: Bool

    private var current: VocabularyEntry? { queue.first }
    private var sessionProgress: Double {
        guard initialCount > 0 else { return 0 }
        return Double(answeredCount) / Double(initialCount)
    }
    private var isDirty: Bool { answeredCount > 0 || !sentence.isEmpty || feedback != .idle }

    var body: some View {
        StudyScreen(mode: .production) {
            if isLoading {
                ProgressView(AppL10n.t("study.prep"))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if let entry = current {
                drill(entry)
                    .id(entry.id)
            } else if stats.answered > 0 {
                StudySessionSummaryView(stats: stats, title: AppL10n.t("study.production.doneTitle"))
            } else {
                ContentUnavailableView(
                    AppL10n.t("study.noCards"),
                    systemImage: "pencil.line",
                    description: Text(AppL10n.t("study.production.empty"))
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .navigationTitle(AppL10n.t("study.production.title"))
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isLoading, current != nil {
                StudyProgressBar(progress: sessionProgress)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(theme.background)
            }
        }
        .studyExitGuard(isDirty: isDirty && current != nil)
        .task { await bootstrap() }
    }

    private func drill(_ entry: VocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            StudyCallout(text: AppL10n.t("study.production.howTo"))
            Text(entry.word)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme.foreground)
            Text(entry.meaning)
                .font(.title3)
                .foregroundStyle(theme.mutedForeground)

            Text(AppL10n.t("study.production.prompt"))
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.foreground)

            TextEditor(text: $sentence)
                .font(.body)
                .focused($focused)
                .frame(minHeight: 110)
                .padding(8)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.chip)
                        .strokeBorder(theme.border, lineWidth: 1)
                }
                .disabled(feedback != .idle)

            StudyFeedbackBanner(feedback: feedback, phraseContext: coachNote)
            if let corrected, !corrected.isEmpty {
                Text(corrected)
                    .font(.callout.italic())
                    .foregroundStyle(theme.mutedForeground)
            }

            StudyDrillActions(
                canCheck: !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGrading,
                feedback: feedback,
                nextEnabled: nextEnabled,
                onCheck: { Task { await check(entry) } },
                onSkip: skip,
                onNext: { Task { await advance() } }
            )
            if isGrading {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { focused = true }
    }

    private func bootstrap() async {
        queue = StudyAI.pickStudyCards(store: store)
        initialCount = queue.count
        isLoading = false
        resetItem()
    }

    private func resetItem() {
        sentence = ""
        feedback = .idle
        lastMatch = .incorrect
        coachNote = nil
        corrected = nil
        nextEnabled = false
        focused = true
    }

    private func check(_ entry: VocabularyEntry) async {
        guard feedback == .idle else { return }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGrading = true
        defer { isGrading = false }

        let pair = entry.languagePair
        let prompt = """
        The learner must write ONE original sentence in "\(pair.source)" that uses the word "\(entry.word)" \
        (sense: \(entry.meaning)).
        Learner sentence: \(trimmed)
        CEFR: \(StudyLearnerPrefs.learnerCEFR)
        \(StudyAI.judgeRubric(feedbackLanguage: pair.target))
        Extra: usesTargetWord must be true for ok=true. Wrong inflection of the target (e.g. plural vs singular \
        when the sense needs singular) → score≤1, ok=false, mention form in feedback.
        Reply JSON only:
        {"score":0-3,"ok":bool,"usesTargetWord":bool,"grammarOK":bool,"feedback":"…","corrected":"…"}
        """

        if let raw = await StudyAI.ask(prompt, store: store),
           let json = StudyAI.parseJSONDictionary(raw) {
            let ok = boolValue(json["ok"]) ?? (((json["score"] as? Int) ?? 0) >= 2)
            let uses = boolValue(json["usesTargetWord"]) ?? trimmed.localizedCaseInsensitiveContains(entry.word)
            let grammar = boolValue(json["grammarOK"]) ?? ok
            coachNote = json["feedback"] as? String
            corrected = json["corrected"] as? String
            if ok && uses {
                lastMatch = .correct
                feedback = .correct
            } else if uses && !grammar {
                lastMatch = .nearMissForm
                feedback = .nearMiss(kind: .form, expected: entry.word)
            } else if uses {
                lastMatch = .nearMissForm
                feedback = .nearMiss(kind: .form, expected: entry.word)
            } else {
                lastMatch = .incorrect
                feedback = .incorrect(expected: entry.word, detail: coachNote)
            }
        } else {
            // Offline: must contain the lemma (or morphological variant → near-miss).
            if trimmed.localizedCaseInsensitiveContains(entry.word) {
                lastMatch = .correct
                feedback = .correct
                coachNote = AppL10n.t("study.production.offlinePass")
            } else if StudyAI.isMorphologicalVariant(
                trimmed.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
                    .first { StudyAI.isMorphologicalVariant($0, of: entry.word, language: pair.source) } ?? "",
                of: entry.word,
                language: pair.source
            ) || trimmed.split(whereSeparator: \.isWhitespace).contains(where: {
                StudyAI.isMorphologicalVariant(String($0), of: entry.word, language: pair.source)
            }) {
                lastMatch = .nearMissForm
                feedback = .nearMiss(kind: .form, expected: entry.word)
                coachNote = AppL10n.t("study.feedback.nearMissForm")
            } else {
                lastMatch = .incorrect
                feedback = .incorrect(expected: entry.word)
                coachNote = AppL10n.t("study.production.offlineFail")
            }
        }
        nextEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nextEnabled = true }
    }

    private func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    private func skip() {
        guard feedback == .idle, let entry = current else { return }
        feedback = .skipped(expected: entry.word)
        lastMatch = .incorrect
        coachNote = AppL10n.t("study.feedback.skipped")
        nextEnabled = true
    }

    private func advance() async {
        stats.record(feedback)
        if let entry = current {
            let skipped = { if case .skipped = feedback { return true }; return false }()
            await StudyAI.applyDrillReview(entry, outcome: lastMatch, skipped: skipped, store: store)
            if lastMatch == .correct {
                StudyLearnerPrefs.recordProductionPass(cardID: entry.id)
            }
        }
        answeredCount += 1
        if !queue.isEmpty { queue.removeFirst() }
        resetItem()
    }
}
