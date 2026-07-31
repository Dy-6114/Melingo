import Foundation
@preconcurrency import TDLibKit

/// A Melingo / Firebase login slot (one Telegram account session).
public struct CollectedTelegramUser: Identifiable, Sendable, Hashable {
    public var id: String { sessionKey }
    public var sessionKey: String
    public var source: Source
    public var phoneHint: String?
    public var updatedAt: Foundation.Date?
    public var totalBytes: Int?
    public var displayName: String?

    public enum Source: String, Sendable, Hashable {
        case firebase
        case local
    }

    public init(
        sessionKey: String,
        source: Source,
        phoneHint: String? = nil,
        updatedAt: Foundation.Date? = nil,
        totalBytes: Int? = nil,
        displayName: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.source = source
        self.phoneHint = phoneHint
        self.updatedAt = updatedAt
        self.totalBytes = totalBytes
        self.displayName = displayName
    }

    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let phoneHint { return "\(sessionKey) ···\(phoneHint)" }
        return sessionKey
    }
}

/// A channel / broadcast chat discovered for the chosen user.
public struct CollectedTelegramChannel: Identifiable, Sendable, Hashable {
    public var id: Int64 { chatId }
    public var chatId: Int64
    public var title: String
    public var username: String?
    public var memberCount: Int?
    public var isChannel: Bool

    public init(
        chatId: Int64,
        title: String,
        username: String? = nil,
        memberCount: Int? = nil,
        isChannel: Bool = true
    ) {
        self.chatId = chatId
        self.title = title
        self.username = username
        self.memberCount = memberCount
        self.isChannel = isChannel
    }

    public var label: String {
        if let username, !username.isEmpty {
            return "\(title) (@\(username))"
        }
        return title
    }
}

public enum TelegramCollectService {
    /// List account slots: Firebase `tdlib_sessions/*` + local key if present.
    public static func collectUsers(
        store: FirebaseTDLibSessionStore = FirebaseTDLibSessionStore()
    ) async throws -> [CollectedTelegramUser] {
        var byKey: [String: CollectedTelegramUser] = [:]

        let remoteKeys = (try? await store.listSessionKeys()) ?? []
        for key in remoteKeys {
            if let meta = try? await store.peekMeta(sessionKey: key) {
                byKey[key] = CollectedTelegramUser(
                    sessionKey: key,
                    source: .firebase,
                    phoneHint: meta.phoneHint,
                    updatedAt: meta.updatedAt,
                    totalBytes: meta.totalBytes
                )
            } else {
                byKey[key] = CollectedTelegramUser(sessionKey: key, source: .firebase)
            }
        }

        let localKey = TelegramPaths.loadOrCreateSessionKey()
        let kids = try? FileManager.default.contentsOfDirectory(
            at: TelegramPaths.tdlibDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let hasLocal = !(kids?.isEmpty ?? true)
        if hasLocal {
            if var existing = byKey[localKey] {
                existing.displayName = "\(existing.label) · also on this Mac"
                byKey[localKey] = existing
            } else {
                byKey[localKey] = CollectedTelegramUser(
                    sessionKey: localKey,
                    source: .local,
                    displayName: "\(localKey) (this Mac)"
                )
            }
        }

        return byKey.values.sorted { $0.sessionKey.localizedCaseInsensitiveCompare($1.sessionKey) == .orderedAscending }
    }

    /// Load chat list and keep channels / public-ish supergroups.
    public static func collectChannels(
        client: TDLibClient,
        limit: Int = 200
    ) async throws -> [CollectedTelegramChannel] {
        // Warm the main list (404 = already fully loaded).
        for _ in 0..<8 {
            do {
                _ = try await client.loadChats(chatList: .chatListMain, limit: 100)
            } catch {
                break
            }
        }

        let chats = try await client.getChats(chatList: .chatListMain, limit: limit)
        var result: [CollectedTelegramChannel] = []

        for chatId in chats.chatIds {
            let chat = try await client.getChat(chatId: chatId)
            guard case .chatTypeSupergroup(let info) = chat.type else { continue }
            let sg = try await client.getSupergroup(supergroupId: info.supergroupId)
            guard sg.isChannel else { continue }

            let username = sg.usernames?.activeUsernames.first
                ?? (sg.usernames?.editableUsername.isEmpty == false ? sg.usernames?.editableUsername : nil)

            var memberCount: Int?
            if let full = try? await client.getSupergroupFullInfo(supergroupId: info.supergroupId) {
                memberCount = full.memberCount
            }

            result.append(
                CollectedTelegramChannel(
                    chatId: chat.id,
                    title: chat.title,
                    username: username,
                    memberCount: memberCount,
                    isChannel: true
                )
            )
        }

        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func currentAccountLabel(client: TDLibClient) async -> String? {
        guard let me = try? await client.getMe() else { return nil }
        let user = me.usernames?.activeUsernames.first.map { "@\($0)" }
        let name = [me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if let user, !name.isEmpty { return "\(name) (\(user))" }
        return user ?? (name.isEmpty ? nil : name)
    }
}
