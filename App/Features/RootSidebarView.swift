import SwiftUI
import AppKit
import Domain

struct RootSidebarView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router
    @Environment(WorkspaceCommandCenter.self) private var commandCenter
    @Environment(PackOrderStore.self) private var packOrder
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var tagsExpanded = true
    @State private var showTagEditor = false
    @State private var showQuickFind = false
    @State private var quickCommand = QuickCommandController()
    @State private var lastQuickFindToken = 0
    @State private var lastReviewWindowToken = 0

    private var pinnedPacks: [WordPack] {
        packOrder.ordered(store.packs.filter { $0.isPinned })
    }

    private var tagPacks: [WordPack] {
        packOrder.ordered(store.packs.filter { $0.kind == .tag })
    }

    private var displayName: String {
        let name = store.profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return AppL10n.t("sidebar.you")
    }

    private var selectionBinding: Binding<WorkspaceDestination?> {
        Binding(
            get: { router.destination },
            set: { newValue in
                if let newValue {
                    router.navigate(to: newValue)
                }
            }
        )
    }

    private var splitVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { router.columnVisibility },
            set: { router.columnVisibility = $0 }
        )
    }

    private var weakCount: Int {
        store.vocabulary.filter {
            $0.suspendedAt == nil
                && VocabularyScheduling.currentRetrievability($0) < 0.7
                && $0.srsState != .new
        }.count
    }

    var body: some View {
        NavigationSplitView(columnVisibility: splitVisibility) {
            List(selection: selectionBinding) {
                Section {
                    Label {
                        HStack(spacing: 8) {
                            Text(AppL10n.t("sidebar.study"))
                            if store.dueCount > 0 {
                                Text("\(store.dueCount)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.primary.opacity(0.16), in: Capsule())
                                    .foregroundStyle(theme.primary)
                            }
                        }
                    } icon: {
                        Image(systemName: "graduationcap")
                    }
                    .tag(WorkspaceDestination.study)
                    Label(AppL10n.t("sidebar.newCard"), systemImage: "plus.rectangle.on.folder")
                        .tag(WorkspaceDestination.newCard)
                    Label(AppL10n.t("sidebar.history"), systemImage: "clock.arrow.circlepath")
                        .tag(WorkspaceDestination.history)
                    Label(AppL10n.t("sidebar.stats"), systemImage: "chart.bar.fill")
                        .tag(WorkspaceDestination.stats)
                    Label(AppL10n.t("sidebar.vocabulary"), systemImage: "character.book.closed")
                        .tag(WorkspaceDestination.vocabulary)
                    Label(AppL10n.t("sidebar.articles"), systemImage: "books.vertical")
                        .tag(WorkspaceDestination.library)
                    Label(AppL10n.t("sidebar.myPacks"), systemImage: "square.stack.3d.up")
                        .tag(WorkspaceDestination.myPacks)
                }

                Section(AppL10n.t("sidebar.smart")) {
                    ForEach(SmartFilter.allCases) { filter in
                        Label {
                            HStack {
                                Text(AppL10n.t(filter.titleKey))
                                Spacer(minLength: 4)
                                let count: Int = {
                                    switch filter {
                                    case .due: return store.dueCount
                                    case .new: return store.newDueCount
                                    case .weak: return weakCount
                                    case .suspended:
                                        return store.vocabulary.filter { $0.suspendedAt != nil }.count
                                    }
                                }()
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(theme.mutedForeground)
                                }
                            }
                        } icon: {
                            Image(systemName: filter.systemImage)
                        }
                        .tag(WorkspaceDestination.smart(filter))
                    }
                }

                if !pinnedPacks.isEmpty {
                    Section(AppL10n.t("sidebar.pins")) {
                        ForEach(pinnedPacks) { pack in
                            Label(pack.name, systemImage: "pin.fill")
                                .tag(WorkspaceDestination.pinnedPack(pack.id))
                                .dropDestination(for: VocabularyTransfer.self) { items, _ in
                                    guard let id = items.first?.id else { return false }
                                    Task { await store.addVocabulary(id, toPack: pack.id) }
                                    return true
                                }
                        }
                        .onMove { source, dest in
                            packOrder.move(packs: pinnedPacks, from: source, to: dest)
                        }
                    }
                }

                Section {
                    Button {
                        withAnimation(DesignTokens.Animation.snappy) {
                            tagsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(AppL10n.t("sidebar.tags"))
                                .foregroundStyle(theme.foreground)
                            Spacer(minLength: 0)
                            Button {
                                showTagEditor = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.mutedForeground)
                            }
                            .buttonStyle(.borderless)
                            .help(AppL10n.t("tags.editor"))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.mutedForeground)
                                .rotationEffect(.degrees(tagsExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if tagsExpanded {
                        ForEach(tagPacks) { tag in
                            let style = TagStyleStore.style(for: tag.id)
                            Label {
                                Text(tag.name)
                            } icon: {
                                Image(systemName: style.symbolName)
                                    .foregroundStyle(Color(hex: style.colorHex))
                            }
                            .tag(WorkspaceDestination.tag(tag.id))
                            .dropDestination(for: VocabularyTransfer.self) { items, _ in
                                guard let id = items.first?.id else { return false }
                                Task { await store.addVocabulary(id, toPack: tag.id) }
                                return true
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        .onMove { source, dest in
                            packOrder.move(packs: tagPacks, from: source, to: dest)
                        }
                    }
                }
            }
            .animation(DesignTokens.Animation.snappy, value: tagsExpanded)
            .navigationTitle("Melingo")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooter
            }
        } detail: {
            Group {
                switch router.destination {
                case .study:
                    StudyHubView()
                case .newCard:
                    NewCardView()
                case .history:
                    HistoryView()
                case .stats:
                    StatsView()
                case .vocabulary:
                    VocabularyView()
                case .smart(let filter):
                    VocabularyView(smartFilter: filter)
                case .library:
                    LibraryView()
                case .myPacks:
                    MyPacksView()
                case .tag(let id):
                    HistoryView(tagID: id)
                case .pinnedPack(let id):
                    NavigationStack {
                        if let pack = store.packs.first(where: { $0.id == id }) {
                            PackDetailView(pack: pack)
                        } else {
                            HistoryView()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .id(store.profile.uiLocale)
        }
        .tint(theme.primary)
        .overlay {
            if showQuickFind {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { dismissQuickFind() }
                    QuickCommandPalette(
                        controller: quickCommand,
                        onSelect: handleQuickCommand,
                        onDismiss: dismissQuickFind
                    )
                }
                .transition(.opacity)
            }
        }
        .animation(DesignTokens.Animation.soft, value: showQuickFind)
        .onReceive(NotificationCenter.default.publisher(for: .melingoOpenNewCardFromService)) { _ in
            router.navigate(to: .newCard)
            MenuBarAgent.shared.showMainWindow()
        }
        .onChange(of: commandCenter.quickFindToken) { _, token in
            guard token != lastQuickFindToken else { return }
            lastQuickFindToken = token
            presentQuickFind()
        }
        .onChange(of: commandCenter.openReviewWindowToken) { _, token in
            guard token != lastReviewWindowToken else { return }
            lastReviewWindowToken = token
            openWindow(id: MelingoWindowID.review)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.lastError {
                HStack(alignment: .center, spacing: 10) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(theme.destructiveForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button {
                        store.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.destructiveForeground.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help(AppL10n.t("error.dismiss"))
                    .accessibilityLabel(AppL10n.t("error.dismiss"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(theme.destructive.opacity(0.92))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(DesignTokens.Animation.snappy, value: store.lastError)
        .onChange(of: store.lastError) { _, newValue in
            guard let newValue else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if store.lastError == newValue {
                    store.dismissError()
                }
            }
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorView()
                .frame(minWidth: 420, minHeight: 360)
        }
        .onAppear {
            AppL10n.sync(from: store.profile)
            quickCommand.attach(store: store)
        }
        .onChange(of: store.profile.uiLocale) { _, _ in
            AppL10n.sync(from: store.profile)
        }
        .onChange(of: store.vocabulary.count) { _, _ in
            quickCommand.attach(store: store)
        }
        .onChange(of: store.packs.count) { _, _ in
            quickCommand.attach(store: store)
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            avatarView
            Text(displayName)
                .font(.body.weight(.medium))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(theme.mutedForeground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppL10n.t("sidebar.settings"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.card)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border.opacity(0.7))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        let size: CGFloat = 28
        if let url = store.absoluteAvatarURL(),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(theme.primary.opacity(0.18))
                Text(String(displayName.prefix(1)).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.primary)
            }
            .frame(width: size, height: size)
        }
    }

    private func presentQuickFind() {
        quickCommand.attach(store: store)
        quickCommand.prepare()
        showQuickFind = true
        MenuBarAgent.shared.showMainWindow()
    }

    private func dismissQuickFind() {
        showQuickFind = false
    }

    private func handleQuickCommand(_ result: QuickCommandResult) {
        dismissQuickFind()
        switch result.action {
        case .go(let dest):
            router.navigate(to: dest)
        case .openSettings:
            openSettings()
        case .openPack(let id):
            if store.packs.first(where: { $0.id == id })?.isPinned == true {
                router.navigate(to: .pinnedPack(id))
            } else if store.packs.first(where: { $0.id == id })?.kind == .tag {
                router.navigate(to: .tag(id))
            } else {
                router.navigate(to: .myPacks)
            }
        case .openVocabulary(let id):
            router.focusedVocabularyID = id
            router.navigate(to: .vocabulary)
        case .startReview:
            router.openStudy(.review)
        }
    }
}
