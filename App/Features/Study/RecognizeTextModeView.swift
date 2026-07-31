import SwiftUI
import UniformTypeIdentifiers
import Vision
import AppKit
import Domain

/// OCR study: pick or paste an image → Vision extracts words (image itself is never shown).
struct RecognizeTextModeView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    /// Optional image already staged by Study hub Cmd+V.
    var initialImageURL: URL? = nil

    @State private var words: [OCRWord] = []
    @State private var selected: OCRWord?
    @State private var hint: String?
    @State private var isBusy = false
    @State private var error: String?
    @State private var importerOpen = false
    @State private var addedIDs: Set<String> = []
    private let translator = TranslationService()

    private struct OCRWord: Identifiable, Hashable {
        var id: String { text.lowercased() + "|\(text)" }
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ThemeChrome.sectionLabel(AppL10n.t("study.ocr.section"))
            Text(AppL10n.t("study.ocr.blurb"))
                .font(.callout)
                .foregroundStyle(theme.mutedForeground)

            HStack(spacing: 10) {
                Button {
                    importerOpen = true
                } label: {
                    Label(AppL10n.t("study.ocr.choose"), systemImage: "doc.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(isBusy)

                Button {
                    Task { await pasteImageFromClipboard() }
                } label: {
                    Label(AppL10n.t("study.ocr.paste"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(AppL10n.t("study.ocr.progress"))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(theme.destructive)
            }

            if words.isEmpty && !isBusy {
                ContentUnavailableView(
                    AppL10n.t("study.ocr.emptyTitle"),
                    systemImage: "text.viewfinder",
                    description: Text(AppL10n.t("study.ocr.emptyBody"))
                )
                .frame(maxHeight: .infinity)
            } else {
                FlowWrap(spacing: 8) {
                    ForEach(words) { word in
                        Button {
                            selected = word
                            Task { await loadHint(word) }
                        } label: {
                            Text(word.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selected == word
                                        ? theme.primary.opacity(0.18)
                                        : theme.muted,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().strokeBorder(
                                        addedIDs.contains(word.id) ? theme.srsStrong : .clear,
                                        lineWidth: 1.5
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.foreground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let selected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selected.text)
                            .font(.title2.weight(.semibold))
                        if let hint {
                            Text(hint)
                                .font(.callout)
                                .foregroundStyle(theme.mutedForeground)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button {
                            Task { await addCard(selected) }
                        } label: {
                            Label(
                                addedIDs.contains(selected.id)
                                    ? AppL10n.t("lookup.added")
                                    : AppL10n.t("lookup.addCard"),
                                systemImage: addedIDs.contains(selected.id)
                                    ? "checkmark.circle.fill" : "plus.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(addedIDs.contains(selected.id) ? theme.mutedForeground : theme.primary)
                        .disabled(addedIDs.contains(selected.id))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OKRadius.sheet, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: OKRadius.sheet, style: .continuous)
                            .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        .navigationTitle(AppL10n.t("study.ocr.title"))
        .trackStudyActivity(.recognizeText)
        .fileImporter(
            isPresented: $importerOpen,
            allowedContentTypes: [.image, .png, .jpeg, .heic, .tiff, .gif, .bmp],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await recognize(url) }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
        .onPasteCommand(of: [.image, .png, .tiff, .jpeg, .heic]) { providers in
            Task { await recognize(providers: providers) }
        }
        .task(id: initialImageURL?.path) {
            guard let initialImageURL else { return }
            await recognize(initialImageURL)
        }
    }

    private func pasteImageFromClipboard() async {
        if let url = StudyPasteboard.tempImageURLFromClipboard() {
            await recognize(url)
            return
        }
        error = AppL10n.t("study.ocr.noClipboardImage")
    }

    private func recognize(providers: [NSItemProvider]) async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        _ = providers
        if let url = StudyPasteboard.tempImageURLFromClipboard() {
            await recognize(url)
            return
        }
        error = AppL10n.t("study.ocr.noClipboardImage")
    }

    private func recognize(_ url: URL) async {
        isBusy = true
        error = nil
        selected = nil
        hint = nil
        defer { isBusy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let extracted = try await OCRWordExtractor.words(from: url)
            words = extracted.map { OCRWord(text: $0) }
            if words.isEmpty {
                error = AppL10n.t("study.ocr.noWords")
            }
        } catch {
            self.error = error.localizedDescription
            words = []
        }
    }

    private func loadHint(_ word: OCRWord) async {
        hint = nil
        let pair = store.profile.preferredLanguagePair
        // Single word: engines only — never LLM. Accept either language direction.
        if let resolved = await translator.resolveStudyLookup(word.text, pair: pair) {
            hint = resolved.gloss
            return
        }
        if let defs = try? await WiktionaryRESTClient.definitions(for: word.text),
           let first = defs.first {
            hint = [first.partOfSpeech, first.gloss].filter { !$0.isEmpty }.joined(separator: " — ")
            return
        }
        hint = AppL10n.t("study.ocr.noHint")
    }

    private func addCard(_ word: OCRWord) async {
        let pair = store.profile.preferredLanguagePair
        let resolved = await translator.resolveStudyLookup(word.text, pair: pair)
        let study = resolved?.cardWord ?? word.text
        let meaning = resolved?.cardMeaning ?? hint ?? "—"
        let ok = await store.createManualCard(
            word: study,
            meaning: meaning,
            context: nil,
            reading: nil,
            packIDs: [],
            reversed: false
        )
        if ok { addedIDs.insert(word.id) }
    }
}

enum StudyPasteboard {
    static func tempImageURLFromClipboard() -> URL? {
        let pb = NSPasteboard.general
        guard let image = NSImage(pasteboard: pb) else { return nil }
        return writeTempPNG(image)
    }

    static func writeTempImage(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            // NSItemProvider is not Sendable; load synchronously from the continuation callback.
            let load: (Data?, (any Error)?) -> Void = { data, _ in
                guard let data, let image = NSImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: writeTempPNG(image))
            }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier, completionHandler: load)
        }
    }

    static func writeTempPNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melingo-ocr-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

enum OCRWordExtractor {
    static func words(from url: URL) async throws -> [String] {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw NSError(
                domain: "OCR", code: 1,
                userInfo: [NSLocalizedDescriptionKey: AppL10n.t("study.ocr.readFail")]
            )
        }
        return try await words(from: cgImage)
    }

    static func words(from cgImage: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var seen = Set<String>()
                var out: [String] = []
                for obs in observations {
                    guard let line = obs.topCandidates(1).first?.string else { continue }
                    for raw in line.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
                        let token = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard token.count > 1 else { continue }
                        let key = token.lowercased()
                        if seen.insert(key).inserted {
                            out.append(token)
                        }
                    }
                }
                continuation.resume(returning: out)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "ru", "fr", "de", "es"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
