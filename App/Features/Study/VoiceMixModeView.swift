import SwiftUI
import AVFoundation
import Domain

/// Pick cards (prefer recordings; else TTS) → AI-ordered phrase → play sequence.
struct VoiceMixModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var pool: [VocabularyEntry] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var ordered: [VocabularyEntry] = []
    @State private var phrase = ""
    @State private var isBuilding = false
    @State private var isPlaying = false
    @State private var note: String?
    @State private var usingTTS = false
    @State private var player = SequencedAudioPlayer()
    @State private var speech = SpeechService()

    private var selected: [VocabularyEntry] {
        pool.filter { selectedIDs.contains($0.id) }
    }

    private var isDirty: Bool { !phrase.isEmpty || selectedIDs.count >= 2 }

    var body: some View {
        StudyScreen(mode: .voiceMix) {
            VStack(alignment: .leading, spacing: 16) {
                StudyCallout(
                    text: AppL10n.t("study.voiceMix.howTo")
                )
                if usingTTS {
                    Text(AppL10n.t("study.voiceMix.ttsNote"))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                } else {
                    Text(AppL10n.t("study.voiceMix.asrNote"))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
                Text(AppL10n.t("study.voiceMix.section"))
                    .font(.headline)
                    .foregroundStyle(.primary)

                if pool.count < 2 {
                    ContentUnavailableView(
                        AppL10n.t("study.voiceMix.needMore"),
                        systemImage: "waveform",
                        description: Text(AppL10n.t("study.needCards"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(pool.prefix(12)) { entry in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(entry.id) },
                            set: { on in
                                if on { selectedIDs.insert(entry.id) }
                                else { selectedIDs.remove(entry.id) }
                            }
                        )) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.word).font(.headline).foregroundStyle(.primary)
                                    Text(entry.meaning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: store.absoluteAudioURL(for: entry) != nil
                                      ? "waveform" : "speaker.wave.2")
                                    .foregroundStyle(theme.primary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    HStack {
                        Button {
                            Task { await buildPhrase() }
                        } label: {
                            if isBuilding { ProgressView().controlSize(.small) }
                            else { Label(AppL10n.t("study.voiceMix.build"), systemImage: "text.append") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.primary)
                        .disabled(selected.count < 2 || isBuilding)

                        Button {
                            playSequence()
                        } label: {
                            Label(
                                isPlaying ? AppL10n.t("study.voiceMix.playing") : AppL10n.t("study.voiceMix.play"),
                                systemImage: "play.fill"
                            )
                        }
                        .disabled(ordered.count < 2 || isPlaying)
                    }

                    if !phrase.isEmpty {
                        Text(phrase)
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.sheet))
                    }
                    if !ordered.isEmpty {
                        Text(AppL10n.t("study.voiceMix.order") + " " + ordered.map(\.word).joined(separator: " → "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(AppL10n.t("study.voiceMix.title"))
        .toolbarTitleDisplayMode(.inline)
        .studyExitGuard(isDirty: isDirty)
        .onAppear { reloadPool() }
        .onDisappear {
            player.stop()
            speech.stop()
        }
    }

    private func reloadPool() {
        let withAudio = StudyAI.cardsWithAudio(store: store)
        if withAudio.count >= 2 {
            pool = withAudio
            usingTTS = false
        } else {
            // Fallback: any study cards → TTS playback so the mode isn't permanently locked.
            pool = StudyAI.pickStudyCards(store: store, limit: 12)
            usingTTS = true
        }
    }

    private func buildPhrase() async {
        isBuilding = true
        defer { isBuilding = false }
        note = nil
        let cards = selected
        let words = cards.map(\.word)
        let pair = store.profile.preferredLanguagePair
        let prompt = """
        Arrange these learner words into ONE short natural sentence in language "\(pair.source)".
        Words (must all appear): \(words.joined(separator: ", "))
        \(StudyAI.generationQualityClause)
        Reply JSON only:
        {"sentence":"...","order":["word1","word2",...]}
        order must be the selected words in the order they appear in the sentence.
        """
        if let raw = await StudyAI.ask(prompt, store: store),
           let json = StudyAI.parseJSONDictionary(raw),
           let sentence = json["sentence"] as? String,
           let order = json["order"] as? [String] {
            phrase = sentence
            ordered = order.compactMap { w in
                cards.first { $0.word.localizedCaseInsensitiveCompare(w) == .orderedSame }
            }
            if ordered.count < 2 {
                ordered = cards
            }
            return
        }
        phrase = words.joined(separator: " ")
        ordered = cards
        note = "Offline order (AI unavailable) — playing selection order."
    }

    private func playSequence() {
        let urls = ordered.compactMap { store.absoluteAudioURL(for: $0) }
        if urls.count >= 2, urls.count == ordered.count {
            isPlaying = true
            player.play(urls: urls) { isPlaying = false }
            return
        }
        // TTS fallback (full or partial recordings).
        isPlaying = true
        playTTS(from: 0)
    }

    private func playTTS(from index: Int) {
        guard index < ordered.count else {
            isPlaying = false
            return
        }
        let entry = ordered[index]
        if let url = store.absoluteAudioURL(for: entry) {
            player.play(urls: [url]) {
                playTTS(from: index + 1)
            }
        } else {
            speech.speak(entry.word, reading: entry.reading, language: entry.languagePair.source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                playTTS(from: index + 1)
            }
        }
    }
}

@MainActor
final class SequencedAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var queue: [URL] = []
    private var index = 0
    private var player: AVAudioPlayer?
    private var onFinished: (() -> Void)?

    func play(urls: [URL], onFinished: @escaping () -> Void) {
        stop()
        self.queue = urls
        self.index = 0
        self.onFinished = onFinished
        playCurrent()
    }

    func stop() {
        player?.stop()
        player = nil
        queue = []
        index = 0
    }

    private func playCurrent() {
        guard index < queue.count else {
            onFinished?()
            onFinished = nil
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: queue[index])
            p.delegate = self
            player = p
            p.play()
        } catch {
            index += 1
            playCurrent()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.index += 1
            self.playCurrent()
        }
    }
}
