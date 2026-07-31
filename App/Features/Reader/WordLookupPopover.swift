import SwiftUI
import Domain

/// Word lookup: translation first, then IPA + Wiki thumb + example — never LLM for gloss.
struct WordLookupPopover: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    let word: String
    let segment: TextSegment
    let documentTitle: String?
    var canSpeak: Bool = true

    @State private var translation: String?
    /// Study-language form used for cards / dictionary (may differ from `word` when the click was native text).
    @State private var cardWord: String?
    @State private var cardMeaning: String?
    @State private var speakLanguage: String?
    @State private var transcription: String?
    @State private var partOfSpeech: String?
    @State private var definition: String?
    @State private var exampleSource: String?
    @State private var exampleTranslation: String?
    @State private var commonsThumb: URL?
    @State private var showExample = false
    @State private var isTranslating = true
    @State private var isLoadingDict = true
    @State private var isLoadingImage = true
    @State private var loadNote: String?
    @State private var isAdded = false
    @State private var isSaving = false
    @State private var speech = SpeechService()
    private let translator = TranslationService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusChips
            Divider().opacity(0.35)
            mainRow
            actionRow
            if let loadNote {
                Text(loadNote)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: word) { await load() }
        .onDisappear { speech.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(word)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
            if canSpeak {
                Button {
                    speech.speak(
                        word,
                        reading: transcription,
                        language: speakLanguage ?? store.profile.preferredLanguagePair.source
                    )
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.primary)
                .help(AppL10n.t("lookup.pronounce"))
            }
        }
    }

    @ViewBuilder
    private var statusChips: some View {
        let show = isTranslating || isLoadingDict || isLoadingImage
        if show {
            HStack(spacing: 6) {
                if isTranslating {
                    statusChip(AppL10n.t("lookup.status.translation"))
                }
                if isLoadingDict {
                    statusChip(AppL10n.t("lookup.status.dictionary"))
                }
                if isLoadingImage {
                    statusChip(AppL10n.t("lookup.status.image"))
                }
            }
        }
    }

    private func statusChip(_ title: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(title)
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.muted.opacity(0.55), in: Capsule())
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let transcription, !transcription.isEmpty {
                    Text(transcription)
                        .font(.callout.weight(.medium).monospaced())
                        .foregroundStyle(theme.primary)
                        .textSelection(.enabled)
                } else if isLoadingDict {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(AppL10n.t("lookup.status.transcription"))
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                if let translation, !translation.isEmpty {
                    Text(translation)
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isTranslating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(AppL10n.t("lookup.status.translation"))
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            wikiThumb
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let pos = partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines)
        let def = definition?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pos, !pos.isEmpty, let def, !def.isEmpty {
            Text("\(pos) · \(def)")
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        } else if let def, !def.isEmpty {
            Text(def)
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(3)
        } else if let pos, !pos.isEmpty {
            Text(pos)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.mutedForeground)
        }
    }

    @ViewBuilder
    private var wikiThumb: some View {
        if commonsThumb != nil || isLoadingImage {
            Group {
                if let commonsThumb {
                    AsyncImage(url: commonsThumb) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty:
                            ZStack {
                                theme.muted
                                ProgressView().controlSize(.mini)
                            }
                        case .failure:
                            Color.clear
                        @unknown default:
                            Color.clear
                        }
                    }
                } else {
                    ZStack {
                        theme.muted
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.4), lineWidth: 1)
            }
            .accessibilityLabel(AppL10n.t("lookup.wikiImage"))
        }
    }

    private func exampleBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let exampleTranslation, !exampleTranslation.isEmpty {
                    Text(exampleTranslation)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                speech.speak(
                    text,
                    reading: nil,
                    language: store.profile.preferredLanguagePair.source
                )
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(theme.primary)
            }
            .buttonStyle(.borderless)
            .help(AppL10n.t("lookup.pronounce"))
            .opacity(canSpeak ? 1 : 0)
            .disabled(!canSpeak)
            .accessibilityHidden(!canSpeak)
        }
        .padding(10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
        }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await addCard() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                    }
                    Text(isAdded ? AppL10n.t("lookup.added") : AppL10n.t("lookup.addCard"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isAdded ? theme.mutedForeground : theme.primary)
            .disabled(isAdded || isSaving)

            if let exampleSource, !exampleSource.isEmpty {
                DisclosureGroup(isExpanded: $showExample) {
                    exampleBubble(exampleSource)
                        .padding(.top, 6)
                } label: {
                    Text(AppL10n.t("lookup.example"))
                        .font(.subheadline.weight(.semibold))
                }
                .onChange(of: showExample) { _, open in
                    if open {
                        Task { await ensureExampleTranslation() }
                    }
                }
            }
        }
    }

    private func load() async {
        isTranslating = true
        isLoadingDict = true
        isLoadingImage = true
        loadNote = nil
        translation = nil
        cardWord = nil
        cardMeaning = nil
        speakLanguage = nil
        transcription = nil
        partOfSpeech = nil
        definition = nil
        exampleSource = segment.text
        exampleTranslation = nil
        showExample = false
        commonsThumb = nil

        let pair = store.profile.preferredLanguagePair
        isAdded = store.vocabulary.contains {
            $0.word.localizedCaseInsensitiveCompare(word) == .orderedSame
        }

        // Soft timeout: stop translation spinner after 2.5s even if Apple Translate is slow.
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if isTranslating { isTranslating = false }
        }

        // Prefer content→native; if the gloss is identical (clicked native text in a bilingual post),
        // fall back to native→study — shared with New Card / OCR / reading mode.
        let resolved = await translator.resolveStudyLookup(word, pair: pair)
        if let resolved {
            translation = resolved.gloss
            cardWord = resolved.cardWord
            cardMeaning = resolved.cardMeaning
            speakLanguage = resolved.speakLanguage
            isAdded = store.vocabulary.contains {
                $0.word.localizedCaseInsensitiveCompare(resolved.cardWord) == .orderedSame
            }
        }
        isTranslating = false

        let dictTerm = resolved?.cardWord ?? word
        let dictHint = pair.source

        async let defsTask: [WiktionaryDefinition] = {
            (try? await WiktionaryRESTClient.definitions(
                for: dictTerm,
                languageHint: dictHint
            )) ?? []
        }()
        async let ipaTask: [String] = {
            (try? await WiktionaryMediaWikiClient.ipaReadings(
                for: dictTerm,
                languageHint: dictHint
            )) ?? []
        }()
        async let commonsTask: URL? = {
            // Prefer sense from content language so FR «pour» ≠ EN “pour (liquid)”.
            let query = dictHint.lowercased().hasPrefix("en")
                ? dictTerm
                : "\(dictTerm) (\(dictHint))"
            let images = (try? await WikimediaCommonsClient.searchImages(query: query, limit: 1)) ?? []
            return images.first?.thumbURL ?? images.first?.fullURL
        }()

        let (defs, ipa) = await (defsTask, ipaTask)
        if let first = defs.first {
            // en.wiktionary glosses are English — localize POS + definition to the user's native language.
            let localized = await localizeDictionarySense(
                partOfSpeech: first.partOfSpeech,
                gloss: first.gloss,
                to: pair.target
            )
            partOfSpeech = nonempty(localized.pos)
            definition = nonempty(localized.gloss)
            if let ex = nonempty(first.example) {
                exampleSource = ex
            }
        }
        transcription = Self.cleanTranscription(ipa.first)
        isLoadingDict = false

        commonsThumb = await commonsTask
        isLoadingImage = false

        if translation != nil || definition != nil || transcription != nil {
            loadNote = nil
        } else {
            loadNote = AppL10n.t("lookup.limited")
        }
    }

    /// Wiktionary REST glosses are English; translate into the user's explanation language.
    private func localizeDictionarySense(
        partOfSpeech: String,
        gloss: String,
        to targetLanguage: String
    ) async -> (pos: String, gloss: String) {
        let target = targetLanguage.lowercased()
        if target.hasPrefix("en") {
            return (partOfSpeech, gloss)
        }
        async let posTask: String? = {
            let p = partOfSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return nil }
            return try? await translator.translate(p, from: "en", to: targetLanguage)
        }()
        async let glossTask: String? = {
            let g = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !g.isEmpty else { return nil }
            return try? await translator.translate(g, from: "en", to: targetLanguage)
        }()
        let (posLocalized, glossLocalized) = await (posTask, glossTask)
        return (
            nonempty(posLocalized) ?? partOfSpeech,
            nonempty(glossLocalized) ?? gloss
        )
    }

    private func ensureExampleTranslation() async {
        guard exampleTranslation == nil,
              let exampleSource,
              !exampleSource.isEmpty
        else { return }
        let pair = store.profile.preferredLanguagePair
        do {
            exampleTranslation = try await translator.translateFlexible(exampleSource, pair: pair)
        } catch {
            // Keep the source example visible even if gloss fails — never crash the popover.
            exampleTranslation = nil
            loadNote = AppL10n.t("lookup.limited")
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func nonempty(_ value: String) -> String? {
        nonempty(Optional(value))
    }

    /// Drop wiki-link crumbs that sometimes leak from Wiktionary IPA extraction.
    private static func cleanTranscription(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("[[") || t.contains("]]") || t.contains("|") && t.contains("#") { return nil }
        if t.hasPrefix("[[") || t.hasPrefix("w:") { return nil }
        return t
    }

    private func addCard() async {
        guard !isAdded else { return }
        isSaving = true
        defer { isSaving = false }
        let study = cardWord ?? word
        let meaning = cardMeaning ?? translation ?? definition ?? "—"
        let ok = await store.createManualCard(
            word: study,
            meaning: meaning,
            context: showExample ? exampleSource : segment.text,
            reading: transcription,
            packIDs: [],
            reversed: false
        )
        if ok { isAdded = true }
    }
}
