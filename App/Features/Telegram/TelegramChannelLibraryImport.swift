import Foundation
import AppKit
import Domain
import TelegramKit

/// Imports / refreshes a public Telegram channel into the Melingo library.
@MainActor
enum TelegramChannelLibraryImport {
    static let pendingUsernameKey = "telegram.pendingChannel"

    /// Prefer existing library document for the same `@username`.
    static func existingDocument(
        username: String,
        in documents: [Document]
    ) -> Document? {
        let key = ChannelExporter.normalizeUsername(username).lowercased()
        return documents.first {
            $0.sourceKind == .telegram
                && ChannelExporter.normalizeUsername($0.sourceURL ?? "").lowercased() == key
        }
    }

    static func makeSegments(
        from export: ChannelExportDocument,
        documentID: Document.ID
    ) -> [TextSegment] {
        export.posts.enumerated().compactMap { index, post in
            let body = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return TextSegment(
                documentID: documentID,
                order: index,
                text: body,
                isNewParagraph: true
            )
        }
    }

    static func makeDocument(
        from export: ChannelExportDocument,
        existingID: Document.ID? = nil
    ) -> Document {
        let username = export.channel.username.map { "@\($0)" }
            ?? export.channel.title
        // Title = channel name for Articles list / navigation.
        return Document(
            id: existingID ?? UUID(),
            title: export.channel.title,
            sourceKind: .telegram,
            sourceURL: username.hasPrefix("@") ? username : "@\(ChannelExporter.normalizeUsername(username))",
            storedFileRelativePath: nil,
            updatedAt: .now
        )
    }

    /// Export via TDLib (25 newest posts) and persist as a library article.
    static func importChannel(
        username: String,
        store: AppLibraryStore,
        controller: TelegramWorkspaceController
    ) async throws -> Document {
        let name = ChannelExporter.normalizeUsername(username)
        guard !name.isEmpty else {
            throw TelegramKitError.exportFailed(AppL10n.t("import.telegram.error.emptyUsername"))
        }

        if !controller.client.isReady {
            await controller.startClient()
            if !controller.client.isReady {
                throw TelegramKitError.notAuthorized
            }
        }

        controller.channelUsername = name
        await controller.exportChannel()
        guard let export = controller.exportDocument else {
            throw TelegramKitError.exportFailed(controller.progressText.isEmpty
                ? AppL10n.t("import.telegram.error.exportFailed")
                : controller.progressText)
        }

        let existing = existingDocument(username: name, in: store.documents)
        var document = makeDocument(from: export, existingID: existing?.id)
        if let existing {
            document.createdAt = existing.createdAt
        }
        let segments = makeSegments(from: export, documentID: document.id)
        let coverPNG = avatarPNG(from: export, folder: controller.exportDirectory)
        try await store.saveTelegramChannel(
            document: document,
            segments: segments,
            coverPNG: coverPNG
        )
        return store.documents.first(where: { $0.id == document.id }) ?? document
    }

    /// Load the next 25 older posts and refresh library segments.
    static func loadMorePosts(
        for document: Document,
        store: AppLibraryStore,
        controller: TelegramWorkspaceController
    ) async throws -> ChannelExportDocument {
        guard let loaded = loadExport(for: document) else {
            throw TelegramKitError.exportFailed(AppL10n.t("import.telegram.error.exportFailed"))
        }
        guard !loaded.0.reachedHistoryEnd else { return loaded.0 }

        controller.channelUsername = ChannelExporter.normalizeUsername(
            document.sourceURL ?? document.title
        )
        guard let updated = await controller.exportMorePosts(existing: loaded.0) else {
            throw TelegramKitError.exportFailed(controller.progressText.isEmpty
                ? AppL10n.t("import.telegram.error.exportFailed")
                : controller.progressText)
        }

        var libraryDoc = makeDocument(from: updated, existingID: document.id)
        libraryDoc.createdAt = document.createdAt
        let segments = makeSegments(from: updated, documentID: document.id)
        let coverPNG = avatarPNG(from: updated, folder: loaded.1)
            ?? (store.pagePreviewURL(for: document.id) == nil
                ? avatarPNG(from: updated, folder: controller.exportDirectory)
                : nil)
        try await store.saveTelegramChannel(
            document: libraryDoc,
            segments: segments,
            coverPNG: coverPNG
        )
        return updated
    }

    /// Check Telegram for newer posts and merge them without dropping older pages.
    @discardableResult
    static func refreshNewestPosts(
        for document: Document,
        store: AppLibraryStore,
        controller: TelegramWorkspaceController
    ) async throws -> ChannelExportDocument {
        guard let loaded = loadExport(for: document) else {
            return try await {
                _ = try await importChannel(
                    username: document.sourceURL ?? document.title,
                    store: store,
                    controller: controller
                )
                guard let again = loadExport(for: document)?.0 else {
                    throw TelegramKitError.exportFailed(AppL10n.t("import.telegram.error.exportFailed"))
                }
                return again
            }()
        }

        if !controller.client.isReady {
            await controller.startClient()
            if !controller.client.isReady {
                throw TelegramKitError.notAuthorized
            }
        }

        controller.channelUsername = ChannelExporter.normalizeUsername(
            document.sourceURL ?? document.title
        )
        guard let updated = await controller.exportNewestPosts(existing: loaded.0) else {
            throw TelegramKitError.exportFailed(controller.progressText.isEmpty
                ? AppL10n.t("import.telegram.error.exportFailed")
                : controller.progressText)
        }

        var libraryDoc = makeDocument(from: updated, existingID: document.id)
        libraryDoc.createdAt = document.createdAt
        let segments = makeSegments(from: updated, documentID: document.id)
        let coverPNG = avatarPNG(from: updated, folder: loaded.1)
            ?? (store.pagePreviewURL(for: document.id) == nil
                ? avatarPNG(from: updated, folder: controller.exportDirectory)
                : nil)
        try await store.saveTelegramChannel(
            document: libraryDoc,
            segments: segments,
            coverPNG: coverPNG
        )
        return updated
    }

    static func loadExport(for document: Document) -> (ChannelExportDocument, URL)? {
        guard document.sourceKind == .telegram else { return nil }
        let name = ChannelExporter.normalizeUsername(document.sourceURL ?? document.title)
        let folder = TelegramPaths.exportFolder(forUsername: name)
        guard let export = try? TelegramExportLibrary.loadDocument(at: folder) else { return nil }
        return (export, folder)
    }

    /// Channel avatar → PNG for Articles card cover.
    static func avatarPNG(from export: ChannelExportDocument, folder: URL?) -> Data? {
        guard let folder,
              let relative = export.channel.avatarRelativePath
        else { return nil }
        let url = folder.appendingPathComponent(relative)
        guard let image = NSImage(contentsOf: url) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    /// Convenience for library cards when the export already lives on disk.
    static func avatarPNG(fromExportOf document: Document) -> Data? {
        guard let loaded = loadExport(for: document) else { return nil }
        return avatarPNG(from: loaded.0, folder: loaded.1)
    }
}
