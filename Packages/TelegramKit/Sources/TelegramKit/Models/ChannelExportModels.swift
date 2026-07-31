import Foundation

public enum TelegramKitError: Error, Sendable, Equatable {
    case notConfigured
    case notAuthorized
    case channelNotFound(String)
    case exportFailed(String)
    case sessionSyncFailed(String)
    case tdlib(String)
}

/// Top-level JSON document written to `channel.json`.
public struct ChannelExportDocument: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var channel: ChannelMeta
    public var posts: [ExportedPost]
    /// True when an older page returned fewer than a full page — no more history.
    public var reachedHistoryEnd: Bool

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = .now,
        channel: ChannelMeta,
        posts: [ExportedPost],
        reachedHistoryEnd: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.channel = channel
        self.posts = posts
        self.reachedHistoryEnd = reachedHistoryEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? .now
        channel = try c.decode(ChannelMeta.self, forKey: .channel)
        posts = try c.decodeIfPresent([ExportedPost].self, forKey: .posts) ?? []
        reachedHistoryEnd = try c.decodeIfPresent(Bool.self, forKey: .reachedHistoryEnd) ?? false
    }
}

public struct ChannelMeta: Codable, Sendable, Hashable {
    public var id: Int64
    public var username: String?
    public var title: String
    public var description: String?
    public var memberCount: Int?
    /// Relative path under the export folder, e.g. `media/avatar.jpg`.
    public var avatarRelativePath: String?

    public init(
        id: Int64,
        username: String? = nil,
        title: String,
        description: String? = nil,
        memberCount: Int? = nil,
        avatarRelativePath: String? = nil
    ) {
        self.id = id
        self.username = username
        self.title = title
        self.description = description
        self.memberCount = memberCount
        self.avatarRelativePath = avatarRelativePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount)
        avatarRelativePath = try c.decodeIfPresent(String.self, forKey: .avatarRelativePath)
    }
}

public struct ExportedPost: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var date: Date
    public var text: String
    public var views: Int?
    public var isChannelPost: Bool
    public var attachments: [ExportedAttachment]
    public var rawContentType: String
    /// Inline custom emoji referenced by UTF-16 offsets in `text`.
    public var customEmojis: [ExportedCustomEmoji]

    public init(
        id: Int64,
        date: Date,
        text: String,
        views: Int? = nil,
        isChannelPost: Bool = true,
        attachments: [ExportedAttachment] = [],
        rawContentType: String = "text",
        customEmojis: [ExportedCustomEmoji] = []
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.views = views
        self.isChannelPost = isChannelPost
        self.attachments = attachments
        self.rawContentType = rawContentType
        self.customEmojis = customEmojis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        views = try c.decodeIfPresent(Int.self, forKey: .views)
        isChannelPost = try c.decodeIfPresent(Bool.self, forKey: .isChannelPost) ?? true
        attachments = try c.decodeIfPresent([ExportedAttachment].self, forKey: .attachments) ?? []
        rawContentType = try c.decodeIfPresent(String.self, forKey: .rawContentType) ?? "text"
        customEmojis = try c.decodeIfPresent([ExportedCustomEmoji].self, forKey: .customEmojis) ?? []
    }
}

/// Custom emoji placed inline in post text (Telegram Premium packs).
public struct ExportedCustomEmoji: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(customEmojiId)-\(utf16Offset)" }
    public var customEmojiId: Int64
    /// Offset into `ExportedPost.text` in UTF-16 code units (TDLib entity offset).
    public var utf16Offset: Int
    public var utf16Length: Int
    public var fallbackEmoji: String
    /// `webp` | `tgs` | `webm`
    public var format: String
    public var localRelativePath: String?
    public var width: Int?
    public var height: Int?

    public init(
        customEmojiId: Int64,
        utf16Offset: Int,
        utf16Length: Int,
        fallbackEmoji: String = "",
        format: String = "webp",
        localRelativePath: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.customEmojiId = customEmojiId
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
        self.fallbackEmoji = fallbackEmoji
        self.format = format
        self.localRelativePath = localRelativePath
        self.width = width
        self.height = height
    }
}

public struct ExportedAttachment: Codable, Sendable, Hashable, Identifiable {
    public enum AttachmentKind: String, Codable, Sendable, Hashable {
        case photo
        case video
        case animation
        case audio
        case voice
        case document
        case sticker
        case other
    }

    public var id: String
    public var kind: AttachmentKind
    public var fileName: String?
    public var mimeType: String?
    public var localRelativePath: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var fileSize: Int64?

    public init(
        id: String = UUID().uuidString,
        kind: AttachmentKind,
        fileName: String? = nil,
        mimeType: String? = nil,
        localRelativePath: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.localRelativePath = localRelativePath
        self.width = width
        self.height = height
        self.duration = duration
        self.fileSize = fileSize
    }
}
