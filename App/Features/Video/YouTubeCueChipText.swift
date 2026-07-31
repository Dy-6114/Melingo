import AppKit
import SwiftUI
import Domain

/// Word chips for a subtitle cue — same hit-testing as Melingo Reader.
struct YouTubeCueChipText: NSViewRepresentable {
    let text: String
    let languageHint: String?
    let selectedIDs: Set<String>
    let isActiveCue: Bool
    let segmentID: UUID
    let onWordTap: (WordToken, Bool) -> Void

    func makeNSView(context: Context) -> YouTubeCueChipHost {
        let host = YouTubeCueChipHost()
        host.onWordTap = onWordTap
        return host
    }

    func updateNSView(_ host: YouTubeCueChipHost, context: Context) {
        host.onWordTap = onWordTap
        host.apply(
            text: text,
            languageHint: languageHint,
            selectedIDs: selectedIDs,
            isActiveCue: isActiveCue,
            segmentID: segmentID
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: YouTubeCueChipHost, context: Context) -> CGSize? {
        let width = proposal.width ?? 360
        let height = nsView.height(forWidth: max(width, 120))
        return CGSize(width: width, height: max(height, 20))
    }
}

final class YouTubeCueChipHost: NSView {
    var onWordTap: ((WordToken, Bool) -> Void)?

    private let chipView = WordChipProseView()

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
        isActiveCue: Bool,
        segmentID: UUID
    ) {
        let tokens = WordTokenizer.tokens(in: text, languageHint: languageHint, segmentID: segmentID)
        let textColor = NSColor.labelColor
        let muted = NSColor.secondaryLabelColor
        let selection = isActiveCue
            ? NSColor.controlAccentColor.withAlphaComponent(0.35)
            : NSColor.quaternaryLabelColor
        chipView.apply(
            tokens: tokens,
            fontSize: isActiveCue ? 16 : 14,
            selectedIDs: selectedIDs,
            textColor: textColor,
            mutedColor: muted,
            selectionFill: selection
        )
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        chipView.height(forWidth: width)
    }

    override var intrinsicContentSize: NSSize {
        let w = bounds.width > 1 ? bounds.width : 360
        return NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: w))
    }

    override func layout() {
        super.layout()
        chipView.refreshFrames()
        invalidateIntrinsicContentSize()
    }
}
