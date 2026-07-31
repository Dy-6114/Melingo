import Foundation
@preconcurrency import TDLibKit

/// Fetches messages from a public channel and writes JSON + local media.
/// Default page is 25 posts (newest). Older pages load via `exportMore`.
/// TDLib often returns a partial first batch — `fetchPage` keeps requesting until
/// a full page is collected or history truly ends.
public struct ChannelExporter: Sendable {
    public var downloadMedia: Bool
    public var pageSize: Int

    public static let defaultPageSize = 25

    public init(downloadMedia: Bool = true, pageSize: Int = ChannelExporter.defaultPageSize) {
        self.downloadMedia = downloadMedia
        self.pageSize = max(1, pageSize)
    }

    public struct Progress: Sendable {
        public var fetched: Int
        public var message: String
        public init(fetched: Int, message: String) {
            self.fetched = fetched
            self.message = message
        }
    }

    /// First page: up to `pageSize` newest posts (stored oldest→newest).
    public func export(
        username rawUsername: String,
        client: TDLibClient,
        outputDirectory: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ChannelExportDocument {
        let username = Self.normalizeUsername(rawUsername)
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let mediaDir = outputDirectory.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        onProgress?(Progress(fetched: 0, message: "Resolving @\(username)…"))

        let chat = try await resolvePublicChat(username: username, client: client)
        // Cold public chats often return a single message until the chat is opened.
        _ = try? await client.openChat(chatId: chat.id)
        let meta = try await channelMeta(
            chat: chat,
            client: client,
            username: username,
            mediaDir: mediaDir,
            downloadAvatar: true
        )

        let page = try await fetchPage(
            chatId: chat.id,
            fromMessageId: 0,
            limit: pageSize,
            client: client,
            mediaDir: mediaDir,
            onProgress: onProgress
        )

        let posts = page.posts.sorted { $0.date < $1.date }
        let document = ChannelExportDocument(
            channel: meta,
            posts: posts,
            reachedHistoryEnd: page.reachedEnd
        )
        try write(document, to: outputDirectory)
        onProgress?(Progress(fetched: posts.count, message: "Wrote \(posts.count) posts"))
        return document
    }

    /// Next older page (up to `pageSize`), merged in front of `existing`.
    public func exportMore(
        username rawUsername: String,
        existing: ChannelExportDocument,
        client: TDLibClient,
        outputDirectory: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ChannelExportDocument {
        if existing.reachedHistoryEnd {
            return existing
        }
        guard let oldestId = existing.posts.map(\.id).min() else {
            return try await export(
                username: rawUsername,
                client: client,
                outputDirectory: outputDirectory,
                onProgress: onProgress
            )
        }

        let username = Self.normalizeUsername(rawUsername)
        let mediaDir = outputDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        onProgress?(Progress(fetched: existing.posts.count, message: "Resolving @\(username)…"))
        let chat = try await resolvePublicChat(username: username, client: client)
        _ = try? await client.openChat(chatId: chat.id)

        let page = try await fetchPage(
            chatId: chat.id,
            fromMessageId: oldestId,
            limit: pageSize,
            client: client,
            mediaDir: mediaDir,
            onProgress: onProgress
        )

        let existingIDs = Set(existing.posts.map(\.id))
        let older = page.posts
            .filter { !existingIDs.contains($0.id) }
            .sorted { $0.date < $1.date }

        var merged = existing
        merged.posts = older + existing.posts
        merged.exportedAt = .now
        merged.reachedHistoryEnd = page.reachedEnd || older.isEmpty
        if let refreshed = try? await channelMeta(
            chat: chat,
            client: client,
            username: username,
            mediaDir: mediaDir,
            downloadAvatar: existing.channel.avatarRelativePath == nil
        ) {
            merged.channel = refreshed
            // Keep an existing avatar if the refresh skipped download.
            if merged.channel.avatarRelativePath == nil {
                merged.channel.avatarRelativePath = existing.channel.avatarRelativePath
            }
        }
        try write(merged, to: outputDirectory)
        onProgress?(Progress(fetched: merged.posts.count, message: "Wrote \(merged.posts.count) posts"))
        return merged
    }

    /// Fetch newest posts and prepend only those not already in `existing` (keeps older pages).
    public func exportNewest(
        username rawUsername: String,
        existing: ChannelExportDocument,
        client: TDLibClient,
        outputDirectory: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ChannelExportDocument {
        guard !existing.posts.isEmpty else {
            return try await export(
                username: rawUsername,
                client: client,
                outputDirectory: outputDirectory,
                onProgress: onProgress
            )
        }

        let username = Self.normalizeUsername(rawUsername)
        let mediaDir = outputDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        onProgress?(Progress(fetched: existing.posts.count, message: "Resolving @\(username)…"))
        let chat = try await resolvePublicChat(username: username, client: client)
        _ = try? await client.openChat(chatId: chat.id)

        let page = try await fetchPage(
            chatId: chat.id,
            fromMessageId: 0,
            limit: pageSize,
            client: client,
            mediaDir: mediaDir,
            onProgress: onProgress
        )

        let existingIDs = Set(existing.posts.map(\.id))
        let newest = page.posts
            .filter { !existingIDs.contains($0.id) }
            .sorted { $0.date < $1.date }

        var merged = existing
        // Refresh metadata / views for posts that already exist and appear in the newest page.
        if !newest.isEmpty || !page.posts.isEmpty {
            var byID = Dictionary(uniqueKeysWithValues: merged.posts.map { ($0.id, $0) })
            for post in page.posts {
                if byID[post.id] != nil {
                    byID[post.id] = post
                }
            }
            let kept = merged.posts.map { byID[$0.id] ?? $0 }
            merged.posts = kept + newest
            // Deduplicate while preserving order (older…newer).
            var seen = Set<Int64>()
            merged.posts = merged.posts.filter { seen.insert($0.id).inserted }
            merged.posts.sort { $0.date < $1.date }
        }
        merged.exportedAt = .now
        if let refreshed = try? await channelMeta(
            chat: chat,
            client: client,
            username: username,
            mediaDir: mediaDir,
            downloadAvatar: existing.channel.avatarRelativePath == nil
        ) {
            merged.channel = refreshed
            if merged.channel.avatarRelativePath == nil {
                merged.channel.avatarRelativePath = existing.channel.avatarRelativePath
            }
        }
        try write(merged, to: outputDirectory)
        onProgress?(Progress(fetched: merged.posts.count, message: "Wrote \(merged.posts.count) posts"))
        return merged
    }

    public static func normalizeUsername(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }
        if let url = URL(string: s), let host = url.host, host.contains("t.me") {
            s = url.lastPathComponent
        }
        if s.lowercased().hasPrefix("https://t.me/") {
            s = String(s.dropFirst("https://t.me/".count))
        }
        if s.lowercased().hasPrefix("t.me/") {
            s = String(s.dropFirst("t.me/".count))
        }
        return s.split(separator: "/").first.map(String.init) ?? s
    }

    // MARK: - Private

    private struct PageResult: Sendable {
        var posts: [ExportedPost]
        var reachedEnd: Bool
    }

    private func fetchPage(
        chatId: Int64,
        fromMessageId: Int64,
        limit: Int,
        client: TDLibClient,
        mediaDir: URL,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> PageResult {
        // TDLib may return fewer than `limit` (often 1 on a cold chat). Keep paging
        // until we collect a full page or truly hit the end — never treat
        // `batch.count < limit` alone as end-of-history.
        var collected: [Message] = []
        var cursor = fromMessageId
        var reachedEnd = false
        var rounds = 0
        let maxRounds = 40

        while collected.count < limit && !reachedEnd && rounds < maxRounds {
            rounds += 1
            let history = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: cursor,
                limit: min(max(limit, 1), 100),
                offset: 0,
                onlyLocal: false
            )
            let batch = history.messages ?? []
            if batch.isEmpty {
                reachedEnd = true
                break
            }

            let known = Set(collected.map(\.id))
            let fresh = batch.filter { message in
                if known.contains(message.id) { return false }
                // Anchor message is included again when paging older history.
                if cursor != 0 && message.id == cursor { return false }
                return true
            }

            if fresh.isEmpty {
                if let oldest = batch.map(\.id).min(), oldest != cursor {
                    cursor = oldest
                    continue
                }
                // Cold cache: retry a few times before declaring end.
                if collected.isEmpty && rounds < 8 {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                reachedEnd = true
                break
            }

            collected.append(contentsOf: fresh)
            onProgress?(Progress(
                fetched: min(collected.count, limit),
                message: "Fetched \(min(collected.count, limit)) posts…"
            ))

            if let oldest = batch.map(\.id).min() {
                cursor = oldest
            } else {
                break
            }
        }

        let pageMessages = Array(collected.prefix(limit))
        var posts: [ExportedPost] = []
        posts.reserveCapacity(pageMessages.count)
        for (index, message) in pageMessages.enumerated() {
            onProgress?(Progress(
                fetched: pageMessages.count,
                message: "Processing \(index + 1)/\(pageMessages.count)…"
            ))
            let mapped = try await mapMessage(
                message,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            // Drop empty shells (service / unsupported) that would show only time + views.
            let trimmed = mapped.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && mapped.attachments.isEmpty {
                continue
            }
            posts.append(mapped)
        }
        return PageResult(posts: posts, reachedEnd: reachedEnd)
    }

    private func channelMeta(
        chat: Chat,
        client: TDLibClient,
        username: String,
        mediaDir: URL,
        downloadAvatar: Bool
    ) async throws -> ChannelMeta {
        var description: String?
        var memberCount: Int?
        var channelId: Int64 = chat.id
        if case .chatTypeSupergroup(let superInfo) = chat.type {
            let full = try await client.getSupergroupFullInfo(supergroupId: superInfo.supergroupId)
            description = full.description
            memberCount = full.memberCount
            channelId = superInfo.supergroupId
        }

        var avatarRelativePath: String?
        if downloadAvatar, let photo = chat.photo {
            let file = photo.big.expectedSize >= photo.small.expectedSize ? photo.big : photo.small
            if let att = try await downloadFileIfNeeded(
                file,
                kind: .photo,
                client: client,
                mediaDir: mediaDir,
                preferredName: "avatar.jpg",
                downloadMedia: true
            ), let relative = att.localRelativePath {
                avatarRelativePath = relative
            }
        }

        return ChannelMeta(
            id: channelId,
            username: username,
            title: chat.title,
            description: description,
            memberCount: memberCount,
            avatarRelativePath: avatarRelativePath
        )
    }

    private func write(_ document: ChannelExportDocument, to outputDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonURL = outputDirectory.appendingPathComponent("channel.json")
        try encoder.encode(document).write(to: jsonURL, options: .atomic)
    }

    private func resolvePublicChat(username: String, client: TDLibClient) async throws -> Chat {
        do {
            return try await client.searchPublicChat(username: username)
        } catch {
            throw TelegramKitError.channelNotFound(username)
        }
    }

    private func mapMessage(
        _ message: Message,
        client: TDLibClient,
        mediaDir: URL,
        downloadMedia: Bool
    ) async throws -> ExportedPost {
        var text = ""
        var contentType = "unknown"
        var attachments: [ExportedAttachment] = []
        var customEmojis: [ExportedCustomEmoji] = []

        switch message.content {
        case .messageText(let value):
            contentType = "text"
            text = value.text.text
            customEmojis = try await resolveCustomEmojis(
                in: value.text,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
        case .messagePhoto(let value):
            contentType = "photo"
            text = value.caption.text
            customEmojis = try await resolveCustomEmojis(
                in: value.caption,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            if let file = bestPhotoFile(value.photo) {
                if let att = try await downloadFileIfNeeded(
                    file,
                    kind: .photo,
                    client: client,
                    mediaDir: mediaDir,
                    preferredName: "photo_\(message.id).jpg",
                    downloadMedia: downloadMedia
                ) {
                    attachments.append(att)
                }
            }
        case .messageVideo(let value):
            contentType = "video"
            text = value.caption.text
            customEmojis = try await resolveCustomEmojis(
                in: value.caption,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            if let att = try await downloadFileIfNeeded(
                value.video.video,
                kind: .video,
                client: client,
                mediaDir: mediaDir,
                preferredName: value.video.fileName.isEmpty
                    ? "video_\(message.id).mp4"
                    : value.video.fileName,
                downloadMedia: downloadMedia,
                width: value.video.width,
                height: value.video.height,
                duration: Double(value.video.duration),
                mimeType: value.video.mimeType
            ) {
                attachments.append(att)
            }
        case .messageAnimation(let value):
            contentType = "animation"
            text = value.caption.text
            customEmojis = try await resolveCustomEmojis(
                in: value.caption,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            if let att = try await downloadFileIfNeeded(
                value.animation.animation,
                kind: .animation,
                client: client,
                mediaDir: mediaDir,
                preferredName: value.animation.fileName.isEmpty
                    ? "anim_\(message.id).mp4"
                    : value.animation.fileName,
                downloadMedia: downloadMedia,
                width: value.animation.width,
                height: value.animation.height,
                duration: Double(value.animation.duration),
                mimeType: value.animation.mimeType
            ) {
                attachments.append(att)
            }
        case .messageDocument(let value):
            contentType = "document"
            text = value.caption.text
            customEmojis = try await resolveCustomEmojis(
                in: value.caption,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            if let att = try await downloadFileIfNeeded(
                value.document.document,
                kind: .document,
                client: client,
                mediaDir: mediaDir,
                preferredName: value.document.fileName.isEmpty
                    ? "doc_\(message.id)"
                    : value.document.fileName,
                downloadMedia: downloadMedia,
                mimeType: value.document.mimeType
            ) {
                attachments.append(att)
            }
        case .messageAudio(let value):
            contentType = "audio"
            text = value.caption.text
            customEmojis = try await resolveCustomEmojis(
                in: value.caption,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            if let att = try await downloadFileIfNeeded(
                value.audio.audio,
                kind: .audio,
                client: client,
                mediaDir: mediaDir,
                preferredName: value.audio.fileName.isEmpty
                    ? "audio_\(message.id).mp3"
                    : value.audio.fileName,
                downloadMedia: downloadMedia,
                duration: Double(value.audio.duration),
                mimeType: value.audio.mimeType
            ) {
                attachments.append(att)
            }
        case .messageVoiceNote(let value):
            contentType = "voice"
            text = value.caption.text
            customEmojis = try await resolveCustomEmojis(
                in: value.caption,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            )
            if let att = try await downloadFileIfNeeded(
                value.voiceNote.voice,
                kind: .voice,
                client: client,
                mediaDir: mediaDir,
                preferredName: "voice_\(message.id).ogg",
                downloadMedia: downloadMedia,
                duration: Double(value.voiceNote.duration),
                mimeType: value.voiceNote.mimeType
            ) {
                attachments.append(att)
            }
        case .messageSticker(let value):
            contentType = "sticker"
            text = value.sticker.emoji
            if let att = try await exportStickerAttachment(
                value.sticker,
                messageID: message.id,
                client: client,
                mediaDir: mediaDir,
                downloadMedia: downloadMedia
            ) {
                attachments.append(att)
            }
        default:
            contentType = String(describing: message.content)
        }

        return ExportedPost(
            id: message.id,
            date: Date(timeIntervalSince1970: TimeInterval(message.date)),
            text: text,
            views: message.interactionInfo?.viewCount,
            isChannelPost: message.isChannelPost,
            attachments: attachments,
            rawContentType: contentType,
            customEmojis: customEmojis
        )
    }

    /// Prefer a drawable raster (webp/jpeg) for stickers; fall back to raw tgs/webm file.
    private func exportStickerAttachment(
        _ sticker: Sticker,
        messageID: Int64,
        client: TDLibClient,
        mediaDir: URL,
        downloadMedia: Bool
    ) async throws -> ExportedAttachment? {
        let formatExt: String
        switch sticker.format {
        case .stickerFormatWebp: formatExt = "webp"
        case .stickerFormatTgs: formatExt = "tgs"
        case .stickerFormatWebm: formatExt = "webm"
        }

        // Static webp: download the sticker itself.
        if case .stickerFormatWebp = sticker.format {
            return try await downloadFileIfNeeded(
                sticker.sticker,
                kind: .sticker,
                client: client,
                mediaDir: mediaDir,
                preferredName: "sticker_\(messageID).webp",
                downloadMedia: downloadMedia,
                width: sticker.width,
                height: sticker.height,
                mimeType: "image/webp"
            )
        }

        // Animated (tgs/webm): prefer raster thumbnail for Melingo UI.
        if let thumb = sticker.thumbnail, Self.isRasterThumbnail(thumb.format) {
            let thumbExt = Self.thumbnailExtension(thumb.format)
            if let att = try await downloadFileIfNeeded(
                thumb.file,
                kind: .sticker,
                client: client,
                mediaDir: mediaDir,
                preferredName: "sticker_\(messageID)_thumb.\(thumbExt)",
                downloadMedia: downloadMedia,
                width: thumb.width > 0 ? thumb.width : sticker.width,
                height: thumb.height > 0 ? thumb.height : sticker.height,
                mimeType: thumbExt == "jpg" ? "image/jpeg" : "image/webp"
            ) {
                return att
            }
        }

        return try await downloadFileIfNeeded(
            sticker.sticker,
            kind: .sticker,
            client: client,
            mediaDir: mediaDir,
            preferredName: "sticker_\(messageID).\(formatExt)",
            downloadMedia: downloadMedia,
            width: sticker.width,
            height: sticker.height,
            mimeType: formatExt == "webm" ? "video/webm" : "application/x-tgsticker"
        )
    }

    private static func isRasterThumbnail(_ format: ThumbnailFormat) -> Bool {
        switch format {
        case .thumbnailFormatJpeg, .thumbnailFormatWebp, .thumbnailFormatPng, .thumbnailFormatGif:
            return true
        default:
            return false
        }
    }

    private static func thumbnailExtension(_ format: ThumbnailFormat) -> String {
        switch format {
        case .thumbnailFormatJpeg: return "jpg"
        case .thumbnailFormatPng: return "png"
        case .thumbnailFormatGif: return "gif"
        case .thumbnailFormatWebp: return "webp"
        default: return "webp"
        }
    }

    /// Resolve `textEntityTypeCustomEmoji` → download sticker files (webp / thumbnail / webm).
    private func resolveCustomEmojis(
        in formatted: FormattedText,
        client: TDLibClient,
        mediaDir: URL,
        downloadMedia: Bool
    ) async throws -> [ExportedCustomEmoji] {
        var refs: [(offset: Int, length: Int, id: Int64)] = []
        for entity in formatted.entities {
            if case .textEntityTypeCustomEmoji(let custom) = entity.type {
                refs.append((entity.offset, entity.length, custom.customEmojiId.rawValue))
            }
        }
        guard !refs.isEmpty else { return [] }

        let uniqueIDs = Array(Set(refs.map(\.id))).map { TdInt64($0) }
        let stickers: [Sticker]
        do {
            let result = try await client.getCustomEmojiStickers(customEmojiIds: uniqueIDs)
            stickers = result.stickers
        } catch {
            return refs.map {
                ExportedCustomEmoji(
                    customEmojiId: $0.id,
                    utf16Offset: $0.offset,
                    utf16Length: $0.length
                )
            }
        }

        var byID: [Int64: Sticker] = [:]
        for sticker in stickers {
            if case .stickerFullTypeCustomEmoji(let meta) = sticker.fullType {
                byID[meta.customEmojiId.rawValue] = sticker
            }
        }

        var out: [ExportedCustomEmoji] = []
        out.reserveCapacity(refs.count)
        for ref in refs {
            guard let sticker = byID[ref.id] else {
                out.append(ExportedCustomEmoji(
                    customEmojiId: ref.id,
                    utf16Offset: ref.offset,
                    utf16Length: ref.length
                ))
                continue
            }

            let format: String
            switch sticker.format {
            case .stickerFormatWebp: format = "webp"
            case .stickerFormatTgs: format = "tgs"
            case .stickerFormatWebm: format = "webm"
            }

            var relative: String?
            if downloadMedia {
                relative = try await downloadCustomEmojiDisplayFile(
                    sticker: sticker,
                    customEmojiId: ref.id,
                    client: client,
                    mediaDir: mediaDir
                )
            }

            out.append(ExportedCustomEmoji(
                customEmojiId: ref.id,
                utf16Offset: ref.offset,
                utf16Length: ref.length,
                fallbackEmoji: sticker.emoji,
                format: format,
                localRelativePath: relative,
                width: sticker.width,
                height: sticker.height
            ))
        }
        return out
    }

    /// Always try to land a still image (webp/jpeg) so the reader can draw inline.
    private func downloadCustomEmojiDisplayFile(
        sticker: Sticker,
        customEmojiId: Int64,
        client: TDLibClient,
        mediaDir: URL
    ) async throws -> String? {
        // 1) Static webp sticker file.
        if case .stickerFormatWebp = sticker.format {
            let att = try await downloadFileIfNeeded(
                sticker.sticker,
                kind: .sticker,
                client: client,
                mediaDir: mediaDir,
                preferredName: "custom_emoji_\(customEmojiId).webp",
                downloadMedia: true,
                width: sticker.width,
                height: sticker.height,
                mimeType: "image/webp"
            )
            return att?.localRelativePath
        }

        // 2) Raster thumbnail (tgs / webm custom emoji).
        if let thumb = sticker.thumbnail, Self.isRasterThumbnail(thumb.format) {
            let ext = Self.thumbnailExtension(thumb.format)
            let att = try await downloadFileIfNeeded(
                thumb.file,
                kind: .sticker,
                client: client,
                mediaDir: mediaDir,
                preferredName: "custom_emoji_\(customEmojiId)_thumb.\(ext)",
                downloadMedia: true,
                width: thumb.width > 0 ? thumb.width : sticker.width,
                height: thumb.height > 0 ? thumb.height : sticker.height,
                mimeType: ext == "jpg" ? "image/jpeg" : "image/webp"
            )
            if let path = att?.localRelativePath { return path }
        }

        // 3) Last resort: download the animated asset (UI may still fall back to emoji char).
        let ext: String
        switch sticker.format {
        case .stickerFormatTgs: ext = "tgs"
        case .stickerFormatWebm: ext = "webm"
        case .stickerFormatWebp: ext = "webp"
        }
        let att = try await downloadFileIfNeeded(
            sticker.sticker,
            kind: .sticker,
            client: client,
            mediaDir: mediaDir,
            preferredName: "custom_emoji_\(customEmojiId).\(ext)",
            downloadMedia: true,
            width: sticker.width,
            height: sticker.height
        )
        return att?.localRelativePath
    }

    private func bestPhotoFile(_ photo: Photo) -> File? {
        photo.sizes.max(by: { $0.photo.expectedSize < $1.photo.expectedSize })?.photo
    }

    private func downloadFileIfNeeded(
        _ file: File,
        kind: ExportedAttachment.AttachmentKind,
        client: TDLibClient,
        mediaDir: URL,
        preferredName: String,
        downloadMedia: Bool,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        mimeType: String? = nil
    ) async throws -> ExportedAttachment? {
        guard downloadMedia else {
            return ExportedAttachment(
                kind: kind,
                fileName: preferredName,
                mimeType: mimeType,
                width: width,
                height: height,
                duration: duration,
                fileSize: Int64(file.expectedSize)
            )
        }

        let downloaded = try await client.downloadFile(
            fileId: file.id,
            limit: 0,
            offset: 0,
            priority: 1,
            synchronous: true
        )
        let localPath = downloaded.local.path
        guard !localPath.isEmpty, FileManager.default.fileExists(atPath: localPath) else {
            return ExportedAttachment(
                kind: kind,
                fileName: preferredName,
                mimeType: mimeType,
                width: width,
                height: height,
                duration: duration,
                fileSize: Int64(file.expectedSize)
            )
        }

        let safeName = preferredName.replacingOccurrences(of: "/", with: "_")
        let dest = mediaDir.appendingPathComponent("\(file.id)_\(safeName)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: localPath), to: dest)
        let relative = "media/\(dest.lastPathComponent)"
        return ExportedAttachment(
            kind: kind,
            fileName: safeName,
            mimeType: mimeType,
            localRelativePath: relative,
            width: width,
            height: height,
            duration: duration,
            fileSize: Int64(file.expectedSize)
        )
    }
}
