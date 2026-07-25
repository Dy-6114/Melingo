import SwiftUI
import Domain

/// Compose one sentence using 3–4 words from different tags; AI grades coverage + FSRS touch.
struct ContextMixModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var picked: [VocabularyEntry] = []
    @State private var sentence = ""
    @State private var feedback: String?
    @State private var improved: String?
    @State private var isGrading = false
    @State private var note: String?
    @State private var gradedOnce = false

    private var tags: [WordPack] { StudyAI.tagsWithCards(store: store) }
    private var isDirty: Bool { !picked.isEmpty || !sentence.isEmpty || gradedOnce }

    var body: some View {
        StudyScreen(mode: .contextMix) {
            VStack(alignment: .leading, spacing: 16) {
                StudyCallout(text: AppL10n.t("study.contextMix.howTo"))
                Text(AppL10n.t("study.contextMix.words"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                if picked.isEmpty {
                    Text(AppL10n.t("study.needTags"))
                        .foregroundStyle(.secondary)
                    Button(AppL10n.t("study.contextMix.pick")) { pickWords() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.primary)
                        .disabled(tags.count < 3)
                } else {
                    FlowWrap(spacing: 8) {
                        ForEach(picked) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.word).font(.headline).foregroundStyle(.primary)
                                Text(entry.meaning)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(theme.muted, in: RoundedRectangle(cornerRadius: OKRadius.chip))
                        }
                    }
                    Text(AppL10n.t("study.contextMix.write"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $sentence)
                        .font(.body)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip))
                        .overlay {
                            RoundedRectangle(cornerRadius: OKRadius.chip)
                                .strokeBorder(theme.border, lineWidth: 1)
                        }
                    HStack {
                        Button {
                            Task { await grade() }
                        } label: {
                            if isGrading { ProgressView().controlSize(.small) }
                            else { Text(AppL10n.t("study.contextMix.grade")) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.primary)
                        .disabled(sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGrading)
                        Button(AppL10n.t("study.contextMix.new")) {
                            sentence = ""
                            feedback = nil
                            improved = nil
                            gradedOnce = false
                            pickWords()
                        }
                    }
                    if let feedback {
                        Text(feedback)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip))
                    }
                    if let improved {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppL10n.t("study.contextMix.improved")).font(.caption.weight(.semibold))
                            Text(improved).font(.callout.italic())
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let note {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(AppL10n.t("study.contextMix.title"))
        .toolbarTitleDisplayMode(.inline)
        .studyExitGuard(isDirty: isDirty)
        .onAppear {
            if tags.count >= 3, picked.isEmpty { pickWords() }
        }
    }

    private func pickWords() {
        var selected: [VocabularyEntry] = []
        var usedTags = Set<UUID>()
        let shuffledTags = tags.shuffled()
        for tag in shuffledTags {
            guard selected.count < 4 else { break }
            guard !usedTags.contains(tag.id) else { continue }
            if let card = store.vocabulary
                .filter({ $0.packIDs.contains(tag.id) && $0.suspendedAt == nil })
                .randomElement() {
                selected.append(card)
                usedTags.insert(tag.id)
            }
        }
        if selected.count < 3 {
            for entry in store.vocabulary.shuffled() where entry.suspendedAt == nil {
                guard selected.count < 3 else { break }
                if selected.contains(where: { $0.id == entry.id }) { continue }
                selected.append(entry)
            }
        }
        picked = selected
    }

    private func grade() async {
        isGrading = true
        defer { isGrading = false }
        feedback = nil
        improved = nil
        note = nil
        let words = picked.map(\.word)
        let pair = store.profile.preferredLanguagePair
        let prompt = """
        The learner wrote a sentence meant to include ALL of these words: \(words.joined(separator: ", ")).
        Sentence: \(sentence)
        Study language: \(pair.source)
        \(StudyLearnerPrefs.cefrPromptClause)
        Reply JSON only:
        {"usedAll":true/false,"missing":["..."],"feedback":"short coaching in \(pair.target)","improved":"optional better sentence using all words"}
        """
        var usedAll = false
        var missing: [String] = []
        if let raw = await StudyAI.ask(prompt, store: store),
           let json = StudyAI.parseJSONDictionary(raw) {
            usedAll = json["usedAll"] as? Bool ?? false
            missing = (json["missing"] as? [String]) ?? []
            let fb = (json["feedback"] as? String) ?? ""
            improved = json["improved"] as? String
            if usedAll {
                feedback = fb.isEmpty ? AppL10n.t("study.contextMix.allUsed") : fb
            } else {
                let miss = missing.isEmpty
                    ? words.filter { !sentence.localizedCaseInsensitiveContains($0) }
                    : missing
                feedback = fb.isEmpty
                    ? String(format: AppL10n.t("study.contextMix.missing"), miss.joined(separator: ", "))
                    : fb
            }
        } else {
            missing = words.filter { !sentence.localizedCaseInsensitiveContains($0) }
            usedAll = missing.isEmpty
            feedback = usedAll
                ? AppL10n.t("study.contextMix.offlinePass")
                : String(format: AppL10n.t("study.contextMix.missing"), missing.joined(separator: ", "))
            note = AppL10n.t("study.contextMix.offlineNote")
        }

        gradedOnce = true
        for entry in picked {
            let listedMissing = missing.contains {
                $0.localizedCaseInsensitiveCompare(entry.word) == .orderedSame
            }
            let inSentence = sentence.localizedCaseInsensitiveContains(entry.word)
            let hit = usedAll || (!listedMissing && inSentence)
            await StudyAI.applyDrillReview(
                entry,
                outcome: hit ? .correct : .incorrect,
                store: store
            )
        }
    }
}
