import SwiftUI
import Domain
import AIKit

/// Short 3-turn dialogue via MLX; production step for learner reply; tap words to add cards.
struct MiniDialogueModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var topic = ""
    @State private var turns: [DialogueTurn] = []
    @State private var isBuilding = false
    @State private var note: String?
    @State private var selectedWord: String?
    @State private var added = Set<String>()
    @State private var translationsEnabled = false
    @State private var revealedTurnIDs = Set<UUID>()
    @State private var usedAI = false

    /// Hide first learner turn → write own reply → compare to sample.
    @State private var productionPhase = false
    @State private var productionAnswer = ""
    @State private var productionFeedback: StudyAnswerFeedback = .idle
    @State private var productionSample = ""
    @State private var productionDone = false
    @State private var productionCard: VocabularyEntry?

    private struct DialogueTurn: Identifiable, Hashable {
        let id: UUID
        var speaker: String
        var text: String
        var translation: String?
        var isLearner: Bool

        init(speaker: String, text: String, translation: String?, isLearner: Bool) {
            self.id = UUID()
            self.speaker = speaker
            self.text = text
            self.translation = translation
            self.isLearner = isLearner
        }
    }

    private var isDirty: Bool {
        !turns.isEmpty || isBuilding || !productionAnswer.isEmpty
    }

    private var firstLearnerIndex: Int? {
        turns.firstIndex(where: \.isLearner)
    }

    var body: some View {
        StudyScreen(mode: .miniDialogue) {
            if isBuilding && turns.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppL10n.t("dialogue.building"))
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                    DialogueSkeletonView()
                }
            } else if turns.isEmpty {
                setup
            } else {
                chat
            }
        }
        .navigationTitle(AppL10n.t("dialogue.title"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if !turns.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $translationsEnabled) {
                        Label(AppL10n.t("dialogue.showTranslation"), systemImage: "character.book.closed")
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(AppL10n.t("dialogue.showTranslation"))
                    .onChange(of: translationsEnabled) { _, on in
                        if !on { revealedTurnIDs.removeAll() }
                    }
                }
            }
        }
        .studyExitGuard(isDirty: isDirty)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppL10n.t("dialogue.topic"))
                .font(.headline)
                .foregroundStyle(.primary)

            TextField(AppL10n.t("dialogue.topicPlaceholder"), text: $topic)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)

            Button {
                Task { await build() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(AppL10n.t("dialogue.start"))
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.primary)
            .disabled(isBuilding || store.vocabulary.isEmpty)

            if store.vocabulary.isEmpty {
                Label(AppL10n.t("study.needCards"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text(String(format: AppL10n.t("study.due"), store.vocabulary.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 14) {
            if usedAI {
                Label(AppL10n.t("dialogue.fromAI"), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if translationsEnabled {
                Text(AppL10n.t("dialogue.tapForTranslation"))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }

            ForEach(Array(turns.enumerated()), id: \.element.id) { idx, turn in
                let hideLearner = productionPhase && !productionDone
                    && firstLearnerIndex == idx
                if hideLearner {
                    productionPrompt(for: turn)
                } else {
                    bubble(turn)
                }
            }

            if let selectedWord {
                HStack {
                    Text(selectedWord)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        Task { await addWord(selectedWord) }
                    } label: {
                        Label(
                            added.contains(selectedWord.lowercased())
                                ? AppL10n.t("dialogue.added")
                                : AppL10n.t("dialogue.addCard"),
                            systemImage: added.contains(selectedWord.lowercased())
                                ? "checkmark.circle.fill" : "plus.circle"
                        )
                    }
                    .disabled(added.contains(selectedWord.lowercased()))
                }
                .padding(12)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                if !added.isEmpty {
                    Text(String(format: AppL10n.t("dialogue.savedSummary"), added.count))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.foreground)
                }

                HStack(spacing: 12) {
                    Button {
                        withAnimation(.snappy) {
                            resetSession()
                        }
                    } label: {
                        Text(AppL10n.t("dialogue.new"))
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Text(AppL10n.t("dialogue.done"))
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                }
            }
        }
    }

    private func productionPrompt(for turn: DialogueTurn) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(AppL10n.t("dialogue.yourReply"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(AppL10n.t("dialogue.replyPlaceholder"), text: $productionAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .disabled(productionFeedback != .idle)
            StudyFeedbackBanner(feedback: productionFeedback)
            HStack {
                if productionFeedback == .idle {
                    Button(AppL10n.t("study.context.check")) { checkProduction() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.primary)
                        .disabled(productionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(AppL10n.t("study.context.skip")) {
                        productionFeedback = .skipped(expected: productionSample)
                        productionDone = true
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(AppL10n.t("study.next")) {
                        productionDone = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                }
            }
            if case .incorrect = productionFeedback {
                Text(String(format: AppL10n.t("dialogue.sampleReply"), turn.text))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(theme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func checkProduction() {
        let result = StudyAI.grade(
            productionAnswer,
            expected: productionSample,
            language: store.profile.preferredLanguagePair.source
        )
        Task {
            switch result {
            case .correct:
                productionFeedback = .correct
                productionDone = true
                if let card = productionCard {
                    await StudyAI.applyDrillReview(card, outcome: .correct, store: store)
                    StudyLearnerPrefs.recordProductionPass(cardID: card.id)
                }
            case .nearMissAccent:
                productionFeedback = .nearMiss(kind: .accent, expected: productionSample)
                if let card = productionCard {
                    await StudyAI.applyDrillReview(card, outcome: .nearMissAccent, store: store)
                }
            case .nearMissForm:
                productionFeedback = .nearMiss(kind: .form, expected: productionSample)
                if let card = productionCard {
                    await StudyAI.applyDrillReview(card, outcome: .nearMissForm, store: store)
                }
            case .incorrect:
                // Soft: also accept if answer shares key tokens with sample
                if StudyAI.challengeOfflinePass(
                    answer: productionAnswer,
                    sample: productionSample,
                    keywords: productionSample.split(separator: " ").prefix(3).map(String.init)
                ) {
                    productionFeedback = .correct
                    productionDone = true
                    if let card = productionCard {
                        await StudyAI.applyDrillReview(card, outcome: .correct, store: store)
                        StudyLearnerPrefs.recordProductionPass(cardID: card.id)
                    }
                } else {
                    productionFeedback = .incorrect(expected: productionSample)
                    if let card = productionCard {
                        await StudyAI.applyDrillReview(card, outcome: .incorrect, store: store)
                    }
                }
            }
        }
    }

    private func resetSession() {
        turns = []
        selectedWord = nil
        usedAI = false
        note = nil
        revealedTurnIDs.removeAll()
        added.removeAll()
        productionPhase = false
        productionDone = false
        productionAnswer = ""
        productionFeedback = .idle
        productionSample = ""
    }

    private func bubble(_ turn: DialogueTurn) -> some View {
        let showThisTranslation = translationsEnabled && revealedTurnIDs.contains(turn.id)
        return HStack {
            if turn.isLearner { Spacer(minLength: 48) }
            VStack(alignment: turn.isLearner ? .trailing : .leading, spacing: 6) {
                Text(turn.speaker)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                wordFlow(turn.text)
                    .padding(12)
                    .background(
                        turn.isLearner ? theme.primary.opacity(0.16) : theme.muted,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture {
                        guard translationsEnabled,
                              let translation = turn.translation,
                              !translation.isEmpty else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if revealedTurnIDs.contains(turn.id) {
                                revealedTurnIDs.remove(turn.id)
                            } else {
                                revealedTurnIDs.insert(turn.id)
                            }
                        }
                    }
                if showThisTranslation, let translation = turn.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
            }
            if !turn.isLearner { Spacer(minLength: 48) }
        }
    }

    private func wordFlow(_ text: String) -> some View {
        let tokens = WordTokenizer.tokens(
            in: text,
            languageHint: store.profile.preferredLanguagePair.source,
            segmentID: UUID()
        )
        return FlowWrap(spacing: 0) {
            ForEach(tokens) { token in
                if token.isWord {
                    Text(token.text)
                        .foregroundStyle(.primary)
                        .background(
                            selectedWord == token.text
                                ? theme.primary.opacity(0.28) : .clear,
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .onTapGesture { selectedWord = token.text }
                } else {
                    Text(token.text).foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func build() async {
        isBuilding = true
        defer { isBuilding = false }
        usedAI = false
        note = nil
        revealedTurnIDs.removeAll()
        productionPhase = false
        productionDone = false
        productionAnswer = ""
        productionFeedback = .idle

        let cards = StudyAI.pickStudyCards(store: store, limit: 5)
        productionCard = cards.first
        let pair = store.profile.preferredLanguagePair
        let words = cards.map(\.word).joined(separator: ", ")
        let resolved = topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "casual chat using: \(words)"
            : topic

        let known = StudyAI.knownWordBudget(store: store, limit: 35).joined(separator: ", ")
        let prompt = """
        Write a short 3-turn dialogue in language "\(pair.source)" about: \(resolved).
        Speakers: A (native) and B (learner). MUST weave in these focus words: \(words).
        Prefer the learner's known vocabulary; avoid introducing many new lemmas.
        Known words (prefer these): \(known).
        At most 3 content words outside the known+focus lists in the whole dialogue.
        Use natural spoken \(pair.source), contractions where natural (e.g. j'ai, t'as); no textbook stiffness.
        Include a natural \(pair.target) translation for each turn.
        \(StudyAI.generationQualityClause)
        Reply JSON only (no markdown):
        {"turns":[{"speaker":"A","text":"...","translation":"..."},{"speaker":"B","text":"...","translation":"..."},{"speaker":"A","text":"...","translation":"..."}]}
        """

        if let raw = await StudyAI.ask(prompt, store: store, preferMLX: true),
           let json = StudyAI.parseJSONDictionary(raw),
           let arr = json["turns"] as? [[String: Any]] {
            let parsed: [DialogueTurn] = arr.compactMap { item in
                guard let sp = item["speaker"] as? String,
                      let tx = item["text"] as? String else { return nil }
                return DialogueTurn(
                    speaker: sp,
                    text: StudyAI.sanitize(tx),
                    translation: (item["translation"] as? String).map(StudyAI.sanitize),
                    isLearner: sp.uppercased().contains("B")
                )
            }
            if parsed.count >= 2 {
                withAnimation(.snappy) {
                    turns = Array(parsed.prefix(3))
                    usedAI = true
                    note = nil
                    beginProductionIfNeeded()
                }
                return
            }
        }

        let w = cards.first?.word ?? "…"
        let offline = StudyAI.offlineDialogueTurns(
            word: w,
            sourceLanguage: pair.source,
            targetLanguage: pair.target
        )
        withAnimation(.snappy) {
            turns = offline.map {
                DialogueTurn(speaker: $0.speaker, text: $0.text, translation: $0.translation, isLearner: $0.isLearner)
            }
            note = AppL10n.t("dialogue.offline")
            usedAI = false
            beginProductionIfNeeded()
        }
    }

    private func beginProductionIfNeeded() {
        if let idx = firstLearnerIndex {
            productionSample = turns[idx].text
            productionPhase = true
            productionDone = false
        } else {
            productionPhase = false
            productionDone = true
        }
    }

    private func addWord(_ word: String) async {
        var meaning = "—"
        if let defs = try? await WiktionaryRESTClient.definitions(for: word),
           let gloss = defs.first?.gloss {
            meaning = gloss
        }
        var packIDs: [UUID] = []
        if let tagID = await store.ensureTag(named: AppL10n.t("dialogue.autoTag")) {
            packIDs.append(tagID)
        }
        let topicTag = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topicTag.isEmpty, topicTag.count <= 32,
           let topicID = await store.ensureTag(named: topicTag) {
            packIDs.append(topicID)
        }
        let ok = await store.createManualCard(
            word: word,
            meaning: meaning,
            context: turns.map(\.text).joined(separator: " / "),
            packIDs: packIDs,
            reversed: false,
            alsoCreateReverse: true
        )
        if ok {
            added.insert(word.lowercased())
        }
    }
}
