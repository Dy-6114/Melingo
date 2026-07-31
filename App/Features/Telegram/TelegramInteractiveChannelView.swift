import SwiftUI
import TelegramKit
import Domain
import AppKit

/// Channel feed: bubble geometry from Telegram-Mac `ChatRowItem` / `ChatRowView.bubbleFrame`
/// ([TelegramSwift](https://github.com/overtake/TelegramSwift) — `theme.bubbled` mode).
struct TelegramInteractiveChannelView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let document: ChannelExportDocument
    let mediaRoot: URL?

    @State private var lookupWord: String?
    @State private var lookupSegment: TextSegment?
    @State private var selectedTokenIDs: Set<String> = []
    @State private var showInspector = false

    private var languageHint: String? {
        store.profile.preferredLanguagePair.source
    }

    private var visiblePosts: [ExportedPost] {
        document.posts.filter(\.hasVisibleContent)
    }

    private var chatBackground: Color { theme.background }
    private var bubbleFill: Color {
        colorScheme == .dark ? theme.card.opacity(0.92) : theme.card
    }
    private var headerFill: Color { theme.card }

    var body: some View {
        HSplitView {
            feed
                .frame(minWidth: 380)
            if showInspector, let word = lookupWord, let segment = lookupSegment {
                lookupPane(word: word, segment: segment)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            }
        }
        .background(chatBackground)
        .focusable()
        .onKeyPress(.space) {
            TelegramVideoPlayback.toggleFocusedOrFrontmost()
            return .handled
        }
    }

    private var feed: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            GeometryReader { geo in
                let bubbleMax = TelegramBubbleLayout.bubbleFrameWidth(containerWidth: geo.size.width)
                ScrollView {
                    // ChatRowItem defaultContentTopOffset (bubbled) ≈ 10; row spacing ≈ 2–4.
                    LazyVStack(alignment: .leading, spacing: TelegramBubbleLayout.rowSpacing) {
                        ForEach(visiblePosts) { post in
                            bubble(for: post, bubbleWidth: bubbleMax)
                                .padding(.leading, TelegramBubbleLayout.leftInset)
                                .padding(.trailing, TelegramBubbleLayout.rightInset)
                        }
                    }
                    .padding(.vertical, TelegramBubbleLayout.defaultContentTopOffset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(chatBackground)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            channelAvatar
            VStack(alignment: .leading, spacing: 2) {
                Text(document.channel.title)
                    .font(.headline)
                    .foregroundStyle(theme.foreground)
                HStack(spacing: 6) {
                    if let username = document.channel.username {
                        Text("@\(username)")
                    }
                    if let members = document.channel.memberCount {
                        Text("· \(members.formatted())")
                    }
                    Text("·")
                    Text(String(format: AppL10n.t("telegram.reader.postCount"), visiblePosts.count))
                }
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            }
            Spacer(minLength: 8)
            Text(AppL10n.t("telegram.tapWord"))
                .font(.caption2)
                .foregroundStyle(theme.mutedForeground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(headerFill)
    }

    @ViewBuilder
    private var channelAvatar: some View {
        // ChatRowView.avatarFrame: 36×36
        let size = TelegramBubbleLayout.avatarDiameter
        if let mediaRoot,
           let relative = document.channel.avatarRelativePath,
           let image = NSImage(contentsOf: mediaRoot.appendingPathComponent(relative)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(theme.primary.opacity(0.85))
                    .frame(width: size, height: size)
                Text(String(document.channel.title.prefix(1)).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(theme.primaryForeground)
            }
        }
    }

    /// Incoming row — geometry from Telegram-Mac `ChatRowItem` / `ChatRowView.bubbleFrame`.
    /// Stickers use `hasBubble == false` (ChatRowItem) and float without a chrome bubble.
    private func bubble(for post: ExportedPost, bubbleWidth: CGFloat) -> some View {
        let hasBubble = Self.postHasBubble(post)
        let contentWidth = max(
            1,
            hasBubble
                ? bubbleWidth - TelegramBubbleLayout.bubbleDefaultInnerInset
                : TelegramBubbleLayout.stickerMaxSide
        )
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // Sticker-only rows: hide bare emoji caption (ChatRowItem sticker has no text bubble).
                let trimmed = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let showText = !trimmed.isEmpty
                    && !(Self.isStickerMessage(post) && post.customEmojis.isEmpty)
                if showText {
                    TelegramPostChipText(
                        text: post.text,
                        languageHint: languageHint,
                        selectedIDs: selectedTokenIDs,
                        customEmojis: post.customEmojis,
                        mediaRoot: mediaRoot,
                        onWordTap: { token, additive in
                            handleTap(token: token, post: post, additive: additive)
                        }
                    )
                    .frame(maxWidth: hasBubble ? contentWidth : bubbleWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(post.attachments.filter(\.isRenderable)) { attachment in
                    TelegramMediaAttachmentView(
                        attachment: attachment,
                        mediaRoot: mediaRoot,
                        maxWidth: attachment.kind == .sticker
                            ? TelegramBubbleLayout.stickerMaxSide
                            : contentWidth,
                        maxHeight: attachment.kind == .sticker
                            ? TelegramBubbleLayout.stickerMaxSide
                            : TelegramBubbleLayout.videoMaxHeight,
                        linkColor: theme.primary
                    )
                }
                mosaicStatus(for: post, overlayOnMedia: !hasBubble)
            }
            .padding(.leading, hasBubble
                ? TelegramBubbleLayout.bubbleContentInset + TelegramBubbleLayout.additionBubbleInset
                : 0)
            .padding(.trailing, hasBubble ? TelegramBubbleLayout.bubbleContentInset : 0)
            .padding(.vertical, hasBubble ? 8 : 2)
            .frame(
                width: hasBubble ? bubbleWidth : nil,
                alignment: .leading
            )
            .background {
                if hasBubble {
                    RoundedRectangle(cornerRadius: TelegramBubbleLayout.cornerRadius, style: .continuous)
                        .fill(bubbleFill)
                }
            }
            .overlay {
                if hasBubble {
                    RoundedRectangle(cornerRadius: TelegramBubbleLayout.cornerRadius, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// `ChatRowItem.hasBubble` — static/animated/video stickers → no bubble.
    private static func postHasBubble(_ post: ExportedPost) -> Bool {
        if isStickerMessage(post) { return false }
        return true
    }

    private static func isStickerMessage(_ post: ExportedPost) -> Bool {
        if post.rawContentType == "sticker" { return true }
        let stickers = post.attachments.filter { $0.kind == .sticker && $0.localRelativePath != nil }
        let others = post.attachments.filter { $0.kind != .sticker && $0.isRenderable }
        return !stickers.isEmpty && others.isEmpty
    }

    private func mosaicStatus(for post: ExportedPost, overlayOnMedia: Bool) -> some View {
        // ChatRowItem.isStateOverlayLayout: stickers get status overlaid at the bottom.
        HStack(spacing: 4) {
            Spacer(minLength: TelegramBubbleLayout.insetBetweenContentAndDate)
            if let views = post.views {
                Image(systemName: "eye")
                    .font(.system(size: 10, weight: .medium))
                Text(TelegramBubbleLayout.formatViewCount(views))
                    .font(.system(size: 11, weight: .regular))
                Text("·")
                    .font(.system(size: 11))
            }
            Text(post.date, format: .dateTime.hour().minute())
                .font(.system(size: 11, weight: .regular))
        }
        .foregroundStyle(overlayOnMedia ? Color.white.opacity(0.92) : theme.mutedForeground)
        .padding(.horizontal, overlayOnMedia ? 6 : 0)
        .padding(.vertical, overlayOnMedia ? 3 : 2)
        .background {
            if overlayOnMedia {
                Capsule().fill(Color.black.opacity(0.35))
            }
        }
        .padding(.top, overlayOnMedia ? -22 : 2)
        .padding(.bottom, 2)
    }

    private func handleTap(token: WordToken, post: ExportedPost, additive: Bool) {
        if additive {
            if selectedTokenIDs.contains(token.id) {
                selectedTokenIDs.remove(token.id)
            } else {
                selectedTokenIDs.insert(token.id)
            }
            return
        }
        selectedTokenIDs = [token.id]
        let segment = TextSegment(
            documentID: UUID(),
            order: 0,
            text: post.text
        )
        lookupWord = token.text
        lookupSegment = segment
        showInspector = true
    }

    private func lookupPane(word: String, segment: TextSegment) -> some View {
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
            Divider().opacity(0.4)
            ScrollView {
                WordLookupPopover(
                    word: word,
                    segment: segment,
                    documentTitle: document.channel.title,
                    canSpeak: true
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(theme.card)
    }
}

/// Telegram-Mac metrics from `ChatRowItem` + `ChatLayoutUtils.contentSize`.
/// Source: overtake/TelegramSwift `Telegram-Mac/ChatRowItem.swift`.
enum TelegramBubbleLayout {
    /// `ChatRowView.avatarFrame` — 36×36.
    static let avatarDiameter: CGFloat = 36
    /// `leftInset` when bubbled.
    static let leftInset: CGFloat = 20
    /// `rightInset` when bubbled.
    static let rightInset: CGFloat = 15
    /// `defaultContentTopOffset` when bubbled.
    static let defaultContentTopOffset: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    /// `bubbleContentInset`
    static let bubbleContentInset: CGFloat = 11
    /// `additionBubbleInset`
    static let additionBubbleInset: CGFloat = 6
    /// `bubbleContentInset * 2 + additionBubbleInset`
    static var bubbleDefaultInnerInset: CGFloat {
        bubbleContentInset * 2 + additionBubbleInset
    }
    /// `insetBetweenContentAndDate`
    static let insetBetweenContentAndDate: CGFloat = 10
    /// `min_block_width`
    static let minBlockWidth: CGFloat = 450
    static let cornerRadius: CGFloat = 18
    /// `ChatLayoutUtils`: media fitted into `min(width, 320)`.
    static let mediaMaxSide: CGFloat = 320
    static let videoMaxHeight: CGFloat = 320
    static let imageMax: CGFloat = 320
    /// `ChatLayoutUtils`: static sticker aspectFitted(208×208).
    static let stickerMaxSide: CGFloat = 208
    /// `ChatLayoutUtils`: custom / animated emoji sticker 112×112.
    static let customEmojiStickerSide: CGFloat = 112
    /// Inline custom emoji in text (~line height).
    static let inlineCustomEmojiSide: CGFloat = 20

    /// Mirrors `ChatRowItem.blockWidth` for an incoming channel post without row avatar,
    /// then adds `bubbleDefaultInnerInset` like `bubbleFrame` width growth.
    static func bubbleFrameWidth(containerWidth: CGFloat) -> CGFloat {
        // contentOffset.x ≈ defLeftInset = leftInset (no photo in broadcast).
        let contentOffsetX = leftInset
        // tempWidth = width - contentOffset.x - bubbleDefaultInnerInset - (20 + 10 + additionBubbleInset) - 20
        let tempWidth = containerWidth
            - contentOffsetX
            - bubbleDefaultInnerInset
            - (20 + 10 + additionBubbleInset)
            - 20
        let block = min(max(120, tempWidth), minBlockWidth)
        return block + bubbleDefaultInnerInset
    }

    /// Compact view count like Telegram (`1.2K`).
    static func formatViewCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            let v = Double(count) / 1_000_000
            return String(format: v >= 10 ? "%.0fM" : "%.1fM", v)
                .replacingOccurrences(of: ".0", with: "")
        case 1_000...:
            let v = Double(count) / 1_000
            return String(format: v >= 10 ? "%.0fK" : "%.1fK", v)
                .replacingOccurrences(of: ".0", with: "")
        default:
            return "\(count)"
        }
    }
}

private extension ExportedPost {
    var hasVisibleContent: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return true }
        return attachments.contains(where: \.isRenderable)
    }
}

private extension ExportedAttachment {
    var isRenderable: Bool {
        guard let relative = localRelativePath, !relative.isEmpty else { return false }
        switch kind {
        case .photo, .sticker, .animation, .video:
            return true
        case .document, .other:
            let name = (fileName ?? relative).lowercased()
            let mime = (mimeType ?? "").lowercased()
            return name.hasSuffix(".webp") || name.hasSuffix(".webm") || name.hasSuffix(".gif")
                || name.hasSuffix(".mp4") || name.hasSuffix(".png") || name.hasSuffix(".jpg")
                || mime.hasPrefix("image/") || mime.hasPrefix("video/")
        case .audio, .voice:
            return true
        }
    }
}
