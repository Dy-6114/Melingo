import SwiftUI
import Domain

/// Focus-mode flashcards: Space reveal · 1/2/3/4 grade · S speak · Hint / Simplify anytime.
/// Prompt side can be L2→L1 or L1→L2 (see `StudyLearnerPrefs.reviewDirection`).
struct ReviewSessionView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// When true, shown inside NavigationStack (Study hub) — hide sheet Close.
    var presentsAsNavigation: Bool = false

    private struct ReviewItem: Identifiable {
        var id: UUID { entry.id }
        var entry: VocabularyEntry
        /// True → front is native meaning, back is study word (production).
        var production: Bool
    }

    @State private var speech = SpeechService()
    @State private var queue: [ReviewItem] = []
    @State private var showAnswer = false
    @State private var isLoading = true
    @State private var gradedCount = 0
    @State private var cardScale: CGFloat = 1
    @State private var revealOpacity: Double = 0
    @State private var simplified: String?
    @State private var hintText: String?
    @State private var isSimplifying = false
    @State private var isHinting = false
    @State private var reviewContext: String?
    @State private var reminderNote: String?
    @State private var sessionStartedAt = Date()
    @State private var elapsedSeconds = 0
    @State private var autoSpeakOnReveal = true
    /// Last graded card + pre-grade snapshot for session undo (Z).
    @State private var undoSnapshot: (item: ReviewItem, prior: VocabularyEntry)?

    private var current: ReviewItem? { queue.first }
    private var progress: Double {
        let total = gradedCount + queue.count
        guard total > 0 else { return 1 }
        return Double(gradedCount) / Double(total)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            Group {
                if isLoading {
                    ProgressView()
                } else if let current {
                    session(current)
                } else {
                    doneView
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .tint(theme.primary)
        .trackStudyActivity(.review)
        .navigationTitle(presentsAsNavigation ? AppL10n.t("review.title") : "")
        .toolbar {
            if !presentsAsNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppL10n.t("review.close")) { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    Text(String(format: AppL10n.t("review.elapsed"), elapsedSeconds / 60, elapsedSeconds % 60))
                        .font(DesignTokens.Typography.mono)
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.muted.opacity(0.55), in: Capsule())
                    Text("\(gradedCount) · \(queue.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.mutedForeground)
                    Toggle(isOn: $autoSpeakOnReveal) {
                        Image(systemName: autoSpeakOnReveal ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .toggleStyle(.button)
                    .help(AppL10n.t("review.autoSpeak"))
                    Button {
                        Task { await undoLastGrade() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(undoSnapshot == nil)
                    .help(AppL10n.t("review.undo"))
                    Menu {
                        Button {
                            shuffleQueue()
                        } label: {
                            Label(AppL10n.t("review.shuffle"), systemImage: "shuffle")
                        }
                        .disabled(queue.count < 2)
                        Button {
                            studyAhead()
                        } label: {
                            Label(AppL10n.t("review.studyAhead"), systemImage: "calendar.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help(AppL10n.t("review.sessionMenu"))
                }
            }
        }
        .task {
            queue = store.dueQueue.map { entry in
                ReviewItem(
                    entry: entry,
                    production: StudyLearnerPrefs.shouldPromptProduction(for: entry.id)
                )
            }
            isLoading = false
            sessionStartedAt = .now
            speakPromptIfSafe()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            elapsedSeconds = max(0, Int(Date().timeIntervalSince(sessionStartedAt)))
        }
        .onExitCommand {
            if !presentsAsNavigation { dismiss() }
        }
        .focusable()
        .onKeyPress(.space) {
            if showAnswer { return .ignored }
            revealAnswer()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard showAnswer, let ch = press.characters.first else { return .ignored }
            switch ch {
            case "1": submit(.again)
            case "2": submit(.hard)
            case "3": submit(.good)
            case "4": submit(.easy)
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { _ in
            guard let item = current else { return .ignored }
            // Don't spoil production prompts (front is L1; L2 speech is the answer).
            guard !item.production || showAnswer else { return .ignored }
            speakStudyWord(item.entry)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "hH")) { _ in
            guard let item = current, !showAnswer else { return .ignored }
            Task { await showHint(item) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ")) { _ in
            guard undoSnapshot != nil else { return .ignored }
            Task { await undoLastGrade() }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in
            guard current != nil else { return .ignored }
            buryCurrent()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { _ in
            guard current != nil else { return .ignored }
            Task { await suspendCurrent() }
            return .handled
        }
    }

    private func session(_ item: ReviewItem) -> some View {
        let entry = item.entry
        let production = item.production
        let pair = entry.languagePair
        let front = production ? entry.meaning : entry.word
        let back = production ? entry.word : entry.meaning
        let directionLabel = production
            ? "\(pair.target) → \(pair.source)"
            : "\(pair.source) → \(pair.target)"

        return VStack(spacing: 0) {
            WorkspaceChrome.ProgressBar(progress: progress)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Text(
                production
                    ? AppL10n.t("review.howTo.production")
                    : AppL10n.t("review.howTo.recognition")
            )
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 10)

            Spacer(minLength: 12)

            ZStack {
                MemoryRing(strength: VocabularyScheduling.currentRetrievability(entry))
                    .frame(width: 200, height: 200)
                    .opacity(showAnswer ? 0.2 : 0.85)
                    .animation(.easeOut(duration: 0.3), value: showAnswer)

                VStack(spacing: 12) {
                    Text(directionLabel)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.muted.opacity(0.55), in: Capsule())

                    HStack(spacing: 12) {
                        Text(front)
                            .font(.system(size: 40, weight: .semibold, design: .serif))
                            .foregroundStyle(theme.foreground)
                            .multilineTextAlignment(.center)
                        if !production || showAnswer {
                            Button {
                                speakStudyWord(entry)
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.title3)
                                    .foregroundStyle(theme.primary)
                            }
                            .buttonStyle(.plain)
                            .help(AppL10n.t("review.speak"))
                        }
                    }

                    if !production, let reading = entry.reading, !reading.isEmpty {
                        Text(reading)
                            .font(.title3.monospaced())
                            .foregroundStyle(theme.mutedForeground)
                    }

                    if let hintText, !showAnswer {
                        Text(hintText)
                            .font(.callout)
                            .foregroundStyle(theme.primary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let simplified {
                        Text(simplified)
                            .font(.callout)
                            .foregroundStyle(theme.primary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }

                    if showAnswer {
                        VStack(spacing: 8) {
                            Text(back)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(theme.foreground)
                            if production, let reading = entry.reading, !reading.isEmpty {
                                Text(reading)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(theme.mutedForeground)
                            }
                            if let reviewContext, !reviewContext.isEmpty {
                                Text(reviewContext)
                                    .font(.body.italic())
                                    .foregroundStyle(theme.mutedForeground)
                                    .multilineTextAlignment(.center)
                            } else if let usage = entry.usage, !usage.isEmpty {
                                Text(usage)
                                    .font(.body)
                                    .foregroundStyle(theme.mutedForeground)
                            } else if let example = entry.example, !example.isEmpty {
                                Text(example)
                                    .font(.body.italic())
                                    .foregroundStyle(theme.mutedForeground)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .opacity(revealOpacity)
                        .offset(y: revealOpacity == 1 ? 0 : 6)
                    } else {
                        Text(AppL10n.t("review.spaceReveal"))
                            .font(.callout)
                            .foregroundStyle(theme.mutedForeground)
                            .padding(.top, 4)
                    }

                    helpActions(item)
                }
                .padding(32)
                .frame(maxWidth: 480)
                .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.sheet, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OKRadius.sheet, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                }
                .scaleEffect(cardScale)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 16)

            Group {
                if showAnswer {
                    Text(AppL10n.t("review.gradeHint"))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.bottom, 6)
                    ViewThatFits {
                        HStack(spacing: 10) { gradeButtons }
                        VStack(spacing: 10) { gradeButtons }
                    }
                } else {
                    Button(action: revealAnswer) {
                        Text(AppL10n.t("review.showAnswer"))
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func helpActions(_ item: ReviewItem) -> some View {
        let entry = item.entry
        return HStack(spacing: 16) {
            if !showAnswer {
                Button {
                    Task { await showHint(item) }
                } label: {
                    if isHinting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppL10n.t("review.hint"), systemImage: "lightbulb")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isHinting)
                .help(AppL10n.t("review.hintHelp"))
            }

            Button {
                Task { await simplify(entry) }
            } label: {
                if isSimplifying {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        simplified == nil
                            ? AppL10n.t("review.simplify")
                            : AppL10n.t("review.simplifyAgain"),
                        systemImage: "text.redaction"
                    )
                }
            }
            .buttonStyle(.borderless)
            .disabled(isSimplifying)
            .help(AppL10n.t("review.simplifyHelp"))

            Button {
                buryCurrent()
            } label: {
                Label(AppL10n.t("review.bury"), systemImage: "arrow.forward.to.line")
            }
            .buttonStyle(.borderless)
            .help(AppL10n.t("review.buryHelp"))

            Button {
                Task { await suspendCurrent() }
            } label: {
                Label(AppL10n.t("review.suspend"), systemImage: "pause.circle")
            }
            .buttonStyle(.borderless)
            .help(AppL10n.t("review.suspendHelp"))
        }
        .padding(.top, 6)
        .font(.callout)
        .foregroundStyle(theme.primary)
    }

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.srsStrong)
                .symbolEffect(.bounce, value: gradedCount)
            Text(gradedCount == 0 ? AppL10n.t("review.nothingDue") : AppL10n.t("review.done"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.foreground)
            Text(
                gradedCount == 0
                    ? AppL10n.t("review.nothingDetail")
                    : String(format: AppL10n.t("review.doneDetail"), gradedCount)
            )
            .font(.body)
            .foregroundStyle(theme.mutedForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)

            if let nextLine = nextDueLine {
                Text(nextLine)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.foreground)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            if !ReviewReminderService.isEnabled {
                Button {
                    Task {
                        let ok = await ReviewReminderService.enable(dueCountHint: store.dueCount)
                        reminderNote = ok
                            ? AppL10n.t("review.remindersEnabled")
                            : AppL10n.t("review.remindersDenied")
                    }
                } label: {
                    Label(AppL10n.t("review.enableReminders"), systemImage: "bell.badge")
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }

            if let reminderNote {
                Text(reminderNote)
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if !presentsAsNavigation {
                Button(AppL10n.t("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
            }
        }
    }

    /// Next calendar due after this session — habit cue beyond “Reviewed N”.
    private var nextDueLine: String? {
        let today = LocalCalendarDate.string()
        let stillDue = store.dueCount
        if stillDue > 0 {
            return String(format: AppL10n.t("review.nextDueToday"), stillDue)
        }
        let upcomingDates = store.vocabulary
            .filter { $0.suspendedAt == nil && !$0.dueDate.isEmpty && $0.dueDate > today }
            .compactMap { LocalCalendarDate.date(from: $0.dueDate) }
            .sorted()
        guard let next = upcomingDates.first else {
            return gradedCount > 0 ? AppL10n.t("review.nextDueNone") : nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: AppL10n.code)
        return String(format: AppL10n.t("review.nextDue"), formatter.string(from: next))
    }

    @ViewBuilder
    private var gradeButtons: some View {
        gradeButton(AppL10n.t("review.again"), hint: "1", color: theme.srsWeak) { submit(.again) }
        gradeButton(AppL10n.t("review.hard"), hint: "2", color: theme.srsFading) { submit(.hard) }
        gradeButton(AppL10n.t("review.good"), hint: "3", color: theme.srsStrong) { submit(.good) }
        gradeButton(AppL10n.t("review.easy"), hint: "4", color: theme.primary) { submit(.easy) }
    }

    private func gradeButton(
        _ title: String,
        hint: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(hint).font(.caption2.monospaced()).opacity(0.6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }

    private func revealAnswer() {
        if let item = current {
            Task { await prepareReviewContext(for: item.entry) }
            if autoSpeakOnReveal {
                // Recognition: speak L2 again; production: speak the study word (answer).
                speakStudyWord(item.entry)
            }
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            showAnswer = true
            revealOpacity = 1
            cardScale = 1.015
            hintText = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                cardScale = 1
            }
        }
    }

    private func shuffleQueue() {
        guard queue.count > 1 else { return }
        var rest = Array(queue.dropFirst())
        rest.shuffle()
        if let head = queue.first {
            queue = [head] + rest
        }
        resetCardChrome()
    }

    private func studyAhead() {
        let excluding = Set(queue.map(\.id))
        let ahead = store.studyAheadCandidates(limit: 10, excludingIDs: excluding)
        guard !ahead.isEmpty else { return }
        let items = ahead.map { entry in
            ReviewItem(
                entry: entry,
                production: StudyLearnerPrefs.shouldPromptProduction(for: entry.id)
            )
        }
        queue.append(contentsOf: items)
    }

    private func resetCardChrome() {
        showAnswer = false
        revealOpacity = 0
        simplified = nil
        hintText = nil
        reviewContext = nil
        reminderNote = nil
    }

    private func prepareReviewContext(for entry: VocabularyEntry) async {
        let last = StudyLearnerPrefs.lastReviewContext(for: entry.id)
        // Prefer rotating AI/saved contexts so the lemma isn't glued to one sentence.
        if let rotated = StudyLearnerPrefs.pickRotatedContext(for: entry.id, excluding: last),
           !rotated.contains("____") {
            reviewContext = rotated
            StudyLearnerPrefs.setLastReviewContext(rotated, for: entry.id)
            return
        }
        if let example = entry.example, !example.isEmpty, example != last {
            reviewContext = example
            StudyLearnerPrefs.setLastReviewContext(example, for: entry.id)
            return
        }
        if let usage = entry.usage, !usage.isEmpty, usage != last {
            reviewContext = usage
            StudyLearnerPrefs.setLastReviewContext(usage, for: entry.id)
            return
        }
        let pair = entry.languagePair
        let prompt = """
        One short example sentence in "\(pair.source)" using "\(entry.word)" (sense: \(entry.meaning)).
        \(StudyAI.generationQualityClause)
        Different from: \(last ?? entry.example ?? "")
        Reply with ONLY the sentence.
        """
        if let sentence = await StudyAI.ask(prompt, store: store, preferMLX: true) {
            let cleaned = StudyAI.sanitize(sentence)
            reviewContext = cleaned
            StudyLearnerPrefs.rememberContext(cleaned, for: entry.id)
            StudyLearnerPrefs.setLastReviewContext(cleaned, for: entry.id)
        } else {
            reviewContext = entry.example ?? entry.usage
        }
    }

    private func submit(_ grade: FSRS.Grade) {
        guard let item = current else { return }
        let prior = item.entry
        Task {
            _ = await store.review(item.entry, grade: grade)
            withAnimation(.easeInOut(duration: 0.18)) {
                undoSnapshot = (item, prior)
                if !queue.isEmpty { queue.removeFirst() }
                gradedCount += 1
                showAnswer = false
                revealOpacity = 0
                simplified = nil
                hintText = nil
                reviewContext = nil
            }
            speakPromptIfSafe()
        }
    }

    private func buryCurrent() {
        guard !queue.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            queue.removeFirst()
            showAnswer = false
            revealOpacity = 0
            simplified = nil
            hintText = nil
            reviewContext = nil
        }
        speakPromptIfSafe()
    }

    private func suspendCurrent() async {
        guard let item = current else { return }
        await store.suspendVocabulary(item.entry.id, suspend: true)
        buryCurrent()
    }

    private func undoLastGrade() async {
        guard let snap = undoSnapshot else { return }
        let ok = await store.restoreVocabularySnapshot(snap.prior)
        guard ok else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            queue.insert(ReviewItem(entry: snap.prior, production: snap.item.production), at: 0)
            gradedCount = max(0, gradedCount - 1)
            undoSnapshot = nil
            showAnswer = false
            revealOpacity = 0
            simplified = nil
            hintText = nil
            reviewContext = nil
        }
        speakPromptIfSafe()
    }

    private func speakStudyWord(_ entry: VocabularyEntry) {
        speech.speak(entry.word, reading: entry.reading, language: entry.languagePair.source)
    }

    /// Auto-speak only when the front already shows the study word (recognition).
    private func speakPromptIfSafe() {
        guard let item = queue.first, !item.production else { return }
        speakStudyWord(item.entry)
    }

    private func showHint(_ item: ReviewItem) async {
        isHinting = true
        defer { isHinting = false }
        let entry = item.entry
        let pair = entry.languagePair
        let prompt: String
        if item.production {
            prompt = """
            Give a tiny HINT (not the full answer) in \(pair.target) to help recall the \(pair.source) word for "\(entry.meaning)".
            Do not state the exact word "\(entry.word)" verbatim.
            One short sentence or a first-letter clue. No JSON.
            """
        } else {
            prompt = """
            Give a tiny HINT (not the full answer) in \(pair.target) for the word "\(entry.word)".
            Do not state the exact meaning "\(entry.meaning)" verbatim.
            One short sentence or a first-letter clue. No JSON.
            """
        }
        if let text = await StudyAI.ask(prompt, store: store) {
            withAnimation(.snappy) { hintText = text }
        } else {
            let target = item.production ? entry.word : entry.meaning
            let letters = Array(target)
            let preview = letters.prefix(max(1, letters.count / 3)).map(String.init).joined()
            withAnimation(.snappy) {
                hintText = String(format: AppL10n.t("review.hintFallback"), preview + "…")
            }
        }
    }

    private func simplify(_ entry: VocabularyEntry) async {
        isSimplifying = true
        defer { isSimplifying = false }
        let pair = entry.languagePair
        let prompt = """
        Explain the word "\(entry.word)" more simply in \(pair.target) for a beginner.
        Meaning to simplify: \(entry.meaning)
        Usage: \(entry.usage ?? "")
        Example: \(entry.example ?? "")
        Reply with 1–2 short plain sentences only. No JSON. No Snapshot dumps.
        """
        if let text = await StudyAI.ask(prompt, store: store) {
            withAnimation(.snappy) { simplified = text }
        } else {
            withAnimation(.snappy) {
                simplified = String(format: AppL10n.t("review.simplifyFallback"), entry.meaning)
            }
        }
    }
}
