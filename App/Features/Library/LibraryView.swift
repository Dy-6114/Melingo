import AppKit
import SwiftUI
import Domain
import UniformTypeIdentifiers

// MARK: - Your Articles

struct LibraryView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var path: [Document] = []
    @State private var showImport = false
    @State private var isDropTargeted = false
    @AppStorage("library.viewMode") private var viewModeRaw = ArticlesViewMode.grid.rawValue

    private var viewModeBinding: Binding<ArticlesViewMode> {
        Binding(
            get: { ArticlesViewMode(rawValue: viewModeRaw) ?? .grid },
            set: { viewModeRaw = $0.rawValue }
        )
    }

    private let gridSpacing: CGFloat = 20
    private let gridPadding: CGFloat = 24
    private let minCardWidth: CGFloat = 210

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.isLoading && store.documents.isEmpty {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    articlesContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .clipped()
            .navigationTitle(AppL10n.t("library.title"))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("View", selection: viewModeBinding) {
                        Image(systemName: "list.bullet")
                            .tag(ArticlesViewMode.list)
                        Image(systemName: "square.grid.2x2")
                            .tag(ArticlesViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                    .help(AppL10n.t("library.viewHelp"))

                    Button {
                        Task { await store.load() }
                    } label: {
                        Label(AppL10n.t("library.refresh"), systemImage: "arrow.clockwise")
                    }
                    .help(AppL10n.t("library.refresh.help"))

                    Button {
                        showImport = true
                    } label: {
                        Label(AppL10n.t("library.newMaterial"), systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help(AppL10n.t("library.newMaterial.help"))
                }
            }
            .navigationDestination(for: Document.self) { document in
                Group {
                    if document.sourceKind == .epub,
                       let url = store.absoluteDocumentFileURL(for: document) {
                        EpubBookReaderView(document: document, bookURL: url)
                    } else {
                        ReaderView(document: document)
                    }
                }
                .onAppear { ReaderWindowSizing.expandForReader() }
            }
            .sheet(isPresented: $showImport) {
                ImportSheet { document in
                    path = [document]
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    dropOverlay
                }
            }
            .overlay(alignment: .bottom) {
                errorBanner
            }
        }
    }

    @ViewBuilder
    private var articlesContent: some View {
        let mode = ArticlesViewMode(rawValue: viewModeRaw) ?? .grid
        switch mode {
        case .grid:
            GeometryReader { geo in
                let available = max(geo.size.width - gridPadding * 2, minCardWidth)
                // Conservative column count — never ask for more columns than fit at minCardWidth.
                let columnsCount = max(
                    1,
                    min(4, Int(floor((available + gridSpacing) / (minCardWidth + gridSpacing))))
                )
                ScrollView {
                    ArticlesGrid(
                        columns: columnsCount,
                        spacing: gridSpacing,
                        documents: store.documents,
                        onNew: { showImport = true },
                        onOpen: { path = [$0] },
                        onDelete: { doc in
                            Task { await store.deleteDocument(doc.id) }
                        }
                    )
                    .padding(gridPadding)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        case .list:
            List {
                Button {
                    showImport = true
                } label: {
                    Label(AppL10n.t("library.newMaterial"), systemImage: "plus.circle")
                        .foregroundStyle(theme.primary)
                }
                .listRowBackground(theme.background)

                ForEach(store.documents) { document in
                    Button {
                        path = [document]
                    } label: {
                        DocumentRow(document: document)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.background)
                    .contextMenu {
                        Button("Open") { path = [document] }
                        Button("Delete", role: .destructive) {
                            Task { await store.deleteDocument(document.id) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.inset)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            theme.primary.opacity(0.06)
            RoundedRectangle(cornerRadius: OKRadius.sheet, style: .continuous)
                .strokeBorder(theme.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(16)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(theme.primary)
                Text(AppL10n.t("library.dropTitle"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                Text(AppL10n.t("library.dropSubtitle"))
                    .font(.subheadline)
                    .foregroundStyle(theme.mutedForeground)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = store.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(theme.destructiveForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    theme.destructive.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                )
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel("Import error: \(error)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let source = ImportSourceKind.imageIfNeeded(url)
                    if let doc = await store.importSource(source) {
                        path = [doc]
                    }
                }
            }
        }
        return true
    }
}

private enum ArticlesViewMode: String {
    case grid
    case list
}

/// Manual row/column grid — equal-width `HStack` cells, so cards can never overlap.
private struct ArticlesGrid: View {
    let columns: Int
    let spacing: CGFloat
    let documents: [Document]
    var onNew: () -> Void
    var onOpen: (Document) -> Void
    var onDelete: (Document) -> Void

    private var rows: [[GridCell]] {
        var cells: [GridCell] = [.newMaterial]
        cells.append(contentsOf: documents.map { .document($0) })
        let cols = max(columns, 1)
        var result: [[GridCell]] = []
        var i = 0
        while i < cells.count {
            let end = min(i + cols, cells.count)
            result.append(Array(cells[i..<end]))
            i = end
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cellView(cell)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .clipped()
                    }
                    // Fill empty slots so remaining cards don't stretch unevenly.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func cellView(_ cell: GridCell) -> some View {
        switch cell {
        case .newMaterial:
            NewMaterialCard(action: onNew)
        case .document(let doc):
            ArticleCard(
                document: doc,
                onOpen: { onOpen(doc) },
                onDelete: { onDelete(doc) }
            )
        }
    }

    private enum GridCell {
        case newMaterial
        case document(Document)
    }
}

// MARK: - Cards

private struct NewMaterialCard: View {
    @Environment(\.theme) private var theme
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(theme.primary)
                Text(AppL10n.t("library.newMaterial"))
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 220)
            .background(theme.card.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                    .strokeBorder(
                        theme.primary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityLabel(AppL10n.t("library.newMaterial"))
        .accessibilityHint(AppL10n.t("library.newMaterial.help"))
    }
}

private struct ArticleCard: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    let document: Document
    var onOpen: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false
    @State private var remoteImage: NSImage?

    private var progress: DocumentLearningProgress {
        store.progress(for: document.id)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    preview
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .clipped()

                    VStack {
                        HStack(alignment: .top) {
                            formatBadge
                            Spacer(minLength: 8)
                            if isHovered {
                                hoverActions
                            }
                        }
                        .padding(8)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipped()
                .contentShape(Rectangle())

                VStack(alignment: .leading, spacing: 8) {
                    Text(document.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 40, alignment: .top)

                    HStack(spacing: 6) {
                        statusChips
                        Spacer(minLength: 0)
                        Text(document.createdAt, format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(theme.mutedForeground)
                            .lineLimit(1)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.7), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        // No drop shadow — shadows were bleeding into neighboring cells and stealing hits.
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.title)
        .accessibilityHint("Opens reader")
    }

    private var preview: some View {
        Group {
            if let url = store.pagePreviewURL(for: document.id),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if let remoteImage {
                Image(nsImage: remoteImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    theme.muted
                    Image(systemName: document.sourceKind.symbolName)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(theme.mutedForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: document.id) {
            await loadCardCoverIfNeeded()
        }
    }

    private func loadCardCoverIfNeeded() async {
        if store.pagePreviewURL(for: document.id) != nil { return }
        if let cached = DocumentCoverCache.image(for: document.id) {
            remoteImage = cached
            return
        }
        if let disk = DocumentCoverCache.loadFromDisk(documentID: document.id) {
            remoteImage = disk
            DocumentCoverCache.store(disk, for: document.id)
            return
        }
        if let source = document.sourceURL,
           let pageURL = URL(string: source),
           let scheme = pageURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let og = await OpenGraphImageFetcher.firstImageURL(from: pageURL),
           let image = await DocumentCoverCache.download(og) {
            remoteImage = image
            DocumentCoverCache.persist(image, documentID: document.id)
        }
    }

    private var formatBadge: some View {
        Text(document.sourceKind.displayLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.primary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(theme.primary)
    }

    @ViewBuilder
    private var statusChips: some View {
        if progress.translated > 0 {
            Text(AppL10n.t("library.translated"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.explained.opacity(0.16), in: Capsule())
                .foregroundStyle(theme.explained)
        } else if progress.explained > 0 {
            Text(AppL10n.t("library.explained"))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.explained.opacity(0.16), in: Capsule())
                .foregroundStyle(theme.explained)
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            circleAction("eye", action: onOpen)
            circleAction("trash", role: .destructive, action: onDelete)
        }
    }

    private func circleAction(
        _ systemName: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(role == .destructive ? theme.destructive : theme.foreground)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct DocumentRow: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    let document: Document

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DocumentThumbnail(document: document)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(document.sourceKind.displayLabel)
                    Text("·")
                    Text(document.createdAt, style: .date)
                    let progress = store.progress(for: document.id)
                    Text("·")
                    Text("\(progress.total) sentences")
                    if progress.translated > 0 {
                        Text(AppL10n.t("library.translated"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.explained.opacity(0.14), in: Capsule())
                            .foregroundStyle(theme.explained)
                    } else if progress.explained > 0 {
                        Text("\(progress.explained)/\(progress.total)")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.explained.opacity(0.14), in: Capsule())
                            .foregroundStyle(theme.explained)
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct DocumentThumbnail: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    let document: Document

    private let size = CGSize(width: 40, height: 52)

    @State private var remoteImage: NSImage?

    var body: some View {
        Group {
            if let url = store.pagePreviewURL(for: document.id),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let remoteImage {
                Image(nsImage: remoteImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            theme.primary.opacity(0.22),
                            theme.accent.opacity(0.35),
                            theme.muted,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: document.sourceKind.symbolName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.mutedForeground)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: OKRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.control, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: document.id) {
            await loadRemoteCoverIfNeeded()
        }
    }

    private func loadRemoteCoverIfNeeded() async {
        if store.pagePreviewURL(for: document.id) != nil { return }
        if let cached = DocumentCoverCache.image(for: document.id) {
            remoteImage = cached
            return
        }
        if let disk = DocumentCoverCache.loadFromDisk(documentID: document.id) {
            remoteImage = disk
            DocumentCoverCache.store(disk, for: document.id)
            return
        }

        // Prefer Open Graph / first image from source page.
        if let source = document.sourceURL,
           let pageURL = URL(string: source),
           let scheme = pageURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            if let og = await OpenGraphImageFetcher.firstImageURL(from: pageURL),
               let image = await DocumentCoverCache.download(og) {
                remoteImage = image
                DocumentCoverCache.persist(image, documentID: document.id)
                return
            }
        }

        // Fallback: themed keyword image (Unsplash Source → picsum).
        let keywords = DocumentCoverCache.keywords(from: document.title)
        let candidates: [URL?] = [
            URL(string: "https://source.unsplash.com/featured/80x104/?\(keywords)"),
            URL(string: "https://picsum.photos/seed/\(document.id.uuidString.prefix(8))/80/104"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let image = await DocumentCoverCache.download(candidate) {
                remoteImage = image
                DocumentCoverCache.persist(image, documentID: document.id)
                return
            }
        }
    }
}

/// In-memory + `~/Documents/Melingo` cache for library cover thumbnails.
@MainActor
private enum DocumentCoverCache {
    private static let memory = NSCache<NSString, NSImage>()

    static func image(for id: UUID) -> NSImage? {
        memory.object(forKey: id.uuidString as NSString)
    }

    static func store(_ image: NSImage, for id: UUID) {
        memory.setObject(image, forKey: id.uuidString as NSString)
    }

    static func loadFromDisk(documentID: UUID) -> NSImage? {
        let url = coverURL(documentID: documentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func persist(_ image: NSImage, documentID: UUID) {
        store(image, for: documentID)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return }
        let url = coverURL(documentID: documentID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Network fetch stays off the cache instance so Swift concurrency doesn't treat `Store` as sent.
    nonisolated static func download(_ url: URL) async -> NSImage? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
                  let image = NSImage(data: data), image.size.width > 0
            else { return nil }
            return image
        } catch {
            return nil
        }
    }

    private static func coverURL(documentID: UUID) -> URL {
        MelingoPaths.ensureRoot()
        return MelingoPaths.documents
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent("cover.jpg", isDirectory: false)
    }

    nonisolated static func keywords(from title: String) -> String {
        let parts = title
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
            .map(String.init)
        let joined = parts.joined(separator: ",")
        let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "book"
        return encoded.isEmpty ? "book,reading" : encoded
    }
}

/// Lightweight Open Graph / first-image scrape for library thumbnails.
private enum OpenGraphImageFetcher {
    static func firstImageURL(from pageURL: URL) async -> URL? {
        do {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else { return nil }

            if let og = matchMeta(html: html, property: "og:image")
                ?? matchMeta(html: html, property: "twitter:image"),
               let resolved = URL(string: og, relativeTo: pageURL)?.absoluteURL {
                return resolved
            }
            // First reasonably-sized <img src="...">
            if let img = matchFirstImageSrc(html),
               let resolved = URL(string: img, relativeTo: pageURL)?.absoluteURL {
                return resolved
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func matchMeta(html: String, property: String) -> String? {
        let patterns = [
            #"property=["']\#(property)["'][^>]*content=["']([^"']+)["']"#,
            #"content=["']([^"']+)["'][^>]*property=["']\#(property)["']"#,
            #"name=["']\#(property)["'][^>]*content=["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func matchFirstImageSrc(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img[^>]+src=["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ),
        let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let src = String(html[range])
        if src.hasPrefix("data:") { return nil }
        return src
    }
}


// MARK: - Import

enum ImportSourceKind {
    static func imageIfNeeded(_ url: URL) -> ImportSource {
        let ext = url.pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
        if imageExts.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            return .image(url)
        }
        return .file(url)
    }
}

private enum ImportTab: String, CaseIterable, Identifiable {
    case url, pdf, epub, txt, word, markdown, image, paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .url: AppL10n.t("import.tab.url")
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .txt: "TXT"
        case .word: AppL10n.t("import.tab.word")
        case .markdown: "Markdown"
        case .image: AppL10n.t("import.tab.ocr")
        case .paste: AppL10n.t("import.tab.paste")
        }
    }

    var symbolName: String {
        switch self {
        case .url: "link"
        case .pdf: "doc.richtext"
        case .epub: "book"
        case .txt: "doc.plaintext"
        case .word: "doc.text"
        case .markdown: "text.alignleft"
        case .image: "text.viewfinder"
        case .paste: "doc.on.clipboard"
        }
    }

    var allowedTypes: [UTType] {
        switch self {
        case .pdf: return [.pdf]
        case .epub:
            return [UTType(filenameExtension: "epub")].compactMap { $0 }
        case .txt: return [.plainText, .text]
        case .word:
            return [UTType(filenameExtension: "docx")].compactMap { $0 }
        case .markdown:
            return [
                UTType(filenameExtension: "md"),
                UTType(filenameExtension: "markdown"),
            ].compactMap { $0 }
        case .image: return [.image]
        case .url, .paste: return []
        }
    }
}

struct ImportSheet: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Called with the imported document when “Start reading after import” is on.
    var onImported: ((Document) -> Void)?

    @State private var tab: ImportTab = .url
    @State private var pastedText = ""
    @State private var title = ""
    @State private var urlString = ""
    @State private var isBusy = false
    @State private var startReading = true
    @State private var pickedFileURL: URL?
    @State private var importError: String?
    @State private var statusNote: String?

    init(onImported: ((Document) -> Void)? = nil) {
        self.onImported = onImported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppL10n.t("import.title"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                    Text(tabHelp)
                        .font(.callout)
                        .foregroundStyle(theme.mutedForeground)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.mutedForeground)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            tabBar
                .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        switch tab {
                        case .url:
                            urlFields
                        case .paste:
                            pasteFields
                        default:
                            fileFields
                        }
                    }

                    Toggle(AppL10n.t("import.startReading"), isOn: $startReading)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(theme.foreground)

                    if let importError {
                        Label(importError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(theme.destructive)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.destructive.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let statusNote {
                        Text(statusNote)
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                    if isBusy {
                        ProgressView(AppL10n.t("import.importingLong"))
                            .controlSize(.small)
                            .foregroundStyle(theme.foreground)
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 420)

            Divider().overlay(theme.border)
            HStack(spacing: 12) {
                Spacer()
                Button(AppL10n.t("common.cancel")) { dismiss() }
                    .foregroundStyle(theme.foreground)
                Button(isBusy ? AppL10n.t("import.importing") : AppL10n.t("import.action")) {
                    Task { await runImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || !canImport)
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
            }
            .padding(16)
        }
        .frame(width: 580)
        .background(theme.background)
        .tint(theme.primary)
        .onChange(of: tab) { _, _ in
            importError = nil
            statusNote = nil
            pickedFileURL = nil
        }
    }

    private var tabHelp: String {
        switch tab {
        case .url: AppL10n.t("import.help.url")
        case .paste: AppL10n.t("import.help.paste")
        case .pdf: AppL10n.t("import.help.pdf")
        case .epub: AppL10n.t("import.help.epub")
        case .txt: AppL10n.t("import.help.txt")
        case .markdown: AppL10n.t("import.help.markdown")
        case .word: AppL10n.t("import.help.word")
        case .image: AppL10n.t("import.help.image")
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ImportTab.allCases) { item in
                    Button {
                        tab = item
                        pickedFileURL = nil
                    } label: {
                        Label(item.title, systemImage: item.symbolName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                tab == item ? theme.primary.opacity(0.16) : theme.card,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    tab == item ? theme.primary.opacity(0.45) : theme.border,
                                    lineWidth: 1
                                )
                            }
                            .foregroundStyle(tab == item ? theme.primary : theme.foreground)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var urlFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel(AppL10n.t("import.url.label"))
            themedField(
                TextField("https://example.com/article", text: $urlString)
                    .textContentType(.URL)
                    .onSubmit { Task { await runImport() } }
            )
            fieldLabel(AppL10n.t("import.title.optional"))
            themedField(
                TextField(AppL10n.t("import.title.placeholder"), text: $title)
            )
            if !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(normalizedURL, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            tipBox(AppL10n.t("import.url.tip"))
        }
    }

    private var pasteFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel(AppL10n.t("import.title.optional"))
            themedField(TextField(AppL10n.t("import.paste.placeholder"), text: $title))
            fieldLabel(AppL10n.t("import.text"))
            TextEditor(text: $pastedText)
                .font(.body)
                .foregroundStyle(theme.foreground)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 180)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                }
            Text(String(format: AppL10n.t("import.chars"), pastedText.count))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.mutedForeground)
        }
    }

    private var fileFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel(AppL10n.t("import.title.optional"))
            themedField(TextField(AppL10n.t("import.fileTitle.placeholder"), text: $title))

            VStack(alignment: .leading, spacing: 12) {
                if let pickedFileURL {
                    Label(pickedFileURL.lastPathComponent, systemImage: "doc.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.foreground)
                        .textSelection(.enabled)
                } else {
                    Text(String(format: AppL10n.t("import.file.hint"), tab.title))
                        .font(.callout)
                        .foregroundStyle(theme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    pickFile()
                } label: {
                    Label(
                        pickedFileURL == nil
                            ? AppL10n.t("import.chooseFile")
                            : AppL10n.t("import.chooseAnother"),
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy)
                .keyboardShortcut("o", modifiers: .command)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.foreground)
    }

    private func themedField<Content: View>(_ content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(theme.foreground)
            .padding(10)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
    }

    private func tipBox(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(theme.mutedForeground)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var canImport: Bool {
        switch tab {
        case .url:
            return URL(string: normalizedURL)?.host != nil
        case .paste:
            return !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return pickedFileURL != nil
        }
    }

    private var normalizedURL: String {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("://") ? t : "https://\(t)"
    }

    private func runImport() async {
        isBusy = true
        importError = nil
        statusNote = tab == .url ? "Fetching and extracting article…" : "Importing…"
        defer {
            isBusy = false
            statusNote = nil
        }
        let source: ImportSource?
        switch tab {
        case .url:
            guard let url = URL(string: normalizedURL) else {
                importError = "That doesn’t look like a valid URL."
                return
            }
            source = .url(url)
        case .paste:
            source = .plainText(
                title: title.isEmpty ? nil : title,
                body: pastedText
            )
        default:
            guard let url = pickedFileURL else { return }
            source = tab == .image ? .image(url) : .file(url)
        }
        guard let source else { return }
        guard var document = await store.importSource(source) else {
            importError = store.lastError
                ?? "Import failed. Check the URL or file and try again."
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            await store.renameDocument(document.id, title: trimmedTitle)
            if let updated = store.documents.first(where: { $0.id == document.id }) {
                document = updated
            } else {
                document.title = trimmedTitle
            }
        }

        dismiss()
        if startReading {
            onImported?(document)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Import \(tab.title)"
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = tab.allowedTypes.isEmpty
            ? [.pdf, .plainText, .text, .image]
            : tab.allowedTypes
        if panel.runModal() == .OK {
            pickedFileURL = panel.url
            importError = nil
        }
    }
}

private extension DocumentSourceKind {
    var displayLabel: String {
        switch self {
        case .plainText: "TXT"
        case .markdown: "MD"
        case .web: "WEB"
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .docx: "DOCX"
        case .imageOCR: "OCR"
        }
    }

    var symbolName: String {
        switch self {
        case .plainText, .markdown: "doc.plaintext"
        case .web: "globe"
        case .pdf: "doc.richtext"
        case .epub: "book"
        case .docx: "doc.text"
        case .imageOCR: "text.viewfinder"
        }
    }
}
