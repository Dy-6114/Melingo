import SwiftUI
import Domain

/// Collocation drills: complete an attested phrase around the target word.
struct CollocationsModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var queue: [VocabularyEntry] = []
    @State private var phrase = ""
    @State private var expected = ""
    @State private var answer = ""
    @State private var gloss = ""
    @State private var feedback: StudyAnswerFeedback = .idle
    @State private var lastMatch: StudyAI.MatchResult = .incorrect
    @State private var nextEnabled = false
    @State private var isLoading = true
    @State private var unavailable = false
    @State private var stats = StudySessionStats()
    @State private var answeredCount = 0
    @State private var initialCount = 0
    @FocusState private var answerFocused: Bool

    private var current: VocabularyEntry? { queue.first }
    private var sessionProgress: Double {
        guard initialCount > 0 else { return 0 }
        return Double(answeredCount) / Double(initialCount)
    }
    private var isDirty: Bool { answeredCount > 0 || !answer.isEmpty || feedback != .idle }

    var body: some View {
        StudyScreen(mode: .collocations) {
            if isLoading {
                ProgressView(AppL10n.t("study.collocations.building"))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if unavailable, current == nil, queue.isEmpty, stats.answered == 0 {
                ContentUnavailableView(
                    AppL10n.t("study.collocations.aiUnavailable"),
                    systemImage: "wifi.slash",
                    description: Text(AppL10n.t("study.collocations.aiUnavailableDetail"))
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if let entry = current, !phrase.isEmpty {
                drill(entry)
                    .id(entry.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else if current == nil, stats.answered > 0 {
                StudySessionSummaryView(stats: stats)
            } else if current == nil {
                ContentUnavailableView(
                    AppL10n.t("study.noCards"),
                    systemImage: "quote.bubble",
                    description: Text(AppL10n.t("study.collocations.empty"))
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ProgressView(AppL10n.t("study.collocations.building"))
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .navigationTitle(AppL10n.t("study.collocations.title"))
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isLoading, current != nil, !phrase.isEmpty {
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
        VStack(alignment: .leading, spacing: 18) {
            ThemeChrome.sectionLabel(AppL10n.t("study.collocations.fill"))

            StudyBlankPrompt(text: phrase, font: .system(size: 23, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                if !gloss.isEmpty {
                    Label {
                        Text(gloss)
                            .font(.callout)
                            .foregroundStyle(theme.foreground)
                    } icon: {
                        Text(StudyAI.flagEmoji(for: entry.languagePair.target))
                            .font(.body)
                    }
                }
                Label {
                    Text("\(entry.word) — \(entry.meaning)")
                        .font(.callout)
                        .foregroundStyle(theme.foreground)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(theme.vocabAccent)
                }
            }
            .padding(.horizontal, 4)

            StudyAnswerField(
                placeholder: AppL10n.t("study.collocations.placeholder"),
                text: $answer,
                feedback: feedback,
                isFocused: $answerFocused,
                onSubmit: check
            )

            StudyFeedbackBanner(
                feedback: feedback,
                phraseContext: feedback == .idle
                    ? nil
                    : phrase.replacingOccurrences(of: "____", with: expected)
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

    private func bootstrap() async {
        queue = StudyAI.pickStudyCards(store: store)
        initialCount = queue.count
        isLoading = false
        await loadItem()
    }

    private func loadItem() async {
        guard let entry = current else {
            phrase = ""
            return
        }
        answer = ""
        feedback = .idle
        lastMatch = .incorrect
        nextEnabled = false
        gloss = ""
        phrase = ""
        unavailable = false

        let pair = entry.languagePair
        let prompt = """
        Give ONE attested collocation for "\(entry.word)" (sense: \(entry.meaning)) in language "\(pair.source)".
        Prefer high-frequency corpus phrases. Do NOT invent novel metaphors.
        Blank ONLY the partner word with ____; keep the headword "\(entry.word)" visible in the phrase.
        Gloss the whole collocation in "\(pair.target)".
        \(StudyAI.generationQualityClause)
        If unsure the collocation is real, reply {"error":"no_attested"}.
        JSON only: {"phrase":"…____…","answer":"…","gloss":"…","attested":true}
        """
        if let raw = await StudyAI.ask(prompt, store: store),
           let json = StudyAI.parseJSONDictionary(raw) {
            if let err = json["error"] as? String, err == "no_attested" {
                await skipUnavailableCard()
                return
            }
            if let p = json["phrase"] as? String,
               let a = json["answer"] as? String,
               p.contains("____"),
               (json["attested"] as? Bool) != false {
                phrase = p
                expected = a
                gloss = (json["gloss"] as? String) ?? ""
                answerFocused = true
                return
            }
        }

        // Offline / failed AI: do NOT invent garbage drills — skip card or end session.
        await skipUnavailableCard()
    }

    private func skipUnavailableCard() async {
        if !queue.isEmpty { queue.removeFirst() }
        if queue.isEmpty {
            unavailable = true
            phrase = ""
            return
        }
        await loadItem()
    }

    private func check() {
        guard feedback == .idle else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lang = current?.languagePair.source
        let result = StudyAI.grade(answer, expected: expected, language: lang)
        lastMatch = result
        switch result {
        case .correct:
            feedback = .correct
        case .nearMissAccent:
            feedback = .nearMiss(kind: .accent, expected: expected)
        case .nearMissForm:
            feedback = .nearMiss(kind: .form, expected: expected)
        case .incorrect:
            feedback = .incorrect(expected: expected)
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
        await loadItem()
    }
}
