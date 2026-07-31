import SwiftUI
import Domain

/// YouTube player + synchronized subtitle transcript with Reader-style word chips.
struct YouTubeReaderView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router
    @Environment(\.theme) private var theme

    let document: Document

    @State private var payload: YouTubeImportPayload?
    @State private var currentTime: TimeInterval = 0
    @State private var activeCueID: UUID?
    @State private var seekRequest: TimeInterval?
    @State private var selectedTokenIDs: Set<String> = []
    @State private var lookupWord: String?
    @State private var lookupSegment: TextSegment?
    @State private var showInspector = false
    @State private var loadError: String?
    /// Cached full-line (or phrase) translations keyed by cue id or selection key.
    @State private var lineTranslations: [UUID: String] = [:]
    @State private var translatingCueID: UUID?
    @State private var selectionTranslation: String?
    @State private var isTranslatingSelection = false

    private let translator = TranslationService()

    private var languageHint: String? {
        payload?.languageCode ?? store.profile.preferredLanguagePair.source
    }

    private var selectedPhraseText: String? {
        guard let payload, selectedTokenIDs.count >= 2 else { return nil }
        // Rebuild phrase from the active (or first matching) cue tokens in order.
        let cue = payload.cues.first(where: { $0.id == activeCueID })
            ?? payload.cues.first(where: { cue in
                WordTokenizer.tokens(in: cue.text, languageHint: languageHint, segmentID: cue.id)
                    .contains { selectedTokenIDs.contains($0.id) }
            })
        guard let cue else { return nil }
        let tokens = WordTokenizer.tokens(in: cue.text, languageHint: languageHint, segmentID: cue.id)
            .filter(\.isWord)
        let selected = tokens.filter { selectedTokenIDs.contains($0.id) }
        guard selected.count >= 2 else { return nil }
        return selected.map(\.text).joined(separator: " ")
    }

    var body: some View {
        Group {
            if let payload {
                content(payload)
            } else if let loadError {
                ContentUnavailableView(
                    AppL10n.t("youtube.loadError"),
                    systemImage: "play.slash",
                    description: Text(loadError)
                )
            } else {
                ProgressView(AppL10n.t("import.importing"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.background)
        .navigationTitle(document.title)
        .task(id: document.id) {
            load()
        }
        .onAppear {
            router.collapseSidebar()
        }
        .onDisappear {
            router.expandSidebar()
        }
    }

    private func content(_ payload: YouTubeImportPayload) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                YouTubePlayerView(
                    videoID: payload.videoID,
                    onTimeUpdate: { time in
                        currentTime = time
                        updateActiveCue(at: time, in: payload.cues)
                    },
                    onReady: {},
                    seekRequest: $seekRequest
                )
                .frame(minHeight: 240)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)

                currentLineBar(payload)
            }
            .frame(minWidth: 420)

            transcriptPane(payload)
                .frame(minWidth: 320, idealWidth: 400)

            if showInspector, let word = lookupWord, let segment = lookupSegment {
                lookupPane(word: word, segment: segment, title: payload.title)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        }
        .overlay(alignment: .bottom) {
            if let phrase = selectedPhraseText {
                selectionBar(phrase: phrase)
                    .padding(.bottom, 16)
            }
        }
    }

    private func currentLineBar(_ payload: YouTubeImportPayload) -> some View {
        let cue = payload.cues.first(where: { $0.id == activeCueID })
        return HStack(alignment: .top, spacing: 10) {
            Text(formatTime(currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.mutedForeground)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if let cue {
                    Text(cue.text)
                        .font(.caption)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if let translation = lineTranslations[cue.id] {
                        Text(translation)
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 8)

            if let cue {
                Button {
                    Task { await translateLine(cue) }
                } label: {
                    if translatingCueID == cue.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: lineTranslations[cue.id] == nil
                              ? "text.bubble"
                              : "text.bubble.fill")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.primary)
                .help(AppL10n.t("youtube.translateLine"))
                .disabled(translatingCueID == cue.id)
            }

            Text(payload.languageName)
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func transcriptPane(_ payload: YouTubeImportPayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppL10n.t("youtube.subtitles"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                Spacer()
                Text("\(payload.cues.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedForeground)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(theme.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(payload.cues.enumerated()), id: \.element.id) { index, cue in
                            cueRow(cue, index: index, isActive: cue.id == activeCueID)
                                .id(cue.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: activeCueID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        .background(theme.background)
    }

    private func cueRow(_ cue: YouTubeCue, index: Int, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                seekRequest = cue.start
                activeCueID = cue.id
            } label: {
                Text(formatTime(cue.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isActive ? theme.primary : theme.mutedForeground)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.top, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppL10n.t("reader.speak"))

            VStack(alignment: .leading, spacing: 6) {
                YouTubeCueChipText(
                    text: cue.text,
                    languageHint: languageHint,
                    selectedIDs: selectedTokenIDs,
                    isActiveCue: isActive,
                    segmentID: cue.id,
                    onWordTap: { token, additive in
                        handleTap(token: token, cue: cue, additive: additive)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) {
                    Task { await translateLine(cue) }
                }

                if let translation = lineTranslations[cue.id] {
                    Text(translation)
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if translatingCueID == cue.id {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(AppL10n.t("youtube.translatingLine"))
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
            }

            Button {
                if lineTranslations[cue.id] != nil {
                    withAnimation(.easeOut(duration: 0.2)) {
                        lineTranslations[cue.id] = nil
                    }
                } else {
                    Task { await translateLine(cue) }
                }
            } label: {
                Image(systemName: lineTranslations[cue.id] == nil
                      ? "text.bubble"
                      : "text.bubble.fill")
                    .font(.body)
                    .foregroundStyle(theme.primary.opacity(isActive ? 1 : 0.75))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                lineTranslations[cue.id] == nil
                    ? AppL10n.t("youtube.translateLine")
                    : AppL10n.t("youtube.hidingTranslation")
            )
            .disabled(translatingCueID == cue.id)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? theme.primary.opacity(0.12) : theme.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive ? theme.primary.opacity(0.55) : theme.border.opacity(0.6),
                    lineWidth: isActive ? 1.5 : 1
                )
        }
        .scaleEffect(isActive ? 1.015 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture {
            seekRequest = cue.start
            activeCueID = cue.id
        }
        .contextMenu {
            Button(AppL10n.t("youtube.translateLine")) {
                Task { await translateLine(cue) }
            }
            if lineTranslations[cue.id] != nil {
                Button(AppL10n.t("youtube.hidingTranslation")) {
                    lineTranslations[cue.id] = nil
                }
            }
            Button(AppL10n.t("reader.speak")) {
                seekRequest = cue.start
                activeCueID = cue.id
            }
        }
    }

    private func selectionBar(phrase: String) -> some View {
        HStack(spacing: 10) {
            Text(phrase)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.foreground)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)

            if let selectionTranslation {
                Text(selectionTranslation)
                    .font(.callout)
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                Task { await translateSelection(phrase) }
            } label: {
                HStack(spacing: 6) {
                    if isTranslatingSelection {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "text.bubble")
                    }
                    Text(AppL10n.t("youtube.translateSelection"))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(isTranslatingSelection)

            Button {
                selectedTokenIDs = []
                selectionTranslation = nil
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
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private func lookupPane(word: String, segment: TextSegment, title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppL10n.t("lookup.translation"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                Spacer()
                Button {
                    showInspector = false
                    lookupWord = nil
                    lookupSegment = nil
                    selectedTokenIDs = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            // Quick action: translate the whole cue while looking at a word.
            if let cue = payload?.cues.first(where: { $0.id == segment.id }) {
                Button {
                    Task { await translateLine(cue) }
                } label: {
                    Label(AppL10n.t("youtube.translateLine"), systemImage: "text.bubble")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                if let translation = lineTranslations[cue.id] {
                    Text(translation)
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }

            ScrollView {
                WordLookupPopover(
                    word: word,
                    segment: segment,
                    documentTitle: title,
                    canSpeak: true
                )
                .padding(.horizontal, 8)
            }
        }
        .background(theme.card)
    }

    private func load() {
        if let loaded = YouTubeLibraryImport.loadPayload(for: document, store: store) {
            payload = loaded
            loadError = nil
        } else {
            loadError = AppL10n.t("youtube.missingData")
        }
    }

    private func updateActiveCue(at time: TimeInterval, in cues: [YouTubeCue]) {
        let match = cues.first { time >= $0.start && time < $0.end }
            ?? cues.last(where: { $0.start <= time })
        let newID = match?.id
        if newID != activeCueID {
            withAnimation(.easeInOut(duration: 0.22)) {
                activeCueID = newID
            }
        }
    }

    private func handleTap(token: WordToken, cue: YouTubeCue, additive: Bool) {
        seekRequest = cue.start
        activeCueID = cue.id
        if additive {
            if selectedTokenIDs.contains(token.id) {
                selectedTokenIDs.remove(token.id)
            } else {
                selectedTokenIDs.insert(token.id)
            }
            selectionTranslation = nil
            return
        }
        selectedTokenIDs = [token.id]
        selectionTranslation = nil
        let segment = store.segments(for: document.id).first(where: { $0.id == cue.id })
            ?? TextSegment(id: cue.id, documentID: document.id, order: 0, text: cue.text)
        lookupWord = token.text
        lookupSegment = segment
        showInspector = true
    }

    private func translateLine(_ cue: YouTubeCue) async {
        if translatingCueID == cue.id { return }
        translatingCueID = cue.id
        defer { translatingCueID = nil }
        let pair = store.profile.preferredLanguagePair
        let source = payload?.languageCode ?? pair.source
        do {
            let contentPair = LanguagePair(source: source, target: pair.target)
            let gloss = try await translator.translateFlexible(cue.text, pair: contentPair)
            withAnimation(.easeInOut(duration: 0.25)) {
                lineTranslations[cue.id] = gloss
            }
        } catch {
            withAnimation {
                lineTranslations[cue.id] = error.localizedDescription
            }
        }
    }

    private func translateSelection(_ phrase: String) async {
        isTranslatingSelection = true
        defer { isTranslatingSelection = false }
        let pair = store.profile.preferredLanguagePair
        let source = payload?.languageCode ?? pair.source
        do {
            let contentPair = LanguagePair(source: source, target: pair.target)
            selectionTranslation = try await translator.translateFlexible(phrase, pair: contentPair)
        } catch {
            selectionTranslation = error.localizedDescription
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
