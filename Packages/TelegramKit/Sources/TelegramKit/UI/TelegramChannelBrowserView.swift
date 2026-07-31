import SwiftUI
import AppKit
import ImageIO
import AVKit

/// Telegram Desktop–inspired palette for channel browsing only.
public enum TelegramChrome {
    public static let accent = ColorHex(0x2AABEE)
    public static let chatBackground = ColorHex(0x0E1621)
    public static let headerBackground = ColorHex(0x17212B)
    public static let bubbleIncoming = ColorHex(0x182533)
    public static let bubbleOutgoing = ColorHex(0x2B5278)
    public static let primaryText = ColorHex(0xF5F5F5)
    public static let secondaryText = ColorHex(0x6D7F8F)
    public static let divider = ColorHex(0x0F1A24)
    public static let link = ColorHex(0x6AB3F3)
    public static let serviceText = ColorHex(0x7E8B99)
}

public struct ColorHex: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }
}

extension Color {
    public init(tg hex: ColorHex) {
        self.init(
            .sRGB,
            red: hex.red,
            green: hex.green,
            blue: hex.blue,
            opacity: hex.alpha
        )
    }
}

/// Telegram Desktop–inspired channel browser (shared by Melingo and Telegram Viewer).
public struct TelegramChannelBrowserView: View {
    public let document: ChannelExportDocument
    public let mediaRoot: URL?

    public init(document: ChannelExportDocument, mediaRoot: URL?) {
        self.document = document
        self.mediaRoot = mediaRoot
    }

    private var visiblePosts: [ExportedPost] {
        document.posts.filter { post in
            let trimmed = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return true }
            return post.attachments.contains { $0.localRelativePath?.isEmpty == false }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color(tg: TelegramChrome.divider))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visiblePosts) { post in
                        TelegramMessageBubble(post: post, mediaRoot: mediaRoot)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color(tg: TelegramChrome.chatBackground))
        }
        .background(Color(tg: TelegramChrome.chatBackground))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(tg: TelegramChrome.accent).opacity(0.85))
                    .frame(width: 42, height: 42)
                Text(String(document.channel.title.prefix(1)).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(document.channel.title)
                    .font(.headline)
                    .foregroundStyle(Color(tg: TelegramChrome.primaryText))
                HStack(spacing: 6) {
                    if let username = document.channel.username {
                        Text("@\(username)")
                    }
                    if let members = document.channel.memberCount {
                        Text("· \(members.formatted()) subscribers")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
            }
            Spacer()
            Text("\(visiblePosts.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(tg: TelegramChrome.headerBackground))
    }
}

struct TelegramMessageBubble: View {
    let post: ExportedPost
    let mediaRoot: URL?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                if !post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(post.text)
                        .font(.body)
                        .foregroundStyle(Color(tg: TelegramChrome.primaryText))
                        .textSelection(.enabled)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                ForEach(post.attachments.filter { $0.localRelativePath?.isEmpty == false }) { attachment in
                    attachmentView(attachment)
                }
                HStack(spacing: 8) {
                    Text(post.date, format: .dateTime.hour().minute())
                    if let views = post.views {
                        Text("· \(views.formatted())")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(tg: TelegramChrome.bubbleIncoming))
            )
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ExportedAttachment) -> some View {
        let url = localURL(attachment)
        switch attachment.kind {
        case .photo, .sticker:
            if let url, let nsImage = Self.loadImage(at: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: attachment.kind == .sticker ? 180 : 360,
                        maxHeight: attachment.kind == .sticker ? 180 : 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                label(attachment.fileName ?? (attachment.kind == .sticker ? "Sticker" : "Photo"),
                      system: attachment.kind == .sticker ? "face.smiling" : "photo")
            }
        case .video, .animation:
            if let url {
                TelegramKitLoopingVideo(url: url)
                    .frame(width: 320, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                label(attachment.fileName ?? "Video", system: "video")
            }
        case .audio, .voice:
            label(attachment.fileName ?? "Audio", system: "waveform")
        case .document, .other:
            if let url, Self.isImagePath(url), let nsImage = Self.loadImage(at: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let url, Self.isVideoPath(url) {
                TelegramKitLoopingVideo(url: url)
                    .frame(width: 320, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                label(attachment.fileName ?? "File", system: "doc")
            }
        }
    }

    private func label(_ title: String, system: String) -> some View {
        Label(title, systemImage: system)
            .font(.caption)
            .foregroundStyle(Color(tg: TelegramChrome.link))
    }

    private func localURL(_ attachment: ExportedAttachment) -> URL? {
        guard let relative = attachment.localRelativePath, let mediaRoot else { return nil }
        let url = mediaRoot.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func isImagePath(_ url: URL) -> Bool {
        ["webp", "png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())
    }

    private static func isVideoPath(_ url: URL) -> Bool {
        ["mp4", "webm", "mov"].contains(url.pathExtension.lowercased())
    }

    private static func loadImage(at url: URL) -> NSImage? {
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct TelegramKitLoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        let player = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        view.player = player
        player.isMuted = true
        player.play()
        context.coordinator.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper = nil
        coordinator.player = nil
        nsView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}
