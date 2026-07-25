import SwiftUI
import AppKit
import Domain

/// Shows a single pack's cards plus actions to grow it (AI generate / JSON import),
/// pin, or delete it (and its cards, if this is their only pack).
struct PackDetailView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var speech = SpeechService()

    let pack: WordPack

    @State private var showGenerate = false
    @State private var showImport = false
    @State private var showDeleteConfirm = false

    private var currentPack: WordPack {
        store.packs.first { $0.id == pack.id } ?? pack
    }

    private var cards: [VocabularyEntry] {
        store.vocabulary
            .filter { $0.packIDs.contains(pack.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if cards.isEmpty {
                ContentUnavailableView(
                    "No cards yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Generate more cards with AI or import a JSON pack.")
                )
                .foregroundStyle(theme.mutedForeground)
                .frame(maxHeight: .infinity)
            } else {
                List(cards) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.word).font(.headline).foregroundStyle(theme.foreground)
                            Text(entry.meaning).font(.body).foregroundStyle(theme.foreground)
                            if let example = entry.example, !example.isEmpty {
                                Text(example)
                                    .font(.caption)
                                    .foregroundStyle(theme.mutedForeground)
                            }
                        }
                        Spacer()
                        Button {
                            speech.speak(entry.word, reading: entry.reading, language: entry.languagePair.source)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(theme.primary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(theme.background)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
            }
        }
        .background(theme.background)
        .navigationTitle(currentPack.name)
        .dropDestination(for: VocabularyTransfer.self) { items, _ in
            guard let id = items.first?.id else { return false }
            Task { await store.addVocabulary(id, toPack: pack.id) }
            return true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Generate more with AI…") { showGenerate = true }
                    Button("Import JSON…") { showImport = true }
                    Button(currentPack.isPinned ? "Unpin" : "Pin") {
                        Task { await store.setPackPinned(pack.id, pinned: !currentPack.isPinned) }
                    }
                    Button("Delete pack", role: .destructive) { showDeleteConfirm = true }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showGenerate) {
            GeneratePackSheet(preselectedPackID: pack.id)
        }
        .sheet(isPresented: $showImport) {
            ImportPackAISheet()
        }
        .confirmationDialog(
            "Delete “\(currentPack.name)”?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete pack and its cards", role: .destructive) {
                Task {
                    await store.deletePackWithCards(pack.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                Text(currentPack.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                if let description = currentPack.packDescription, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                }
                Text("\(cards.count) cards")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var cover: some View {
        if let url = store.absoluteCoverURL(for: currentPack), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
        } else {
            ZStack {
                theme.muted
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(theme.primary)
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
        }
    }
}
