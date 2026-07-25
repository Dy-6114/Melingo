import SwiftUI
import Domain

/// Multi-step scenario: L1 prompt card → L2 answer, with LLM (or offline) grading.
struct ChallengeModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var topic = ""
    @State private var steps: [ChallengeStep] = []
    @State private var index = 0
    @State private var userAnswer = ""
    @State private var showSample = false
    @State private var isBuilding = false
    @State private var isJudging = false
    @State private var note: String?
    @State private var judgeFeedback: String?
    @State private var judgeCorrected: String?
    @State private var judgeOK: Bool?
    @State private var confirmEmptySkip = false
    @State private var keywords: [String] = []
    @State private var sourceCards: [VocabularyEntry] = []
    @FocusState private var answerFocused: Bool

    private struct ChallengeStep: Identifiable {
        let id = UUID()
        var promptL1: String
        var sampleL2: String
        var cardID: UUID?
    }

    private var isDirty: Bool {
        !steps.isEmpty || isBuilding || !userAnswer.isEmpty
    }

    private var currentStep: ChallengeStep? {
        guard steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    var body: some View {
        StudyScreen(mode: .challenge) {
            if steps.isEmpty {
                setup
            } else if let step = currentStep {
                round(step)
            }
        }
        .navigationTitle(AppL10n.t("study.challenge.title"))
        .toolbarTitleDisplayMode(.inline)
        .studyExitGuard(isDirty: isDirty)
        .confirmationDialog(
            AppL10n.t("study.challenge.emptySkipTitle"),
            isPresented: $confirmEmptySkip,
            titleVisibility: .visible
        ) {
            Button(AppL10n.t("study.challenge.emptySkipConfirm"), role: .destructive) {
                Task { await advanceAfterJudge(ok: false, feedback: AppL10n.t("study.feedback.skipped"), skipped: true) }
            }
            Button(AppL10n.t("study.exitConfirm.stay"), role: .cancel) {}
        } message: {
            Text(AppL10n.t("study.challenge.emptySkipBody"))
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppL10n.t("study.challenge.blurb"))
                .font(.callout)
                .foregroundStyle(theme.mutedForeground)
            Text(AppL10n.t("study.challenge.scenario"))
                .font(.headline)
                .foregroundStyle(theme.foreground)
            TextField(AppL10n.t("study.challenge.topic"), text: $topic)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
            Button {
                Task { await buildRound() }
            } label: {
                if isBuilding {
                    ProgressView().controlSize(.small)
                } else {
                    Text(AppL10n.t("study.challenge.start"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.primary)
            .disabled(isBuilding || store.vocabulary.isEmpty)
            if store.vocabulary.isEmpty {
                Text(AppL10n.t("study.needCards"))
                    .font(.callout)
                    .foregroundStyle(theme.destructive)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private func round(_ step: ChallengeStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(format: AppL10n.t("study.challenge.step"), index + 1, steps.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)

            // 1. L1 prompt on white card
            Text(step.promptL1)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)

            // 2. Answer field
            Text(AppL10n.t("study.challenge.answerIn"))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            TextField(AppL10n.t("study.challenge.placeholder"), text: $userAnswer, axis: .vertical)
                .font(.body)
                .lineLimit(2...6)
                .focused($answerFocused)
                .padding(12)
                .frame(minHeight: 88, alignment: .topLeading)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.45), lineWidth: 1)
                }
                .disabled(judgeOK != nil)

            // 3. Sample — only after user asked, and never show garbage
            if judgeOK == nil {
                Button {
                    showSample.toggle()
                } label: {
                    Text(showSample
                         ? AppL10n.t("study.challenge.hideSample")
                         : AppL10n.t("study.challenge.showSample"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .disabled(userAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !showSample)
            }

            if showSample, isCleanUserFacing(step.sampleL2) {
                Text(step.sampleL2)
                    .font(.callout)
                    .foregroundStyle(theme.foreground)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                            .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
                    }
            }

            if let judgeFeedback, isCleanUserFacing(judgeFeedback) {
                Text(judgeFeedback)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(judgeOK == true ? theme.explained : theme.destructive)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (judgeOK == true ? theme.explained : theme.destructive).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                    )
            }
            if let judgeCorrected, isCleanUserFacing(judgeCorrected) {
                Text(judgeCorrected)
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
            }

            // 4. Check / Skip — same language
            HStack(spacing: 12) {
                if judgeOK == nil {
                    Button {
                        Task { await checkAnswer() }
                    } label: {
                        if isJudging {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(AppL10n.t("study.context.check"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.large)
                    .disabled(isJudging || userAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(AppL10n.t("study.context.skip")) {
                        if userAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            confirmEmptySkip = true
                        } else {
                            Task {
                                await advanceAfterJudge(
                                    ok: false,
                                    feedback: AppL10n.t("study.feedback.skipped"),
                                    skipped: true
                                )
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .foregroundStyle(theme.mutedForeground)
                } else {
                    Button(index + 1 < steps.count
                           ? AppL10n.t("study.challenge.next")
                           : AppL10n.t("common.done")) {
                        goNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.large)
                }

                Spacer(minLength: 0)

                Button(AppL10n.t("study.challenge.restart")) {
                    steps = []
                    index = 0
                    userAnswer = ""
                    showSample = false
                    clearJudge()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .onAppear { answerFocused = true }
    }

    private func clearJudge() {
        judgeFeedback = nil
        judgeCorrected = nil
        judgeOK = nil
    }

    /// Reject prompt leaks / schema placeholders that models sometimes echo.
    private func isCleanUserFacing(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }
        let lower = t.lowercased()
        let banned = [
            "l1 instruction", "natural l2", "short coaching", "improved l2",
            "feedback language", "reply json", "system prompt",
            "je vais t'apprendre", "tu dois répéter", "parler fr.",
            "learner l1", "learner l2", "cefr target",
        ]
        if banned.contains(where: { lower.contains($0) }) { return false }
        if lower.hasPrefix("prompt:") || lower.hasPrefix("sample:") { return false }
        return true
    }

    private func buildRound() async {
        isBuilding = true
        defer { isBuilding = false }
        note = nil
        clearJudge()
        showSample = false
        let cards = StudyAI.pickStudyCards(store: store, limit: 6)
        sourceCards = cards
        keywords = cards.prefix(4).map(\.word)
        let pair = store.profile.preferredLanguagePair
        let themeWords = keywords.joined(separator: ", ")
        let resolvedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (themeWords.isEmpty ? "café" : themeWords)
            : topic

        let l1Name = pair.target
        let l2Name = pair.source
        let prompt = """
        Create exactly 3 spoken challenge steps for a language learner.
        Topic/situation: \(resolvedTopic)
        Write each "prompt" ONLY in \(l1Name) — a short real instruction the learner can act on \
        (e.g. a request or line to say). NEVER write English meta labels like "L1 instruction".
        Write each "sample" ONLY in \(l2Name) — one natural spoken reply (the expected answer). \
        NEVER paste coaching, lessons, or "repeat after me" text into sample.
        Optional words to weave into samples: \(themeWords)
        Prefer known words: \(StudyAI.knownWordBudget(store: store).prefix(20).joined(separator: ", "))
        \(StudyAI.generationQualityClause)
        Reply with JSON only, no markdown, no commentary:
        {"steps":[{"prompt":"…","sample":"…"},{"prompt":"…","sample":"…"},{"prompt":"…","sample":"…"}]}
        """
        if let raw = await StudyAI.ask(prompt, store: store),
           let json = StudyAI.parseJSONDictionary(raw),
           let arr = json["steps"] as? [[String: Any]] {
            let parsed = arr.enumerated().compactMap { offset, item -> ChallengeStep? in
                guard let p = item["prompt"] as? String,
                      let s = item["sample"] as? String,
                      isCleanUserFacing(p),
                      isCleanUserFacing(s) else { return nil }
                let cardID = cards.isEmpty ? nil : cards[offset % cards.count].id
                return ChallengeStep(
                    promptL1: StudyAI.sanitize(p),
                    sampleL2: StudyAI.sanitize(s),
                    cardID: cardID
                )
            }
            if parsed.count >= 2 {
                steps = Array(parsed.prefix(3))
                index = 0
                answerFocused = true
                return
            }
        }
        steps = fallbackSteps(topic: resolvedTopic, cards: cards, pair: pair)
        index = 0
        note = AppL10n.t("study.challenge.offlineNote")
        answerFocused = true
    }

    private func fallbackSteps(
        topic: String,
        cards: [VocabularyEntry],
        pair: LanguagePair
    ) -> [ChallengeStep] {
        let w1 = cards.first?.word ?? "bonjour"
        let w2 = cards.dropFirst().first?.word ?? "s’il vous plaît"
        let w3 = cards.dropFirst(2).first?.word ?? "merci"
        return [
            ChallengeStep(
                promptL1: StudyAI.offlineChallengePrompt(step: 0, topic: topic, word: w1, targetLanguage: pair.target),
                sampleL2: w1,
                cardID: cards.first?.id
            ),
            ChallengeStep(
                promptL1: StudyAI.offlineChallengePrompt(step: 1, topic: topic, word: w2, targetLanguage: pair.target),
                sampleL2: w2,
                cardID: cards.dropFirst().first?.id
            ),
            ChallengeStep(
                promptL1: StudyAI.offlineChallengePrompt(step: 2, topic: topic, word: w3, targetLanguage: pair.target),
                sampleL2: w3,
                cardID: cards.dropFirst(2).first?.id
            ),
        ]
    }

    private func checkAnswer() async {
        let trimmed = userAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            confirmEmptySkip = true
            return
        }
        isJudging = true
        defer { isJudging = false }
        let step = steps[index]
        let pair = store.profile.preferredLanguagePair

        let prompt = """
        Grade this learner reply.
        Task (in \(pair.target)): \(step.promptL1)
        Expected sample (in \(pair.source)): \(step.sampleL2)
        Learner answer: \(trimmed)
        CEFR: \(StudyLearnerPrefs.learnerCEFR)
        \(StudyAI.judgeRubric(feedbackLanguage: pair.target))
        Write real feedback in \(pair.target) — never copy schema words like "short coaching".
        JSON only:
        {"score":2,"ok":true,"feedback":"…","corrected":"…"}
        """
        if let raw = await StudyAI.ask(prompt, store: store),
           let json = StudyAI.parseJSONDictionary(raw) {
            let score = (json["score"] as? Int)
                ?? (json["score"] as? NSNumber)?.intValue
                ?? 0
            let ok: Bool = {
                if let b = json["ok"] as? Bool { return b }
                if let n = json["ok"] as? NSNumber { return n.boolValue }
                return score >= 2
            }()
            let fbRaw = (json["feedback"] as? String) ?? ""
            let fb = isCleanUserFacing(fbRaw)
                ? fbRaw
                : (ok ? AppL10n.t("study.challenge.pass") : AppL10n.t("study.challenge.fail"))
            let correctedRaw = json["corrected"] as? String
            let corrected = correctedRaw.flatMap { isCleanUserFacing($0) ? $0 : nil }
            await advanceAfterJudge(ok: ok, feedback: fb, corrected: corrected)
            return
        }

        let ok = StudyAI.challengeOfflinePass(
            answer: trimmed,
            sample: step.sampleL2,
            keywords: keywords
        )
        await advanceAfterJudge(
            ok: ok,
            feedback: ok
                ? AppL10n.t("study.challenge.offlinePass")
                : AppL10n.t("study.challenge.offlineFail"),
            corrected: isCleanUserFacing(step.sampleL2) ? step.sampleL2 : nil
        )
    }

    private func advanceAfterJudge(
        ok: Bool,
        feedback: String,
        corrected: String? = nil,
        skipped: Bool = false
    ) async {
        judgeOK = ok
        judgeFeedback = feedback
        judgeCorrected = corrected
        if steps.indices.contains(index), isCleanUserFacing(steps[index].sampleL2) {
            showSample = true
        }
        let cardID = steps.indices.contains(index) ? steps[index].cardID : nil
        let card = cardID.flatMap { id in sourceCards.first(where: { $0.id == id }) }
            ?? cardID.flatMap { id in store.vocabulary.first(where: { $0.id == id }) }
        if let card {
            let outcome: StudyAI.MatchResult = ok ? .correct : .incorrect
            await StudyAI.applyDrillReview(card, outcome: outcome, skipped: skipped, store: store)
            if ok {
                StudyLearnerPrefs.recordProductionPass(cardID: card.id)
            }
        }
    }

    private func goNext() {
        if index + 1 < steps.count {
            index += 1
            userAnswer = ""
            showSample = false
            clearJudge()
            answerFocused = true
        } else {
            steps = []
            sourceCards = []
            index = 0
            userAnswer = ""
            showSample = false
            clearJudge()
            note = AppL10n.t("study.challenge.complete")
        }
    }
}
