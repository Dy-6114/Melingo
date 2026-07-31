import SwiftUI
import TelegramKit
import Domain

/// Opens a library Telegram channel: loads JSON export, supports “25 more” older posts.
struct TelegramChannelReaderView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    let document: Document

    @State private var export: ChannelExportDocument?
    @State private var mediaRoot: URL?
    @State private var refreshNote: String?
    @State private var isRefreshing = false
    @State private var isLoadingMore = false
    @Bindable private var controller = TelegramSession.shared

    var body: some View {
        Group {
            if let export {
                VStack(spacing: 0) {
                    if !export.reachedHistoryEnd {
                        loadMoreBar(postCount: export.posts.count)
                    }
                    TelegramInteractiveChannelView(document: export, mediaRoot: mediaRoot)
                }
            } else {
                ProgressView(AppL10n.t("telegram.reader.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
            }
        }
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    Label(AppL10n.t("telegram.reader.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || isLoadingMore)
                .help(AppL10n.t("telegram.reader.refresh.help"))
            }
        }
        .overlay(alignment: .bottom) {
            if let refreshNote {
                Text(refreshNote)
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .task(id: document.id) {
            loadCached()
            if export == nil {
                await refresh(force: true)
            } else if controller.client.isReady {
                // Soft check for new posts when already signed in (does not wipe older pages).
                await refresh(force: false)
            }
        }
    }

    private func loadMoreBar(postCount: Int) -> some View {
        HStack(spacing: 10) {
            Text(String(format: AppL10n.t("telegram.reader.postCount"), postCount))
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            Spacer()
            Button {
                Task { await loadMore() }
            } label: {
                if isLoadingMore {
                    ProgressView().controlSize(.small)
                } else {
                    Label(AppL10n.t("telegram.reader.loadMore"), systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingMore || isRefreshing || !controller.client.isReady)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.card)
    }

    private func loadCached() {
        if let loaded = TelegramChannelLibraryImport.loadExport(for: document) {
            export = loaded.0
            mediaRoot = loaded.1
        }
    }

    private func refresh(force: Bool) async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let updated = try await TelegramChannelLibraryImport.refreshNewestPosts(
                for: document,
                store: store,
                controller: controller
            )
            export = updated
            if let folder = TelegramChannelLibraryImport.loadExport(for: document)?.1 {
                mediaRoot = folder
            }
            if force {
                refreshNote = String(format: AppL10n.t("telegram.reader.updated"), updated.posts.count)
                try? await Task.sleep(for: .seconds(2))
                refreshNote = nil
            }
        } catch TelegramKitError.notAuthorized, TelegramKitError.notConfigured {
            refreshNote = AppL10n.t("telegram.reader.signInToRefresh")
            if export == nil { loadCached() }
        } catch {
            refreshNote = error.localizedDescription
            if export == nil { loadCached() }
        }
    }

    private func loadMore() async {
        if isLoadingMore { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let updated = try await TelegramChannelLibraryImport.loadMorePosts(
                for: document,
                store: store,
                controller: controller
            )
            export = updated
            if let folder = TelegramChannelLibraryImport.loadExport(for: document)?.1 {
                mediaRoot = folder
            }
            refreshNote = String(format: AppL10n.t("telegram.reader.updated"), updated.posts.count)
            try? await Task.sleep(for: .seconds(1.5))
            refreshNote = nil
        } catch TelegramKitError.notAuthorized, TelegramKitError.notConfigured {
            refreshNote = AppL10n.t("telegram.reader.signInToRefresh")
        } catch {
            refreshNote = error.localizedDescription
        }
    }
}
