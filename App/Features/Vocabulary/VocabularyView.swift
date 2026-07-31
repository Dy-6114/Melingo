import SwiftUI
import Domain

struct VocabularyView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router
    @Environment(\.theme) private var theme
    @State private var speech = SpeechService()
    @State private var showReview = false
    @State private var showQuickAdd = false
    @State private var editing: VocabularyEntry?
    @State private var filter: VocabFilter = .all
    @State private var search = ""
    @State private var confirmDeletePair: VocabularyEntry?
    @State private var audioPlayers: [UUID: AudioPlayerBox] = [:]
    @State private var selectedID: UUID?
    @State private var showInspector = false

    /// When opened from sidebar smart filters.
    var smartFilter: SmartFilter? = nil

    private enum VocabFilter: String, CaseIterable, Identifiable {
        case all, due, new, learning, review, weak, suspended
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: AppL10n.t("vocab.filter.all")
            case .due: AppL10n.t("vocab.filter.due")
            case .new: AppL10n.t("vocab.filter.new")
            case .learning: AppL10n.t("vocab.filter.learning")
            case .review: AppL10n.t("vocab.filter.review")
            case .weak: AppL10n.t("smart.weak")
            case .suspended: AppL10n.t("vocab.filter.paused")
            }
        }
    }

    private var filterLocked: Bool { smartFilter != nil }

    private var filtered: [VocabularyEntry] {
        store.vocabulary.filter { entry in
            let matchesFilter: Bool = {
                switch filter {
                case .all: true
                case .due: VocabularyScheduling.isDue(entry)
                case .new: entry.srsState == .new && entry.suspendedAt == nil
                case .learning: entry.srsState == .learning && entry.suspendedAt == nil
                case .review: entry.srsState == .review && entry.suspendedAt == nil
                case .weak:
                    entry.suspendedAt == nil
                        && entry.srsState != .new
                        && VocabularyScheduling.currentRetrievability(entry) < 0.7
                case .suspended: entry.suspendedAt != nil
                }
            }()
            guard matchesFilter else { return false }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return entry.word.lowercased().contains(q)
                || entry.meaning.lowercased().contains(q)
                || (entry.reading?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !filterLocked {
                filterBar
            }
            if store.vocabulary.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(theme.mutedForeground.opacity(0.85))
                    Text(AppL10n.t("vocab.emptyTitle"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                    Text(AppL10n.t("vocab.emptyBody"))
                        .font(.body)
                        .foregroundStyle(theme.mutedForeground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button {
                        showQuickAdd = true
                    } label: {
                        Label(AppL10n.t("vocab.emptyCTA"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                list
            }
        }
        .background(theme.background)
        .navigationTitle(
            smartFilter.map { AppL10n.t($0.titleKey) } ?? AppL10n.t("sidebar.vocabulary")
        )
        .searchable(text: $search, prompt: AppL10n.t("vocab.search"))
        .onAppear {
            applySmartFilterIfNeeded()
        }
        .onChange(of: smartFilter) { _, _ in
            applySmartFilterIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQuickAdd = true
                } label: {
                    Label(AppL10n.t("vocab.addWord"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showReview = true
                } label: {
                    Label(
                        store.dueCount > 0
                            ? String(format: AppL10n.t("vocab.studyCount"), store.dueCount)
                            : AppL10n.t("vocab.study"),
                        systemImage: "rectangle.on.rectangle.angled"
                    )
                }
                .disabled(store.dueCount == 0)
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
        .sheet(isPresented: $showReview) {
            ReviewSessionView()
                .frame(minWidth: 640, minHeight: 520)
        }
        .sheet(isPresented: $showQuickAdd) {
            QuickAddWordSheet()
                .frame(minWidth: 420, minHeight: 240)
        }
        .sheet(item: $editing) { entry in
            VocabularyEditSheet(entry: entry, packs: store.packs) { word, meaning, reading, example, packIDs in
                Task {
                    await store.updateVocabulary(
                        entry.id,
                        word: word,
                        meaning: meaning,
                        reading: reading,
                        example: example,
                        packIDs: packIDs
                    )
                }
            }
        }
        .confirmationDialog(
            AppL10n.t("vocab.deletePairConfirm"),
            isPresented: Binding(
                get: { confirmDeletePair != nil },
                set: { if !$0 { confirmDeletePair = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppL10n.t("vocab.deletePair"), role: .destructive) {
                if let entry = confirmDeletePair {
                    Task { await store.deleteVocabulary(entry.id, deletePair: true) }
                }
                confirmDeletePair = nil
            }
            Button(AppL10n.t("vocab.delete"), role: .destructive) {
                if let entry = confirmDeletePair {
                    Task { await store.deleteVocabulary(entry.id) }
                }
                confirmDeletePair = nil
            }
            Button(AppL10n.t("study.exitConfirm.stay"), role: .cancel) {
                confirmDeletePair = nil
            }
        }
        .inspector(isPresented: $showInspector) {
            if let entryID = selectedID {
                VocabularyEntryInspector(
                    entryID: entryID,
                    onEdit: {
                        if let entry = store.vocabulary.first(where: { $0.id == entryID }) {
                            editing = entry
                        }
                    },
                    onDismiss: {
                        showInspector = false
                        selectedID = nil
                        router.focusedVocabularyID = nil
                    }
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            } else {
                WorkspaceChrome.EmptyState(
                    systemImage: "sidebar.trailing",
                    title: AppL10n.t("inspector.missing"),
                    message: AppL10n.t("inspector.missingHint")
                )
            }
        }
        .onAppear {
            if let focused = router.focusedVocabularyID {
                selectedID = focused
                showInspector = true
            }
        }
        .onChange(of: router.focusedVocabularyID) { _, id in
            guard let id else { return }
            selectedID = id
            showInspector = true
        }
    }

    private func applySmartFilterIfNeeded() {
        guard let smartFilter else { return }
        switch smartFilter {
        case .due: filter = .due
        case .new: filter = .new
        case .weak: filter = .weak
        case .suspended: filter = .suspended
        }
    }

    private var filterBar: some View {
        ViewThatFits {
            Picker(selection: $filter) {
                ForEach(VocabFilter.allCases) { Text($0.title).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker(selection: $filter) {
                ForEach(VocabFilter.allCases) { Text($0.title).tag($0) }
            } label: {
                Label(filter.title, systemImage: "line.3.horizontal.decrease.circle")
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(filtered) { entry in
                vocabRow(entry)
                    .tag(entry.id)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onChange(of: selectedID) { _, id in
            showInspector = id != nil
            router.focusedVocabularyID = id
        }
    }

    private func vocabRow(_ entry: VocabularyEntry) -> some View {
        HStack(spacing: 12) {
            MemoryRing(strength: VocabularyScheduling.currentRetrievability(entry))
                .frame(width: 32, height: 32)

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
                    Spacer()
                    stateChip(entry)
                }
                Text(entry.meaning)
                    .font(.body)
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 8) {
                    if let source = entry.sourceDocumentTitle {
                        Text(source).font(.caption).foregroundStyle(theme.mutedForeground)
                    }
                    if !entry.dueDate.isEmpty {
                        Text(entry.dueDate)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
            }

            if entry.audioRelativePath != nil {
                Button {
                    playAudio(entry)
                } label: {
                    Image(systemName: "waveform.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.primary)
            }

            Button {
                speech.speak(
                    entry.word,
                    reading: entry.reading,
                    language: entry.languagePair.source
                )
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.primary)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .fill(.regularMaterial)
            if selectedID == entry.id {
                RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                    .fill(theme.primary.opacity(0.12))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(
                    selectedID == entry.id ? theme.primary.opacity(0.55) : theme.border.opacity(0.25),
                    lineWidth: selectedID == entry.id ? 1.5 : 1
                )
        }
        .contentShape(Rectangle())
        .draggable(VocabularyTransfer(id: entry.id))
        .contextMenu {
            Button(AppL10n.t("vocab.edit")) { editing = entry }
            Button(entry.suspendedAt == nil ? AppL10n.t("vocab.pause") : AppL10n.t("vocab.resume")) {
                Task { await store.suspendVocabulary(entry.id, suspend: entry.suspendedAt == nil) }
            }
            Button(AppL10n.t("vocab.delete"), role: .destructive) {
                if entry.pairID != nil {
                    confirmDeletePair = entry
                } else {
                    Task { await store.deleteVocabulary(entry.id) }
                }
            }
        }
    }

    private func playAudio(_ entry: VocabularyEntry) {
        guard let url = store.absoluteAudioURL(for: entry) else { return }
        let box = AudioPlayerBox(url: url)
        audioPlayers[entry.id] = box
        box.play()
    }

    private func stateChip(_ entry: VocabularyEntry) -> some View {
        let label: String
        let color: Color
        if entry.suspendedAt != nil {
            label = AppL10n.t("vocab.filter.paused")
            color = theme.mutedForeground
        } else if VocabularyScheduling.isDue(entry) {
            label = AppL10n.t("vocab.filter.due")
            color = theme.srsFading
        } else {
            switch entry.srsState {
            case .new: label = AppL10n.t("vocab.filter.new")
            case .learning: label = AppL10n.t("vocab.filter.learning")
            case .review: label = AppL10n.t("vocab.filter.review")
            }
            color = theme.mutedForeground
        }
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Fast path: add one word without requiring a full sentence or example.
struct QuickAddWordSheet: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var word = ""
    @State private var meaning = ""
    @State private var isTranslating = false
    @State private var isSaving = false
    @State private var note: String?

    private let translator = TranslationService()

    private var canSave: Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Word", text: $word)
                    .onSubmit { Task { await ensureMeaning() } }
                TextField("Meaning (optional — auto-translates)", text: $meaning, axis: .vertical)
                if let note {
                    Text(note).font(.caption).foregroundStyle(theme.mutedForeground)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(AppL10n.t("vocab.addWord"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving || isTranslating)
                }
            }
        }
        .tint(theme.primary)
    }

    private func ensureMeaning() async {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isTranslating = true
        defer { isTranslating = false }
        let pair = store.profile.preferredLanguagePair
        if let resolved = await translator.resolveStudyLookup(trimmed, pair: pair) {
            if resolved.inputWasNative {
                word = resolved.cardWord
                meaning = resolved.cardMeaning
                note = "Translated from native → study"
            } else {
                meaning = resolved.gloss
                note = "Translated with Apple Translation"
            }
        } else {
            note = "Add a meaning manually — translation unavailable."
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        await ensureMeaning()
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMeaning.isEmpty {
            trimmedMeaning = trimmedWord
        }
        let ok = await store.createManualCard(
            word: trimmedWord,
            meaning: trimmedMeaning,
            context: nil,
            packIDs: [],
            reversed: false
        )
        if ok {
            dismiss()
        } else {
            note = store.lastError
        }
    }
}

struct VocabularyEditSheet: View {
    @Environment(\.theme) private var theme
    let entry: VocabularyEntry
    let packs: [WordPack]
    let onSave: (String, String, String?, String?, [UUID]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var word: String
    @State private var meaning: String
    @State private var reading: String
    @State private var example: String
    @State private var selectedTagIDs: Set<UUID>
    @State private var selectedPackID: UUID?

    private var tagPacks: [WordPack] { packs.filter { $0.kind == .tag } }
    private var learningPacks: [WordPack] { packs.filter { $0.kind == .learningPack && !$0.isSystem } }

    init(
        entry: VocabularyEntry,
        packs: [WordPack],
        onSave: @escaping (String, String, String?, String?, [UUID]) -> Void
    ) {
        self.entry = entry
        self.packs = packs
        self.onSave = onSave
        _word = State(initialValue: entry.word)
        _meaning = State(initialValue: entry.meaning)
        _reading = State(initialValue: entry.reading ?? "")
        _example = State(initialValue: entry.example ?? "")
        let tags = Set(entry.packIDs.filter { id in packs.contains { $0.id == id && $0.kind == .tag } })
        _selectedTagIDs = State(initialValue: tags)
        _selectedPackID = State(initialValue: entry.packIDs.first { id in
            packs.contains { $0.id == id && $0.kind == .learningPack }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(AppL10n.t("vocab.edit.word"), text: $word)
                TextField(AppL10n.t("vocab.edit.reading"), text: $reading)
                TextField(AppL10n.t("vocab.edit.meaning"), text: $meaning, axis: .vertical)
                TextField(AppL10n.t("vocab.edit.example"), text: $example, axis: .vertical)

                Section(AppL10n.t("newcard.tags")) {
                    FlowChips {
                        ForEach(tagPacks) { tag in
                            let on = selectedTagIDs.contains(tag.id)
                            Button {
                                if on { selectedTagIDs.remove(tag.id) }
                                else { selectedTagIDs.insert(tag.id) }
                            } label: {
                                Text(tag.name)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        on ? theme.primary.opacity(0.16) : theme.muted.opacity(0.55),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(AppL10n.t("newcard.pack")) {
                    Picker(AppL10n.t("newcard.pack"), selection: $selectedPackID) {
                        Text(AppL10n.t("newcard.ungrouped")).tag(UUID?.none)
                        ForEach(learningPacks) { pack in
                            Text(pack.name).tag(Optional(pack.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(AppL10n.t("vocab.edit.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppL10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppL10n.t("common.save")) {
                        var ids = Array(selectedTagIDs)
                        if let selectedPackID { ids.append(selectedPackID) }
                        onSave(
                            word,
                            meaning,
                            reading.isEmpty ? nil : reading,
                            example.isEmpty ? nil : example,
                            ids
                        )
                        dismiss()
                    }
                    .disabled(
                        word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .tint(theme.primary)
    }
}
