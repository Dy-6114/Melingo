import AppKit
import SwiftUI
import Domain

enum ReaderViewMode: String, CaseIterable, Identifiable {
    case original, bilingual, translation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: AppL10n.t("reader.original")
        case .bilingual: AppL10n.t("reader.bilingual")
        case .translation: AppL10n.t("reader.translation")
        }
    }
}

/// Active word chip selection (stays in word mode when switching words).
private struct SelectedWordChip: Identifiable, Hashable {
    var id: String { tokenID }
    var tokenID: String
    var word: String
    var segmentID: UUID
    /// Tokenizer index — used to order multi-selection and span phrases.
    var tokenIndex: Int
}

/// Stable popover payload — capturing the segment snapshot avoids empty-popover dismiss races.
private struct WordLookupTarget: Identifiable {
    var id: String { tokenID }
    var tokenID: String
    var word: String
    var segment: TextSegment
}

struct ReaderView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let document: Document
    /// When set (e.g. EPUB study mode), closes back to the previous view instead of popping navigation.
    var onClose: (() -> Void)? = nil

    @State private var mode: ReaderViewMode = .original
    @State private var selected: TextSegment?
    @State private var breakdown: GrammarBreakdown?
    @State private var question = ""
    @State private var answer: String?
    @State private var readingStart: Date?
    @State private var speech = SpeechService()
    @State private var showReadingLine = true
    /// Only recognized (lexical) words are clickable; chrome appears on hover/select — not on every word.
    @State private var wordChipMode = true
    /// Ordered multi-selection within one segment. Count == 1 → word in inspector; ≥ 2 → Explain bar.
    @State private var selectedWords: [SelectedWordChip] = []
    @State private var lookupTarget: WordLookupTarget?
    @State private var isExplainingPhrase = false
    @State private var phraseExpanded = false
    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.showInspector") private var showInspector = true

    private var canSpeakSource: Bool {
        SpeechService.canSpeak(language: store.profile.preferredLanguagePair.source)
    }

    private var multiSelectPhrase: String? {
        guard selectedWords.count >= 2,
              let segmentID = selectedWords.first?.segmentID,
              let segment = segments.first(where: { $0.id == segmentID }) ?? selected
        else { return nil }
        return phrase(from: selectedWords, in: segment)
    }

    private var segments: [TextSegment] {
        store.segments(for: document.id)
    }

    private var paragraphs: [[TextSegment]] {
        var result: [[TextSegment]] = []
        for segment in segments {
            if segment.isNewParagraph || result.isEmpty {
                result.append([segment])
            } else {
                result[result.count - 1].append(segment)
            }
        }
        return result
    }

    private var illustrations: [ArticleIllustration] {
        store.illustrations(for: document.id)
    }

    private var heroIllustration: ArticleIllustration? {
        illustrations.first { $0.afterParagraphIndex < 0 } ?? illustrations.first
    }

    private func scenes(afterParagraph index: Int) -> [ArticleIllustration] {
        illustrations.filter { $0.afterParagraphIndex == index && $0.id != heroIllustration?.id }
    }

    private var selectedIndex: Int? {
        guard let selected else { return nil }
        return segments.firstIndex(where: { $0.id == selected.id })
    }

    /// Fresh segment from the store (picks up reading/translation updates).
    private var liveSelected: TextSegment? {
        guard let selected else { return nil }
        return segments.first { $0.id == selected.id } ?? selected
    }

    var body: some View {
        VStack(spacing: 0) {
            if let state = store.batchByDocument[document.id] {
                batchProgressBar(state)
            }
            // AppKit NSScrollView — SwiftUI ScrollView swallows word/sentence clicks on macOS.
            GeometryReader { geo in
                ReaderAppKitScroll(
                    segments: segments,
                    mode: mode,
                    wordChipMode: wordChipMode,
                    fontSize: fontSize,
                    showReadingLine: showReadingLine,
                    languageHint: store.profile.preferredLanguagePair.source,
                    selectedSegmentID: selected?.id,
                    selectedWordIDs: Set(
                        selectedWords.map(\.tokenID) + (lookupTarget.map { [$0.tokenID] } ?? [])
                    ),
                    canvasWidth: geo.size.width,
                    canvasHeight: geo.size.height,
                    onSelectSegment: { select($0) },
                    onWordTap: { token, segment, additive in
                        let chip = SelectedWordChip(
                            tokenID: token.id,
                            word: token.text,
                            segmentID: segment.id,
                            tokenIndex: token.index
                        )
                        handleWordTap(chip, segment: segment, additive: additive)
                        if !additive {
                            showInspector = true
                            lookupTarget = WordLookupTarget(
                                tokenID: token.id,
                                word: token.text,
                                segment: segment
                            )
                        } else {
                            lookupTarget = nil
                        }
                    }
                )
            }
            .background(theme.background)
            .frame(minWidth: 480)
        }
        .overlay(alignment: .bottom) {
            if let phrase = multiSelectPhrase {
                phraseExplainBar(phrase: phrase)
                    .padding(.bottom, 16)
                    .fixedSize(horizontal: true, vertical: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: lookupTarget?.id)
        .animation(.easeInOut(duration: 0.2), value: selectedWords.count)
        .inspector(isPresented: $showInspector) {
            Group {
                if let target = lookupTarget {
                    wordLookupInspector(for: target)
                } else {
                    ExplanationPanel(
                        segment: liveSelected,
                        breakdown: breakdown,
                        isBusy: liveSelected.map { store.explainingSegmentIDs.contains($0.id) } ?? false,
                        canSpeak: canSpeakSource,
                        wordChipMode: wordChipMode,
                        question: $question,
                        answer: answer,
                        onExplain: {
                            guard let selected else { return }
                            breakdown = await store.explain(segment: selected)
                            refreshSelection()
                        },
                        onTranslate: {
                            guard let selected else { return }
                            showInspector = true
                            await store.translate(segment: selected)
                            refreshSelection()
                        },
                        onReading: {
                            guard let selected else { return }
                            await store.generateReading(segment: selected, force: true)
                            refreshSelection()
                        },
                        onAsk: {
                            guard let selected else { return }
                            answer = ""
                            answer = await store.askStreaming(question: question, about: selected) { chunk in
                                answer = (answer ?? "") + chunk
                            }
                        },
                        onCancelAsk: {
                            store.cancelAsk()
                        },
                        onSpeak: { segment in
                            speech.speak(
                                segment.text,
                                reading: segment.readingText,
                                language: store.profile.preferredLanguagePair.source
                            )
                        }
                    )
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .alert(
            AppL10n.t("reader.fallbackTitle"),
            isPresented: Binding(
                get: { store.pendingFallback != nil },
                set: { if !$0 { store.dismissFallbackPrompt() } }
            )
        ) {
            Button(AppL10n.t("reader.cancel"), role: .cancel) { store.dismissFallbackPrompt() }
            Button(AppL10n.t("reader.fallbackUse")) {
                guard let selected else { return }
                Task {
                    breakdown = await store.confirmFallbackAndRetryExplain(segment: selected)
                    refreshSelection()
                }
            }
        } message: {
            if let pending = store.pendingFallback {
                Text(String(format: AppL10n.t("reader.fallbackMessage"), pending.preferred, pending.fallback))
            }
        }
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    closeReader()
                } label: {
                    Image(systemName: "xmark")
                }
                .help(AppL10n.t("common.close"))
                .accessibilityLabel(AppL10n.t("common.close"))
            }
            ToolbarItemGroup {
                let progress = store.progress(for: document.id)
                let running = store.isBatchRunning(documentID: document.id)
                Menu {
                    Button {
                        store.batchExplainAll(documentID: document.id)
                    } label: {
                        Label(AppL10n.t("reader.batchExplain"), systemImage: "sparkles")
                    }
                    .disabled(running || progress.explained >= progress.total)
                    Button {
                        store.batchTranslateAll(documentID: document.id)
                    } label: {
                        Label(AppL10n.t("reader.batchTranslate"), systemImage: "character.book.closed")
                    }
                    .disabled(running || progress.translated >= progress.total)
                    if running {
                        Divider()
                        Button(AppL10n.t("reader.batchCancel"), role: .destructive) {
                            store.cancelBatch(documentID: document.id)
                        }
                    }
                } label: {
                    Label(AppL10n.t("reader.batch"), systemImage: "ellipsis.circle")
                }
                .help(AppL10n.t("reader.batch"))

                ViewThatFits(in: .horizontal) {
                    Picker(AppL10n.t("reader.mode"), selection: $mode) {
                        ForEach(ReaderViewMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()

                    Picker(AppL10n.t("reader.mode"), selection: $mode) {
                        ForEach(ReaderViewMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .accessibilityLabel(AppL10n.t("reader.mode"))

                Toggle(isOn: $showInspector) {
                    Image(systemName: "sidebar.trailing")
                }
                .toggleStyle(.button)
                .help(AppL10n.t("reader.inspector"))

                Toggle(isOn: $showReadingLine) {
                    Image(systemName: "textformat.abc.dottedunderline")
                }
                .toggleStyle(.button)
                .help(AppL10n.t("reader.readingLine"))
                Toggle(isOn: $wordChipMode) {
                    Image(systemName: "character.textbox")
                }
                .toggleStyle(.button)
                .help(AppL10n.t("reader.wordChips"))
                .onChange(of: wordChipMode) { _, enabled in
                    if !enabled {
                        clearWordSelection()
                    }
                }
                if canSpeakSource {
                    Button {
                        if let selected {
                            speech.speak(
                                selected.text,
                                reading: selected.readingText,
                                language: store.profile.preferredLanguagePair.source
                            )
                        }
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .disabled(selected == nil)
                    .help(AppL10n.t("reader.speak"))
                }
                Slider(value: $fontSize, in: 14...28, step: 1)
                    .frame(width: 100)
                    .help(AppL10n.t("reader.textSize"))
            }
        }
        .focusable()
        .onKeyPress(.escape) {
            if lookupTarget != nil || !selectedWords.isEmpty {
                clearWordSelection()
                return .handled
            }
            closeReader()
            return .handled
        }
        .onExitCommand {
            if lookupTarget != nil || !selectedWords.isEmpty {
                clearWordSelection()
            } else {
                closeReader()
            }
        }
        .onKeyPress(.leftArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { _ in
            guard canSpeakSource, let selected else { return .ignored }
            speech.speak(
                selected.text,
                reading: selected.readingText,
                language: store.profile.preferredLanguagePair.source
            )
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "eE")) { _ in
            guard let selected, !store.explainingSegmentIDs.contains(selected.id) else {
                return .ignored
            }
            Task {
                breakdown = await store.explain(segment: selected)
                refreshSelection()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "tT")) { _ in
            guard let selected else { return .ignored }
            Task {
                await store.translate(segment: selected)
                refreshSelection()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in
            guard let selected, !store.explainingSegmentIDs.contains(selected.id) else {
                return .ignored
            }
            Task {
                await store.generateReading(segment: selected, force: true)
                refreshSelection()
            }
            return .handled
        }
        .onAppear {
            if readingStart == nil { readingStart = Date() }
            ReaderWindowSizing.expandForReader()
        }
        .onDisappear {
            speech.stop()
            flushReading(restart: false)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                flushReading(restart: true)
            case .active:
                if readingStart == nil { readingStart = Date() }
            @unknown default:
                break
            }
        }
        // Translation is lazy: only the selected sentence is translated (see `select`).
    }

    @ViewBuilder
    private var readerBody: some View {
        if let hero = heroIllustration {
            SceneMomentView(
                illustration: hero,
                localURL: store.sceneImageURL(for: document.id, illustrationID: hero.id),
                isHero: true
            )
            .padding(.bottom, 4)
        }
        ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
            paragraphBlock(paragraph)
            ForEach(scenes(afterParagraph: index)) { scene in
                SceneMomentView(
                    illustration: scene,
                    localURL: store.sceneImageURL(for: document.id, illustrationID: scene.id),
                    isHero: false
                )
                .padding(.vertical, 6)
            }
        }
    }

    private func closeReader() {
        speech.stop()
        flushReading(restart: false)
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func wordLookupInspector(for target: WordLookupTarget) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppL10n.t("lookup.translation"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                Spacer(minLength: 0)
                Button {
                    lookupTarget = nil
                    if selectedWords.count == 1 { clearWordSelection() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .help(AppL10n.t("error.dismiss"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                WordLookupPopover(
                    word: target.word,
                    segment: target.segment,
                    documentTitle: document.title,
                    canSpeak: canSpeakSource
                )
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.card)
    }

    @ViewBuilder
    private func paragraphBlock(_ paragraph: [TextSegment]) -> some View {
        switch mode {
        case .original:
            if wordChipMode {
                wordChipParagraph(paragraph)
            } else {
                VStack(alignment: .leading, spacing: CGFloat(fontSize) * 0.65) {
                    ForEach(paragraph) { segment in
                        SentenceStateChip(
                            text: segment.text,
                            reading: segment.readingText,
                            showReading: showReadingLine,
                            fontSize: fontSize,
                            isSelected: selected?.id == segment.id,
                            hasTranslation: segment.translation != nil,
                            hasExplanation: segment.explanation != nil,
                            action: { select(segment) }
                        )
                        .id(segment.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { segmentMenu(segment) }
                    }
                }
            }
        case .bilingual:
            VStack(alignment: .leading, spacing: CGFloat(fontSize) * 0.9) {
                ForEach(paragraph) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        if wordChipMode {
                            wordChipLine(segment)
                        } else {
                            SentenceStateChip(
                                text: segment.text,
                                reading: segment.readingText,
                                showReading: showReadingLine,
                                fontSize: fontSize,
                                isSelected: selected?.id == segment.id,
                                hasTranslation: segment.translation != nil,
                                hasExplanation: segment.explanation != nil,
                                action: { select(segment) }
                            )
                            .id(segment.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu { segmentMenu(segment) }
                        }
                        translationLine(for: segment)
                    }
                    .padding(.vertical, 4)
                }
            }
        case .translation:
            VStack(alignment: .leading, spacing: CGFloat(fontSize) * 0.55) {
                ForEach(paragraph) { segment in
                    translationOnlyLine(segment)
                }
            }
        }
    }

    @ViewBuilder
    private func translationLine(for segment: TextSegment) -> some View {
        if let translation = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            Text(translation)
                .font(.system(size: fontSize * 0.88))
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.border)
                        .frame(width: 2)
                }
                .padding(.leading, 6)
        } else if store.explainingSegmentIDs.contains(segment.id)
                    || (selected?.id == segment.id && store.isBatchRunning(documentID: document.id)) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AppL10n.t("reader.translating"))
                    .font(.system(size: fontSize * 0.8))
                    .foregroundStyle(theme.mutedForeground)
            }
            .padding(.leading, 10)
        } else {
            Button {
                select(segment)
            } label: {
                Text(AppL10n.t("reader.translateHint"))
                    .font(.system(size: fontSize * 0.8))
                    .foregroundStyle(theme.primary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
        }
    }

    private func translationOnlyLine(_ segment: TextSegment) -> some View {
        let gloss = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLoading = gloss.isEmpty && (
            store.explainingSegmentIDs.contains(segment.id)
            || (selected?.id == segment.id && store.isBatchRunning(documentID: document.id))
        )
        return Group {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppL10n.t("reader.translating"))
                        .font(.system(size: fontSize * 0.9))
                        .foregroundStyle(theme.mutedForeground)
                }
            } else if gloss.isEmpty {
                Text(AppL10n.t("reader.translateHint"))
                    .font(.system(size: fontSize * 0.9))
                    .foregroundStyle(theme.mutedForeground)
            } else {
                Text(gloss)
                    .font(.system(size: fontSize))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(segment.id)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected?.id == segment.id
                ? theme.primary.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(segment) }
    }

    private func wordChipParagraph(_ paragraph: [TextSegment]) -> some View {
        VStack(alignment: .leading, spacing: max(10, CGFloat(fontSize) * 0.7)) {
            ForEach(paragraph) { segment in
                wordChipLine(segment)
                    .id(segment.id)
            }
        }
    }

    private func wordChipLine(_ segment: TextSegment) -> some View {
        // Legacy SwiftUI path unused — prose is rendered by ReaderAppKitScroll.
        Text(segment.text)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func phraseExplainBar(phrase: String) -> some View {
        HStack(spacing: 10) {
            Text(phrase)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.foreground)
                .lineLimit(phraseExpanded ? nil : 1)
                .frame(maxWidth: phraseExpanded ? 480 : 320, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { phraseExpanded.toggle() }
            Button {
                Task { await explainSelectedPhrase() }
            } label: {
                HStack(spacing: 6) {
                    if isExplainingPhrase {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(AppL10n.t("phrase.explain"))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(isExplainingPhrase)
            Button {
                clearWordSelection()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.mutedForeground)
            .help(AppL10n.t("phrase.clear"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(theme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 6, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppL10n.t("phrase.explain"))
    }

    @ViewBuilder
    private func segmentMenu(_ segment: TextSegment) -> some View {
        Button(AppL10n.t("reader.speak")) {
            speech.speak(
                segment.text,
                reading: segment.readingText,
                language: store.profile.preferredLanguagePair.source
            )
        }
        Button(AppL10n.t("reader.explain")) {
            select(segment)
            Task { breakdown = await store.explain(segment: segment) }
        }
        Button(AppL10n.t("reader.translate")) {
            select(segment)
            Task {
                await store.translate(segment: segment)
                refreshSelection()
            }
        }
        Button(AppL10n.t("reader.reading")) {
            select(segment)
            Task {
                await store.generateReading(segment: segment, force: true)
                refreshSelection()
            }
        }
    }

    private func refreshSelection() {
        guard let selected else { return }
        self.selected = segments.first { $0.id == selected.id } ?? selected
    }

    private func select(_ segment: TextSegment, clearWords: Bool = true) {
        selected = segment
        breakdown = nil
        answer = nil
        showInspector = true
        if clearWords {
            selectedWords = []
            lookupTarget = nil
        }
        // Lazy translation: only the tapped sentence, never the whole book.
        if mode == .bilingual || mode == .translation {
            let gloss = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if gloss.isEmpty {
                Task {
                    await store.translate(segment: segment)
                    refreshSelection()
                }
            }
        }
    }

    private func clearWordSelection() {
        selectedWords = []
        lookupTarget = nil
        phraseExpanded = false
    }

    private func handleWordTap(_ chip: SelectedWordChip, segment: TextSegment, additive: Bool) {
        select(segment, clearWords: false)
        if additive {
            // Multi-select only within the same segment.
            if let existing = selectedWords.first, existing.segmentID != chip.segmentID {
                selectedWords = [chip]
                return
            }
            if let idx = selectedWords.firstIndex(where: { $0.tokenID == chip.tokenID }) {
                selectedWords.remove(at: idx)
            } else {
                selectedWords.append(chip)
                selectedWords.sort { $0.tokenIndex < $1.tokenIndex }
            }
        } else {
            selectedWords = [chip]
        }
    }

    /// Span from first to last selected token so intervening punctuation is kept.
    private func phrase(from chips: [SelectedWordChip], in segment: TextSegment) -> String {
        let tokens = WordTokenizer.tokens(
            in: segment.text,
            languageHint: store.profile.preferredLanguagePair.source,
            segmentID: segment.id
        )
        let ids = Set(chips.map(\.tokenID))
        let matched = tokens.filter { $0.isWord && ids.contains($0.id) }
        guard let first = matched.first, let last = matched.last else {
            return chips.map(\.word).joined(separator: " ")
        }
        return String(segment.text[first.range.lowerBound..<last.range.upperBound])
    }

    /// Explain the multi-selected phrase via a temporary segment (does not overwrite the sentence).
    private func explainSelectedPhrase() async {
        guard selectedWords.count >= 2,
              let segmentID = selectedWords.first?.segmentID,
              let segment = segments.first(where: { $0.id == segmentID }) ?? selected
        else { return }
        let phraseText = phrase(from: selectedWords, in: segment)
        let trimmed = phraseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isExplainingPhrase = true
        defer { isExplainingPhrase = false }

        // Fresh ID so `store.explain` analyzes the phrase without mutating the real segment row.
        let temp = TextSegment(
            documentID: segment.documentID,
            order: segment.order,
            text: trimmed,
            isNewParagraph: false
        )
        select(segment, clearWords: false)
        if let result = await store.explain(segment: temp) {
            breakdown = result
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !segments.isEmpty else { return }
        let next: Int
        if let selectedIndex {
            next = min(max(selectedIndex + delta, 0), segments.count - 1)
        } else {
            next = delta > 0 ? 0 : segments.count - 1
        }
        select(segments[next])
    }

    private func flushReading(restart: Bool) {
        guard let start = readingStart else {
            if restart { readingStart = Date() }
            return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(start)))
        if restart {
            readingStart = Date()
        } else {
            readingStart = nil
        }
        guard elapsed >= 1 else { return }
        Task { await store.recordReadingSession(documentID: document.id, seconds: elapsed, startedAt: start) }
    }

    private func batchProgressBar(_ state: AppLibraryStore.BatchState) -> some View {
        let fraction = state.total > 0 ? Double(state.completed) / Double(state.total) : 0
        return VStack(spacing: 6) {
            HStack {
                Text(state.kind == .explain ? "Explaining…" : "Translating…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.foreground)
                Spacer()
                Text("\(state.completed)/\(state.total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
                if state.failed > 0 {
                    Text("· \(state.failed) failed")
                        .font(.footnote)
                        .foregroundStyle(theme.destructive)
                }
                Button(AppL10n.t("reader.cancel")) {
                    store.cancelBatch(documentID: document.id)
                }
                .font(.footnote)
            }
            ProgressView(value: fraction)
                .tint(theme.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(state.kind == .explain ? "Explaining" : "Translating") \(state.completed) of \(state.total)"
        )
    }
}

struct ExplanationPanel: View {
    @Environment(\.theme) private var theme
    let segment: TextSegment?
    let breakdown: GrammarBreakdown?
    let isBusy: Bool
    var canSpeak: Bool = true
    /// When true, empty state prompts clicking a word (Readlang-style); otherwise a sentence.
    var wordChipMode: Bool = true
    @Binding var question: String
    let answer: String?
    let onExplain: () async -> Void
    let onTranslate: () async -> Void
    let onReading: () async -> Void
    let onAsk: () async -> Void
    var onCancelAsk: (() -> Void)? = nil
    let onSpeak: (TextSegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppL10n.t("reader.learn"))
                .font(.headline)
                .foregroundStyle(theme.foreground)
            if let segment {
                HStack(alignment: .top, spacing: 8) {
                    Text(segment.text)
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(6)
                    Spacer(minLength: 0)
                    if canSpeak {
                        Button { onSpeak(segment) } label: {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(theme.primary)
                        .help(AppL10n.t("reader.speak"))
                        .accessibilityLabel(AppL10n.t("reader.speak"))
                    }
                }
                if let reading = displayReading(segment.readingText) {
                    Text(reading)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.mutedForeground)
                        .accessibilityLabel(AppL10n.t("learn.reading"))
                }
                HStack(spacing: 8) {
                    Button(AppL10n.t("reader.explain")) { Task { await onExplain() } }
                        .disabled(isBusy)
                        .help("E")
                    Button(AppL10n.t("reader.translate")) { Task { await onTranslate() } }
                        .disabled(isBusy)
                        .help("T")
                    Button(AppL10n.t("reader.reading")) { Task { await onReading() } }
                        .disabled(isBusy)
                        .help("R")
                    if isBusy { ProgressView().controlSize(.small) }
                }
                // Always surface segment gloss in the inspector (original mode has no inline translation).
                if let gloss = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !gloss.isEmpty {
                    labeled(AppL10n.t("learn.translation"), gloss)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.muted.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let breakdown {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let reading = displayReading(
                                breakdown.readingText ?? segment.readingText
                            ) {
                                labeled(AppL10n.t("learn.reading"), reading)
                            }
                            let segmentGloss = segment.translation?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if segmentGloss.isEmpty {
                                labeled(AppL10n.t("learn.translation"), breakdown.translation)
                            }
                            labeled(AppL10n.t("learn.explanation"), breakdown.summary)
                            if !breakdown.vocabulary.isEmpty {
                                Text(AppL10n.t("learn.vocabulary"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(theme.vocabAccent)
                                ForEach(Array(breakdown.vocabulary.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(item.word).font(.callout.weight(.semibold))
                                        if let reading = item.reading {
                                            Text(reading)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(theme.mutedForeground)
                                        }
                                        Text("— \(item.meaning)").font(.callout)
                                    }
                                    .foregroundStyle(theme.foreground)
                                }
                            }
                            if !breakdown.notes.isEmpty {
                                Text(AppL10n.t("learn.grammar"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(theme.grammarAccent)
                                ForEach(Array(breakdown.notes.enumerated()), id: \.offset) { _, note in
                                    Text("\(note.point): \(note.explanation)")
                                        .font(.callout)
                                        .foregroundStyle(theme.foreground)
                                }
                            }
                        }
                    }
                }
                Divider().overlay(theme.border)
                TextField(AppL10n.t("reader.askPlaceholder"), text: $question)
                HStack {
                    Button(AppL10n.t("reader.ask")) { Task { await onAsk() } }
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    if isBusy {
                        Button(AppL10n.t("reader.cancel")) { onCancelAsk?() }
                    }
                }
                if let answer {
                    Text(answer)
                        .font(.callout)
                        .foregroundStyle(theme.foreground)
                        .textSelection(.enabled)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if wordChipMode {
                        Label(AppL10n.t("reader.selectWord"), systemImage: "hand.tap")
                            .font(.headline)
                            .foregroundStyle(theme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(AppL10n.t("reader.selectWordHint"))
                            .font(.callout)
                            .foregroundStyle(theme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Label(AppL10n.t("reader.selectSentence"), systemImage: "text.cursor")
                            .font(.headline)
                            .foregroundStyle(theme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(AppL10n.t("reader.selectHint"))
                            .font(.callout)
                            .foregroundStyle(theme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 260)
        .background(theme.card)
    }

    private func labeled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.foreground)
            Text(body)
                .font(.callout)
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
        }
    }

    /// Hide LLM prose that was wrongly stored in the reading field.
    private func displayReading(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Reject obvious English commentary / paragraph summaries.
        if t.contains("The text ") || t.contains("This passage") || t.contains("descriptive language") {
            return nil
        }
        if t.count > 120 && (t.contains(". ") || t.contains("。")) { return nil }
        return t
    }
}

struct FlowWrap: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        WordFlowLayout(spacing: spacing, lineSpacing: lineSpacing)
            .sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        WordFlowLayout(spacing: spacing, lineSpacing: lineSpacing)
            .placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

/// Wrapping prose layout via `Layout` protocol.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return arrange(sizes: sizes, containerWidth: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let frames = arrange(sizes: sizes, containerWidth: bounds.width).frames
        for index in subviews.indices {
            let frame = frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(sizes: [CGSize], containerWidth: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        frames.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let maxWidth = containerWidth.isFinite ? max(containerWidth, 1) : 10_000

        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        let height = y + rowHeight
        let width = containerWidth.isFinite ? containerWidth : (frames.map(\.maxX).max() ?? 0)
        return (CGSize(width: width, height: max(height, 0)), frames)
    }
}

