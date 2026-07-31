import AppKit
import AVFoundation
import SwiftUI
import TelegramKit
import ImageIO

/// Renders Telegram photos, stickers (webp), and animations/videos (mp4/webm/gif) inline.
/// Sticker sizing follows Telegram-Mac `ChatLayoutUtils.contentSize` (208×208 aspectFitted).
struct TelegramMediaAttachmentView: View {
    let attachment: ExportedAttachment
    let mediaRoot: URL?
    var maxWidth: CGFloat = 360
    var maxHeight: CGFloat = 280
    var linkColor: Color = Color(tg: TelegramChrome.link)

    var body: some View {
        switch attachment.kind {
        case .sticker:
            stickerBlock
        case .photo:
            imageBlock(fallbackSystem: "photo",
                       fallbackTitle: attachment.fileName ?? AppL10n.t("telegram.media.photo"),
                       isSticker: false)
        case .animation, .video:
            videoOrAnimatedBlock
        case .audio, .voice:
            label(attachment.fileName ?? AppL10n.t("telegram.media.audio"), system: "waveform")
        case .document:
            if isImageFile {
                imageBlock(fallbackSystem: "doc",
                           fallbackTitle: attachment.fileName ?? AppL10n.t("telegram.media.file"),
                           isSticker: looksLikeStickerFile)
            } else if isVideoFile {
                videoOrAnimatedBlock
            } else {
                label(attachment.fileName ?? AppL10n.t("telegram.media.file"), system: "doc")
            }
        case .other:
            if isImageFile {
                imageBlock(fallbackSystem: "paperclip",
                           fallbackTitle: attachment.fileName ?? AppL10n.t("telegram.media.attachment"),
                           isSticker: looksLikeStickerFile)
            } else if isVideoFile {
                videoOrAnimatedBlock
            } else {
                label(attachment.fileName ?? AppL10n.t("telegram.media.attachment"), system: "paperclip")
            }
        }
    }

    /// WebP / JPEG sticker — no bubble chrome, transparent, aspectFitted(208).
    @ViewBuilder
    private var stickerBlock: some View {
        if let url = localURL, let image = TelegramRasterImage.load(at: url, maxPixelSize: 512) {
            let fitted = Self.aspectFitted(
                intrinsic: image.size,
                maxSide: min(maxWidth, maxHeight, TelegramBubbleLayout.stickerMaxSide)
            )
            Image(nsImage: image)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fitted.width, height: fitted.height)
        } else {
            label(attachment.fileName ?? AppL10n.t("telegram.media.sticker"), system: "face.smiling")
        }
    }

    @ViewBuilder
    private var videoOrAnimatedBlock: some View {
        if let url = localURL {
            let ext = url.pathExtension.lowercased()
            if ["gif", "webp", "png", "jpg", "jpeg"].contains(ext),
               let image = TelegramRasterImage.load(at: url, maxPixelSize: 1024) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: TelegramBubbleLayout.cornerRadius, style: .continuous))
            } else {
                TelegramLoopingVideoView(url: url)
                    .frame(
                        width: displayWidth,
                        height: displayHeight
                    )
                    .clipShape(RoundedRectangle(cornerRadius: TelegramBubbleLayout.cornerRadius, style: .continuous))
            }
        } else {
            label(attachment.fileName ?? AppL10n.t("telegram.media.video"), system: "video")
        }
    }

    @ViewBuilder
    private func imageBlock(fallbackSystem: String, fallbackTitle: String, isSticker: Bool) -> some View {
        if isSticker {
            stickerBlock
        } else if let url = localURL, let image = TelegramRasterImage.load(at: url, maxPixelSize: 1280) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: min(maxWidth, TelegramBubbleLayout.imageMax),
                    maxHeight: min(maxHeight, TelegramBubbleLayout.videoMaxHeight)
                )
                .clipShape(RoundedRectangle(cornerRadius: TelegramBubbleLayout.cornerRadius, style: .continuous))
        } else {
            label(fallbackTitle, system: fallbackSystem)
        }
    }

    private func label(_ title: String, system: String) -> some View {
        Label(title, systemImage: system)
            .font(.caption)
            .foregroundStyle(linkColor)
            .lineLimit(2)
    }

    private var localURL: URL? {
        guard let relative = attachment.localRelativePath, let mediaRoot else { return nil }
        let url = mediaRoot.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var looksLikeStickerFile: Bool {
        let name = (attachment.fileName ?? attachment.localRelativePath ?? "").lowercased()
        return name.contains("sticker") || name.hasSuffix(".webp")
    }

    private var isImageFile: Bool {
        let name = (attachment.fileName ?? attachment.localRelativePath ?? "").lowercased()
        let mime = (attachment.mimeType ?? "").lowercased()
        return name.hasSuffix(".webp") || name.hasSuffix(".png") || name.hasSuffix(".jpg")
            || name.hasSuffix(".jpeg") || name.hasSuffix(".gif")
            || mime.contains("image/")
    }

    private var isVideoFile: Bool {
        let name = (attachment.fileName ?? attachment.localRelativePath ?? "").lowercased()
        let mime = (attachment.mimeType ?? "").lowercased()
        return name.hasSuffix(".mp4") || name.hasSuffix(".webm") || name.hasSuffix(".mov")
            || mime.contains("video/") || mime.contains("webm")
    }

    private var displayWidth: CGFloat {
        if let w = attachment.width, let h = attachment.height, w > 0, h > 0 {
            let scale = min(maxWidth / CGFloat(w), maxHeight / CGFloat(h), 1)
            return max(120, CGFloat(w) * scale)
        }
        return maxWidth
    }

    private var displayHeight: CGFloat {
        if let w = attachment.width, let h = attachment.height, w > 0, h > 0 {
            let scale = min(maxWidth / CGFloat(w), maxHeight / CGFloat(h), 1)
            return max(90, CGFloat(h) * scale)
        }
        return 200
    }

    /// Same idea as Telegram-Mac `aspectFitted` into a square box.
    private static func aspectFitted(intrinsic: NSSize, maxSide: CGFloat) -> CGSize {
        let w = max(intrinsic.width, 1)
        let h = max(intrinsic.height, 1)
        let scale = min(maxSide / w, maxSide / h, 1)
        return CGSize(
            width: max(40, floor(w * scale)),
            height: max(40, floor(h * scale))
        )
    }
}

