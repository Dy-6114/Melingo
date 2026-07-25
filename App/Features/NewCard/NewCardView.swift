import SwiftUI
import Domain

/// Manual vocabulary card creation: word + meaning (with optional force-translate),
/// Wiktionary definition/IPA hints, optional context / tags / voice. Cards are stored
/// L2→L1; Study reviews them as queued — no separate direction picker.
struct NewCardView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var word = ""
    @State private var meaning = ""
    @State private var context = ""
    @State private var reading = ""
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var selectedPackID: UUID?

    @State private var isTranslating = false
    @State private var translationNote: String?

    @State private var isLookingUp = false
    @State private var definitions: [WiktionaryDefinition] = []
    @State private var ipaReadings: [String] = []
    @State private var lookupError: String?

    @State private var recorder = VoiceRecorderService()
    @State private var isRecording = false
    @State private var showTrim = false
    @State private var keptAudioURL: URL?

    @State private var isSaving = false
    @State private var saveMessage: String?

    private let translator = TranslationService()

    private var tagPacks: [WordPack] {
        store.packs.filter { $0.kind == .tag }.sorted { $0.name < $1.name }
    }

    /// Learning packs excluding system Ungrouped (shown once as a chip).
    private var learningPacks: [WordPack] {
        store.packs
            .filter { $0.kind == .learningPack && $0.id != WordPack.systemUngroupedID }
            .sorted { $0.name < $1.name }
    }

    private var canSave: Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @State private var showMoreOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                wordSection
                meaningSection

                DisclosureGroup(isExpanded: $showMoreOptions) {
                    VStack(alignment: .leading, spacing: 28) {
                        contextSection
                        tagsSection
                        voiceSection
                    }
                    .padding(.top, 12)
                } label: {
                    Text(AppL10n.t("newcard.more"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.mutedForeground)
                }

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(AppL10n.t("newcard.create"))
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .controlSize(.large)
                .disabled(isSaving || isTranslating || !canSave)
                .keyboardShortcut(.return, modifiers: .command)

                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(theme.background)
        .navigationTitle(AppL10n.t("newcard.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppL10n.t("newcard.create"), systemImage: "plus.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(isSaving || isTranslating || !canSave)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { Task { await consumeServiceTextIfNeeded() } }
        .onReceive(NotificationCenter.default.publisher(for: .melingoOpenNewCardFromService)) { note in
            if let text = note.object as? String {
                Task { await applyServiceText(text) }
            } else {
                Task { await consumeServiceTextIfNeeded() }
            }
        }
    }

    private func consumeServiceTextIfNeeded() async {
        if let pending = MelingoServicesInbox.shared.consume() {
            await applyServiceText(pending)
        }
    }

    private func applyServiceText(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        word = trimmed
        meaning = ""
        translationNote = nil
        isTranslating = true
        defer { isTranslating = false }
        let pair = store.profile.preferredLanguagePair
        if let gloss = try? await translator.translate(trimmed, from: pair.source, to: pair.target),
           !gloss.isEmpty,
           gloss.localizedCaseInsensitiveCompare(trimmed) != .orderedSame {
            meaning = gloss
        } else if let study = try? await translator.translate(trimmed, from: pair.target, to: pair.source),
                  !study.isEmpty,
                  study.localizedCaseInsensitiveCompare(trimmed) != .orderedSame {
            meaning = trimmed
            word = study
        }
    }

    // MARK: - Word

    private var wordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ThemeChrome.sectionLabel(AppL10n.t("newcard.word"))
                Text(AppL10n.t("newcard.required"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.primary)
            }
            HStack(spacing: 10) {
                TextField(AppL10n.t("newcard.wordPlaceholder"), text: $word)
                    .okField()
                    .onSubmit { Task { await lookUpWiktionary() } }
                Button {
                    Task { await lookUpWiktionary() }
                } label: {
                    if isLookingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppL10n.t("newcard.lookup"), systemImage: "text.book.closed")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isLookingUp || word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !ipaReadings.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ipaReadings, id: \.self) { ipa in
                            Button {
                                reading = ipa
                            } label: {
                                Text(ipa)
                                    .font(.caption.monospaced())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            TextField(AppL10n.t("newcard.readingPlaceholder"), text: $reading)
                .okField()

            if !definitions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(definitions.prefix(5).enumerated()), id: \.offset) { _, def in
                        Button {
                            Task { await applyWikiGloss(def.gloss) }
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                if !def.partOfSpeech.isEmpty {
                                    Text(def.partOfSpeech)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(theme.mutedForeground)
                                }
                                Text(def.gloss)
                                    .font(.caption)
                                    .foregroundStyle(theme.foreground)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.field, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.field, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.4), lineWidth: 1)
                }
            }

            if let lookupError {
                Text(lookupError)
                    .font(.caption)
                    .foregroundStyle(theme.destructive)
            }
        }
    }

    private func lookUpWiktionary() async {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        do {
            async let defs = WiktionaryRESTClient.definitions(
                for: term,
                languageHint: store.profile.preferredLanguagePair.source
            )
            async let ipas = WiktionaryMediaWikiClient.ipaReadings(
                for: term,
                languageHint: store.profile.preferredLanguagePair.source
            )
            definitions = try await defs
            ipaReadings = try await ipas
            lookupError = definitions.isEmpty && ipaReadings.isEmpty
                ? AppL10n.t("newcard.wikiNone")
                : nil
        } catch {
            definitions = []
            ipaReadings = []
            lookupError = AppL10n.t("newcard.wikiFail")
        }
    }

    // MARK: - Meaning

    private var meaningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ThemeChrome.sectionLabel(AppL10n.t("newcard.meaning"))
                Text(AppL10n.t("newcard.autoOrManual"))
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
            }
            HStack(alignment: .top, spacing: 10) {
                TextField(AppL10n.t("newcard.meaningPlaceholder"), text: $meaning, axis: .vertical)
                    .okField(minHeight: 56)
                    .lineLimit(2...4)
                Button {
                    Task { await forceTranslate() }
                } label: {
                    if isTranslating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppL10n.t("newcard.translate"), systemImage: "globe")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isTranslating || word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(AppL10n.t("newcard.translateHelp"))
            }
            if let translationNote {
                Text(translationNote)
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    /// Wiktionary REST glosses are English — localize into the user's L1 before filling meaning.
    private func applyWikiGloss(_ gloss: String) async {
        guard meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let trimmed = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = store.profile.preferredLanguagePair.target
        if target.lowercased().hasPrefix("en") {
            meaning = trimmed
            return
        }
        if let localized = try? await translator.translate(trimmed, from: "en", to: target),
           !localized.isEmpty {
            meaning = localized
        } else {
            meaning = trimmed
        }
    }

    private func forceTranslate() async {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isTranslating = true
        defer { isTranslating = false }
        let pair = store.profile.preferredLanguagePair
        translationNote = nil

        // Path A — classic: Слово = L2 → Значение = L1 gloss
        if let gloss = try? await translator.translate(term, from: pair.source, to: pair.target),
           !gloss.isEmpty,
           !Self.sameIgnoringCase(gloss, term) {
            meaning = gloss
            return
        }

        // Path B — native typed in Слово: L1 → L2, then swap into card sides
        // (e.g. «Чёрт» → word=diable / diable…, meaning=Чёрт)
        if let study = try? await translator.translate(term, from: pair.target, to: pair.source),
           !study.isEmpty,
           !Self.sameIgnoringCase(study, term) {
            meaning = term
            word = study
            translationNote = AppL10n.t("newcard.translatedFromNative")
            // Refresh wiki for the new L2 headword
            Task { await lookUpWiktionary() }
            return
        }

        translationNote = AppL10n.t("newcard.translationUnavailable")
    }

    private static func sameIgnoringCase(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(
                b.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }

    // MARK: - Context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThemeChrome.sectionLabel(AppL10n.t("newcard.context"))
            TextField(AppL10n.t("newcard.contextPlaceholder"), text: $context, axis: .vertical)
                .okField(minHeight: 72)
                .lineLimit(2...5)
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThemeChrome.sectionLabel(AppL10n.t("newcard.tags"))
            FlowChips {
                ForEach(tagPacks) { tag in
                    let style = TagStyleStore.style(for: tag.id)
                    chip(
                        title: tag.name,
                        isSelected: selectedTagIDs.contains(tag.id),
                        accent: Color(hex: style.colorHex),
                        symbol: style.symbolName
                    ) {
                        if selectedTagIDs.contains(tag.id) {
                            selectedTagIDs.remove(tag.id)
                        } else {
                            selectedTagIDs.insert(tag.id)
                        }
                    }
                }
            }

            ThemeChrome.sectionLabel(AppL10n.t("newcard.pack"))
            FlowChips {
                chip(title: AppL10n.t("newcard.ungrouped"), isSelected: selectedPackID == nil) {
                    selectedPackID = nil
                }
                ForEach(learningPacks) { pack in
                    chip(title: pack.name, isSelected: selectedPackID == pack.id) {
                        selectedPackID = pack.id
                    }
                }
            }
        }
    }

    private func chip(title: String, isSelected: Bool, accent: Color? = nil, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.caption)
                }
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? (accent ?? theme.primary).opacity(0.16) : theme.muted.opacity(0.55),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? (accent ?? theme.primary) : theme.mutedForeground)
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? (accent ?? theme.primary).opacity(0.5) : .clear,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThemeChrome.sectionLabel(AppL10n.t("newcard.pronunciation"))

            if showTrim {
                VoiceTrimView(
                    recorder: recorder,
                    onKeep: { url in
                        keptAudioURL = url
                        showTrim = false
                    },
                    onDiscard: {
                        keptAudioURL = nil
                        showTrim = false
                    }
                )
            } else if let keptAudioURL {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(theme.primary)
                    Text(keptAudioURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(1)
                    Spacer()
                    Button(AppL10n.t("newcard.rerecord")) {
                        self.keptAudioURL = nil
                        startRecording()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    if isRecording {
                        recorder.stop()
                        isRecording = false
                        showTrim = true
                    } else {
                        startRecording()
                    }
                } label: {
                    Label(
                        isRecording ? AppL10n.t("newcard.stopRecord") : AppL10n.t("newcard.record"),
                        systemImage: isRecording ? "stop.circle.fill" : "mic.circle"
                    )
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? theme.destructive : theme.primary)
            }

            if recorder.permissionDenied {
                Text(AppL10n.t("newcard.micDenied"))
                    .font(.caption)
                    .foregroundStyle(theme.destructive)
            }
        }
    }

    private func startRecording() {
        Task {
            let granted = await recorder.requestPermission()
            guard granted else { return }
            do {
                try recorder.start()
                isRecording = true
            } catch {
                isRecording = false
            }
        }
    }

    // MARK: - Save

    private func ensureMeaning() async {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isTranslating = true
        defer { isTranslating = false }
        let pair = store.profile.preferredLanguagePair
        // Prefer L2→L1; if that echoes, try treating input as L1.
        if let gloss = try? await translator.translate(trimmed, from: pair.source, to: pair.target),
           !gloss.isEmpty,
           !Self.sameIgnoringCase(gloss, trimmed) {
            meaning = gloss
            translationNote = AppL10n.t("newcard.translatedNote")
            return
        }
        if let study = try? await translator.translate(trimmed, from: pair.target, to: pair.source),
           !study.isEmpty,
           !Self.sameIgnoringCase(study, trimmed) {
            meaning = trimmed
            word = study
            translationNote = AppL10n.t("newcard.translatedFromNative")
            return
        }
        translationNote = AppL10n.t("newcard.meaningManual")
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        await ensureMeaning()
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty, !trimmedMeaning.isEmpty,
              !Self.sameIgnoringCase(trimmedWord, trimmedMeaning) else {
            saveMessage = AppL10n.t("newcard.needTranslation")
            return
        }
        let packIDs = selectedPackID.map { [$0] } ?? []
        let ok = await store.createManualCard(
            word: trimmedWord,
            meaning: trimmedMeaning,
            context: context.isEmpty ? nil : context,
            reading: reading.isEmpty ? nil : reading,
            packIDs: packIDs + Array(selectedTagIDs),
            reversed: false,
            alsoCreateReverse: false,
            audioURL: keptAudioURL
        )
        if ok {
            saveMessage = AppL10n.t("newcard.created")
            word = ""
            meaning = ""
            context = ""
            reading = ""
            selectedTagIDs = []
            selectedPackID = nil
            keptAudioURL = nil
            definitions = []
            ipaReadings = []
            translationNote = nil
        } else {
            saveMessage = store.lastError
        }
    }
}

/// Simple wrapping HStack for chip collections (macOS `Layout`).
struct FlowChips: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
