import SwiftUI
import AppKit
import Domain

/// Paste JSON produced by NotebookLM / any chat model (using `PackJSONParser.notebookPrompt`)
/// and import it as a pack, with an optional cover image searched live on Wikimedia Commons.
struct ImportPackAISheet: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText = ""
    @State private var parseError: String?
    @State private var draft: PackImportDraft?
    @State private var copied = false

    @State private var coverQuery = ""
    @State private var coverResults: [CommonsImageResult] = []
    @State private var selectedCover: CommonsImageResult?
    @State private var selectedCoverData: Data?
    @State private var isSearchingCovers = false
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import pack from JSON")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.foreground)

            HStack {
                Text("1. Copy this prompt into NotebookLM / your AI of choice, paste the source material, then paste the JSON reply below.")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                Spacer()
                Button(copied ? "Copied" : "Copy prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PackJSONParser.notebookPrompt, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
            }

            TextEditor(text: $jsonText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(theme.muted, in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                }
                .frame(minHeight: 140)
                .onChange(of: jsonText) { _, _ in parse() }

            if let parseError {
                Text(parseError).font(.caption).foregroundStyle(theme.destructive)
            } else if let draft {
                Text("\(draft.title) — \(draft.cards.count) cards")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.explained)
            }

            coverSection

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await importPack() }
                } label: {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Import")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(draft == nil || isImporting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .background(theme.background)
        .tint(theme.primary)
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeChrome.sectionLabel("Cover (optional — Wikimedia Commons)")
            HStack {
                TextField("Search Commons images…", text: $coverQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await searchCovers() } }
                Button {
                    Task { await searchCovers() }
                } label: {
                    if isSearchingCovers {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(coverQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !coverResults.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coverResults) { result in
                            AsyncImage(url: result.thumbURL) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.gray.opacity(0.2)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                                    .strokeBorder(
                                        selectedCover?.id == result.id ? theme.primary : theme.border,
                                        lineWidth: selectedCover?.id == result.id ? 2 : 1
                                    )
                            }
                            .onTapGesture {
                                Task { await selectCover(result) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func parse() {
        guard !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft = nil
            parseError = nil
            return
        }
        do {
            draft = try PackJSONParser.parse(jsonText)
            parseError = nil
        } catch {
            draft = nil
            parseError = "Couldn’t parse JSON — check it matches the prompt schema."
        }
    }

    private func searchCovers() async {
        let query = coverQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearchingCovers = true
        defer { isSearchingCovers = false }
        do {
            coverResults = try await WikimediaCommonsClient.searchImages(query: query)
        } catch {
            coverResults = []
        }
    }

    private func selectCover(_ result: CommonsImageResult) async {
        selectedCover = result
        guard let url = result.fullURL ?? result.thumbURL else { return }
        selectedCoverData = try? await WikimediaCommonsClient.downloadImageData(from: url)
    }

    private func importPack() async {
        guard let draft else { return }
        isImporting = true
        defer { isImporting = false }
        if await store.importPack(draft: draft, coverData: selectedCoverData) != nil {
            dismiss()
        }
    }
}