/// Tracks focused / frontmost Telegram inline videos so Space can pause/play.
@MainActor
enum TelegramVideoPlayback {
    private static weak var focused: AVQueuePlayer?
    private static var registry: [ObjectIdentifier: WeakPlayer] = [:]

    private final class WeakPlayer {
        weak var player: AVQueuePlayer?
        init(_ player: AVQueuePlayer) { self.player = player }
    }

    static func register(_ player: AVQueuePlayer) {
        registry[ObjectIdentifier(player)] = WeakPlayer(player)
        prune()
    }

    static func unregister(_ player: AVQueuePlayer) {
        registry.removeValue(forKey: ObjectIdentifier(player))
        if focused === player { focused = nil }
    }

    static func focus(_ player: AVQueuePlayer) {
        focused = player
    }

    static func toggleFocusedOrFrontmost() {
        prune()
        if let focused {
            toggle(focused)
            return
        }
        // Prefer a currently playing clip; else the first registered.
        let players = registry.values.compactMap(\.player)
        if let playing = players.first(where: { $0.rate > 0 }) {
            toggle(playing)
        } else if let any = players.first {
            toggle(any)
        }
    }

    private static func toggle(_ player: AVQueuePlayer) {
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }

    private static func prune() {
        registry = registry.filter { $0.value.player != nil }
        if let focused, focused.rate.isNaN { self.focused = nil }
        if let focused, registry[ObjectIdentifier(focused)] == nil {
            self.focused = nil
        }
    }
}

/// Autoplaying, muted, looping clip — plain `AVPlayerLayer` (no AVPlayerView Mute chrome).
/// Click to focus; Space (via `TelegramVideoPlayback`) pauses/plays.
struct TelegramLoopingVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> TelegramPlayerLayerView {
        let view = TelegramPlayerLayerView()
        let player = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        view.attach(player: player)
        view.onFocus = { [weak player] in
            guard let player else { return }
            TelegramVideoPlayback.focus(player)
        }
        player.play()
        context.coordinator.player = player
        TelegramVideoPlayback.register(player)
        return view
    }

    func updateNSView(_ nsView: TelegramPlayerLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: TelegramPlayerLayerView, coordinator: Coordinator) {
        if let player = coordinator.player {
            player.pause()
            TelegramVideoPlayback.unregister(player)
        }
        coordinator.looper = nil
        nsView.attach(player: nil)
        coordinator.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}

final class TelegramPlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    var onFocus: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    func attach(player: AVPlayer?) {
        playerLayer.player = player
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        // Click also toggles play/pause (Telegram-like).
        if let queue = playerLayer.player as? AVQueuePlayer {
            if queue.rate > 0 { queue.pause() } else { queue.play() }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onFocus?()
            TelegramVideoPlayback.toggleFocusedOrFrontmost()
            return
        }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
