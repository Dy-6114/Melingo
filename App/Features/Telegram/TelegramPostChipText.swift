import AppKit
import SwiftUI
import Domain
import TelegramKit
import ImageIO

/// Inline word chips for a Telegram post — same hit-testing as the Melingo reader,
/// with custom emoji (TDLib `textEntityTypeCustomEmoji`) drawn as inline images.
struct TelegramPostChipText: NSViewRepresentable {
    let text: String
    let languageHint: String?
    let selectedIDs: Set<String>
    var customEmojis: [ExportedCustomEmoji] = []
    var mediaRoot: URL?
    let onWordTap: (WordToken, Bool) -> Void

    func makeNSView(context: Context) -> TelegramPostChipHost {
        let host = TelegramPostChipHost()
        host.onWordTap = onWordTap
        return host
    }

    func updateNSView(_ host: TelegramPostChipHost, context: Context) {
        host.onWordTap = onWordTap
        host.apply(
            text: text,
            languageHint: languageHint,
            selectedIDs: selectedIDs,
            customEmojis: customEmojis,
            mediaRoot: mediaRoot
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TelegramPostChipHost, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        let height = nsView.height(forWidth: max(width, 120))
        return CGSize(width: width, height: max(height, 20))
    }
}

final class TelegramPostChipHost: NSView {
    var onWordTap: ((WordToken, Bool) -> Void)?

    private let chipView = WordChipProseView()
    private var segmentID = UUID()
    private var lastText = ""
    private var lastEmojiSignature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        chipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipView)
        NSLayoutConstraint.activate([
            chipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipView.topAnchor.constraint(equalTo: topAnchor),
            chipView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        chipView.onTap = { [weak self] token, additive in
            self?.onWordTap?(token, additive)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(
        text: String,
        languageHint: String?,
        selectedIDs: Set<String>,
        customEmojis: [ExportedCustomEmoji],
        mediaRoot: URL?
    ) {
        let emojiSig = customEmojis.map { "\($0.customEmojiId):\($0.utf16Offset):\($0.localRelativePath ?? "")" }.joined(separator: "|")
        if text != lastText || emojiSig != lastEmojiSignature {
            lastText = text
            lastEmojiSignature = emojiSig
            segmentID = UUID()
        }

        let built = Self.buildTokens(
            text: text,
            languageHint: languageHint,
            segmentID: segmentID,
            customEmojis: customEmojis,
            mediaRoot: mediaRoot
        )

        let textColor = NSColor.labelColor
        let muted = NSColor.controlAccentColor.withAlphaComponent(0.85)
        let selection = NSColor.controlAccentColor.withAlphaComponent(0.28)
        chipView.apply(
            tokens: built.tokens,
            fontSize: 15,
            selectedIDs: selectedIDs,
            textColor: textColor,
            mutedColor: muted,
            selectionFill: selection,
            imagesByIndex: built.images
        )
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        chipView.height(forWidth: width)
    }

    override var intrinsicContentSize: NSSize {
        let w = bounds.width > 1 ? bounds.width : 480
        return NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: w))
    }

    override func layout() {
        super.layout()
        chipView.refreshFrames()
        invalidateIntrinsicContentSize()
    }

    /// Split text on custom-emoji UTF-16 spans; tokenize plain parts; attach images.
    private static func buildTokens(
        text: String,
        languageHint: String?,
        segmentID: UUID,
        customEmojis: [ExportedCustomEmoji],
        mediaRoot: URL?
    ) -> (tokens: [WordToken], images: [Int: NSImage]) {
        guard !customEmojis.isEmpty else {
            return (WordTokenizer.tokens(in: text, languageHint: languageHint, segmentID: segmentID), [:])
        }

        let sorted = customEmojis.sorted { $0.utf16Offset < $1.utf16Offset }
        var tokens: [WordToken] = []
        var images: [Int: NSImage] = [:]
        var index = 0
        var utf16Cursor = 0
        let utf16Count = text.utf16.count

        func stringIndex(utf16Offset: Int) -> String.Index? {
            guard utf16Offset >= 0, utf16Offset <= utf16Count else { return nil }
            return text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset, limitedBy: text.utf16.endIndex)
                .flatMap { String.Index($0, within: text) }
        }

        for emoji in sorted {
            let start = max(utf16Cursor, emoji.utf16Offset)
            let end = min(utf16Count, emoji.utf16Offset + max(1, emoji.utf16Length))
            if start > utf16Cursor, let from = stringIndex(utf16Offset: utf16Cursor), let to = stringIndex(utf16Offset: start) {
                let slice = String(text[from..<to])
                for token in WordTokenizer.tokens(in: slice, languageHint: languageHint, segmentID: segmentID) {
                    tokens.append(WordToken(
                        text: token.text,
                        range: token.range,
                        isWord: token.isWord,
                        segmentID: segmentID,
                        index: index
                    ))
                    index += 1
                }
            }

            if end > start {
                let fallback = emoji.fallbackEmoji.isEmpty ? " " : emoji.fallbackEmoji
                if let from = stringIndex(utf16Offset: start), let to = stringIndex(utf16Offset: end) {
                    let range = from..<to
                    tokens.append(WordToken(
                        text: fallback,
                        range: range,
                        isWord: false,
                        segmentID: segmentID,
                        index: index
                    ))
                } else {
                    tokens.append(WordToken(
                        text: fallback,
                        range: text.startIndex..<text.startIndex,
                        isWord: false,
                        segmentID: segmentID,
                        index: index
                    ))
                }
                if let image = loadCustomEmojiImage(emoji, mediaRoot: mediaRoot) {
                    images[index] = image
                }
                index += 1
                utf16Cursor = end
            }
        }

        if utf16Cursor < utf16Count, let from = stringIndex(utf16Offset: utf16Cursor) {
            let slice = String(text[from...])
            for token in WordTokenizer.tokens(in: slice, languageHint: languageHint, segmentID: segmentID) {
                tokens.append(WordToken(
                    text: token.text,
                    range: token.range,
                    isWord: token.isWord,
                    segmentID: segmentID,
                    index: index
                ))
                index += 1
            }
        }

        return (tokens, images)
    }

    private static func loadCustomEmojiImage(_ emoji: ExportedCustomEmoji, mediaRoot: URL?) -> NSImage? {
        guard let mediaRoot, let relative = emoji.localRelativePath else { return nil }
        let url = mediaRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Prefer ImageIO (webp / gif first frame); skip non-raster (tgs/webm) → fallback glyph.
        guard TelegramRasterImage.isRasterPath(url.path) else { return nil }
        return TelegramRasterImage.load(
            at: url,
            maxPixelSize: TelegramBubbleLayout.inlineCustomEmojiSide * 4
        )
    }

    private static func loadStill(at url: URL) -> NSImage? {
        TelegramRasterImage.load(at: url)
    }
}
