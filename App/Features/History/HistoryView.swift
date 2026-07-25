import SwiftUI
import Domain

/// Recently created vocabulary cards, optionally filtered to a single tag/pack.
struct HistoryView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var speech = SpeechService()
    @State private var search = ""

    /// When set, scopes history to a single tag/pack (e.g. tapped from the sidebar).
    var tagID: WordPack.ID?

    private var tagName: String? {
        guard let tagID else { return nil }
        return store.packs.first { $0.id == tagID }?.name
    }

    private var entries: [VocabularyEntry] {
        let base = store.historyEntries(tagID: tagID)
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        return base.filter {
            $0.word.lowercased().contains(q) || $0.meaning.lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    tagName.map { "No cards in \($0) yet" } ?? "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Cards you create or import appear here, newest first.")
                )
                .foregroundStyle(theme.mutedForeground)
            } else {
                List(entries) { entry in
                    row(entry)
                        .listRowBackground(theme.background)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
            }
        }
        .background(theme.background)
        .navigationTitle(tagName ?? "History")
        .searchable(text: $search, prompt: "Search history")
    }

    private func row(_ entry: VocabularyEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.word)
                        .font(.headline)
                        .foregroundStyle(theme.foreground)
                    if let reading = entry.reading {
                        Text(reading)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                Text(entry.meaning)
                    .font(.body)
                    .foregroundStyle(theme.foreground)
                if let example = entry.example, !example.isEmpty {
                    Text(example)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(2)
                }
                Text(entry.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
            }
            Spacer(minLength: 8)
            if entry.audioRelativePath != nil {
                Button {
                    playAudio(entry)
                } label: {
                    Image(systemName: "waveform.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.primary)
                .help("Play recording")
            }
            Button {
                speech.speak(entry.word, reading: entry.reading, language: entry.languagePair.source)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.primary)
            .help("Speak")
        }
        .padding(.vertical, 4)
    }

    @State private var audioPlayers: [UUID: AudioPlayerBox] = [:]

    private func playAudio(_ entry: VocabularyEntry) {
        guard let url = store.absoluteAudioURL(for: entry) else { return }
        let box = AudioPlayerBox(url: url)
        audioPlayers[entry.id] = box
        box.play()
    }
}
