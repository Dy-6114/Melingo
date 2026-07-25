import SwiftUI
import AppKit
import Domain

/// Custom (non-tag) learning packs: create empty, AI-generate, or JSON-import.
struct MyPacksView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(PackOrderStore.self) private var packOrder
    @Environment(\.theme) private var theme

    @State private var showGenerate = false
    @State private var showImport = false
    @State private var showCreate = false
    @State private var newPackName = ""
    @State private var renaming: WordPack?
    @State private var renameText = ""
    @State private var useList = true
    @State private var selectedPackID: UUID?
    @State private var showInspector = false
    @State private var path = NavigationPath()

    private var packs: [WordPack] {
        let raw = store.packs.filter { $0.kind == .learningPack && $0.id != WordPack.systemUngroupedID }
        return packOrder.ordered(raw)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: WordPack.self) { pack in
                    PackDetailView(pack: pack)
                }
        }
        .onAppear { packOrder.reconcile(with: packs) }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if packs.isEmpty {
                ContentUnavailableView {
                    Label(AppL10n.t("packs.emptyTitle"), systemImage: "square.stack.3d.up")
                } description: {
                    Text(AppL10n.t("packs.emptyDetail"))
                } actions: {
                    HStack {
                        Button(AppL10n.t("packs.createEmpty")) { showCreate = true }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.primary)
                        Button(AppL10n.t("packs.generate")) { showGenerate = true }
                            .buttonStyle(.bordered)
                        Button(AppL10n.t("packs.import")) { showImport = true }
                            .buttonStyle(.bordered)
                    }
                }
            } else if useList {
                listContent
            } else {
                gridContent
            }
        }
        .background(theme.background)
        .navigationTitle(AppL10n.t("packs.title"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("", selection: $useList) {
                    Image(systemName: "list.bullet").tag(true)
                    Image(systemName: "square.grid.2x2").tag(false)
                }
                .pickerStyle(.segmented)
                .help(useList ? AppL10n.t("packs.listMode") : AppL10n.t("packs.gridMode"))
                .frame(width: 72)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(AppL10n.t("packs.createEmpty")) { showCreate = true }
                    Button(AppL10n.t("packs.generate")) { showGenerate = true }
                    Button(AppL10n.t("packs.import")) { showImport = true }
                } label: {
                    Label(AppL10n.t("packs.new"), systemImage: "plus")
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            if let packID = selectedPackID {
                PackInspector(
                    packID: packID,
                    onOpen: {
                        if let pack = store.packs.first(where: { $0.id == packID }) {
                            path.append(pack)
                        }
                    },
                    onDismiss: {
                        showInspector = false
                        selectedPackID = nil
                    }
                )
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
        }
        .sheet(isPresented: $showGenerate) {
            GeneratePackSheet()
        }
        .sheet(isPresented: $showImport) {
            ImportPackAISheet()
        }
        .alert(AppL10n.t("packs.createEmpty"), isPresented: $showCreate) {
            TextField(AppL10n.t("packs.namePlaceholder"), text: $newPackName)
            Button("Cancel", role: .cancel) { newPackName = "" }
            Button(AppL10n.t("common.create")) {
                Task {
                    _ = await store.createLearningPack(name: newPackName)
                    newPackName = ""
                    packOrder.reconcile(with: packs)
                }
            }
        } message: {
            Text(AppL10n.t("packs.createHint"))
        }
        .alert(AppL10n.t("packs.rename"), isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField(AppL10n.t("packs.namePlaceholder"), text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                guard let pack = renaming else { return }
                Task {
                    _ = await store.renamePack(pack.id, name: renameText)
                    renaming = nil
                }
            }
        }
    }

    private var listContent: some View {
        List(selection: $selectedPackID) {
            Section {
                ForEach(packs) { pack in
                    NavigationLink(value: pack) {
                        PackListRow(pack: pack) {
                            renaming = pack
                            renameText = pack.name
                        }
                    }
                    .tag(pack.id)
                    .listRowBackground(Color.clear)
                    .dropDestination(for: VocabularyTransfer.self) { items, _ in
                        guard let id = items.first?.id else { return false }
                        Task { await store.addVocabulary(id, toPack: pack.id) }
                        return true
                    }
                }
                .onMove { source, dest in
                    packOrder.move(packs: packs, from: source, to: dest)
                }
            } header: {
                Text(AppL10n.t("packs.reorderHint"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onChange(of: selectedPackID) { _, id in
            showInspector = id != nil
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)],
                spacing: 16
            ) {
                ForEach(packs) { pack in
                    NavigationLink(value: pack) {
                        PackCard(pack: pack) {
                            renaming = pack
                            renameText = pack.name
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        selectedPackID = pack.id
                        showInspector = true
                    })
                    .dropDestination(for: VocabularyTransfer.self) { items, _ in
                        guard let id = items.first?.id else { return false }
                        Task { await store.addVocabulary(id, toPack: pack.id) }
                        return true
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct PackListRow: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    let pack: WordPack
    var onRename: () -> Void

    private var progress: (learned: Int, total: Int) {
        store.packLearningProgress(for: pack)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(theme.mutedForeground)
                .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(pack.name)
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundStyle(theme.foreground)
                    if pack.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.primary)
                    }
                }
                Text(String(format: AppL10n.t("packs.progress"), progress.learned, progress.total))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(theme.mutedForeground)
            }
            Spacer()
            WorkspaceChrome.ProgressBar(
                progress: Double(progress.learned) / Double(max(progress.total, 1))
            )
            .frame(width: 72)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(AppL10n.t("packs.rename"), action: onRename)
            Button(pack.isPinned ? AppL10n.t("packs.unpin") : AppL10n.t("packs.pin")) {
                Task { await store.setPackPinned(pack.id, pinned: !pack.isPinned) }
            }
            Button(AppL10n.t("packs.delete"), role: .destructive) {
                Task { await store.deletePackWithCards(pack.id) }
            }
        }
    }
}

private struct PackCard: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    let pack: WordPack
    var onRename: () -> Void

    private var progress: (learned: Int, total: Int) {
        store.packLearningProgress(for: pack)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                cover
                if pack.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(pack.name)
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(String(format: AppL10n.t("packs.cards"), progress.total))
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                ProgressView(
                    value: Double(progress.learned),
                    total: Double(max(progress.total, 1))
                )
                .tint(theme.primary)
                Text(String(format: AppL10n.t("packs.progress"), progress.learned, max(progress.total, 0)))
                    .font(.caption2)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .padding(10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        .contextMenu {
            Button(AppL10n.t("packs.rename"), action: onRename)
            Button(pack.isPinned ? AppL10n.t("packs.unpin") : AppL10n.t("packs.pin")) {
                Task { await store.setPackPinned(pack.id, pinned: !pack.isPinned) }
            }
            Button(AppL10n.t("packs.delete"), role: .destructive) {
                Task { await store.deletePackWithCards(pack.id) }
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let url = store.absoluteCoverURL(for: pack), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
        } else {
            ZStack {
                LinearGradient(
                    colors: [theme.primary.opacity(0.25), theme.accent.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.primary)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
        }
    }
}
