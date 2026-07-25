import AppKit
import SwiftUI
import Domain

// MARK: - SwiftUI ↔ AppKit
//
// Troubleshooting (macOS + SwiftUI):
// - SwiftUI ScrollView eats taps on Text/Button/links (hover can still show).
// - NSTextField inside custom NSViews steals mouseDown even when not editable —
//   hitTest must return nil on labels so the row/word view receives events.
// - NSViewRepresentable needs an explicit size (GeometryReader); ambiguous height
//   yields a drawn view whose hit-testing region is empty/offset.

struct ReaderAppKitScroll: NSViewRepresentable {
    let segments: [TextSegment]
    let mode: ReaderViewMode
    let wordChipMode: Bool
    let fontSize: CGFloat
    let showReadingLine: Bool
    let languageHint: String?
    let selectedSegmentID: UUID?
    let selectedWordIDs: Set<String>
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    let onSelectSegment: (TextSegment) -> Void
    let onWordTap: (WordToken, TextSegment, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        scroll.scrollerInsets = .init()

        let document = ReaderDocumentView()
        document.wantsLayer = true
        scroll.documentView = document
        context.coordinator.document = document
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = context.coordinator.document ?? scroll.documentView as? ReaderDocumentView else { return }
        document.onSelectSegment = onSelectSegment
        document.onWordTap = onWordTap

        // Prefer measured SwiftUI size; fall back to scroll bounds.
        let width = max(canvasWidth > 1 ? canvasWidth - 56 : scroll.bounds.width - 56, 320)

        document.apply(
            segments: segments,
            mode: mode,
            wordChipMode: wordChipMode,
            fontSize: fontSize,
            showReadingLine: showReadingLine,
            languageHint: languageHint,
            selectedSegmentID: selectedSegmentID,
            selectedWordIDs: selectedWordIDs,
            width: width,
            horizontalPadding: 28,
            verticalPadding: 20
        )

        if let id = selectedSegmentID, let row = document.rowView(for: id) {
            DispatchQueue.main.async {
                row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -48))
            }
        }
    }

    final class Coordinator {
        var document: ReaderDocumentView?
    }
}

// MARK: - Pass-through label (must not steal clicks)

private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Document

final class ReaderDocumentView: NSView {
    var onSelectSegment: ((TextSegment) -> Void)?
    var onWordTap: ((WordToken, TextSegment, Bool) -> Void)?

    private var rows: [SegmentRowView] = []
    private var lastSignature = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rowView(for segmentID: UUID) -> SegmentRowView? {
        rows.first { $0.segment.id == segmentID }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Ensure we participate even when subviews return nil (pass-through labels).
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for sub in subviews.reversed() {
            let p = convert(point, to: sub.superview)
            if let hit = sub.hitTest(p) { return hit }
        }
        return self
    }

    func apply(
        segments: [TextSegment],
        mode: ReaderViewMode,
        wordChipMode: Bool,
        fontSize: CGFloat,
        showReadingLine: Bool,
        languageHint: String?,
        selectedSegmentID: UUID?,
        selectedWordIDs: Set<String>,
        width: CGFloat,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) {
        let usableWidth = max(width, 200)
        let signature = segments.map(\.id.uuidString).joined(separator: ",")
            + "|\(mode.rawValue)|\(wordChipMode)|\(Int(fontSize))|\(showReadingLine)"

        if signature != lastSignature || rows.count != segments.count {
            lastSignature = signature
            rows.forEach { $0.removeFromSuperview() }
            rows = segments.map { segment in
                let row = SegmentRowView(segment: segment)
                addSubview(row)
                return row
            }
        }

        var y = verticalPadding
        let spacing = fontSize * (wordChipMode ? 0.7 : 0.65)
        for row in rows {
            row.onSelectSegment = onSelectSegment
            row.onWordTap = onWordTap
            row.apply(
                mode: mode,
                wordChipMode: wordChipMode,
                fontSize: fontSize,
                showReadingLine: showReadingLine,
                languageHint: languageHint,
                isSelected: row.segment.id == selectedSegmentID,
                selectedWordIDs: selectedWordIDs,
                width: usableWidth
            )
            let height = row.fittingHeight(forWidth: usableWidth)
            row.frame = CGRect(x: horizontalPadding, y: y, width: usableWidth, height: height)
            y += height + spacing
        }

        let totalHeight = max(y - spacing + verticalPadding, verticalPadding * 2)
        let totalWidth = usableWidth + horizontalPadding * 2
        frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// MARK: - Row

final class SegmentRowView: NSView {
    let segment: TextSegment
    var onSelectSegment: ((TextSegment) -> Void)?
    var onWordTap: ((WordToken, TextSegment, Bool) -> Void)?

    private let readingLabel = PassThroughLabel(labelWithString: "")
    private let sentenceLabel = PassThroughLabel(labelWithString: "")
    private let translationLabel = PassThroughLabel(labelWithString: "")
    private let wordView = WordChipProseView()
    private var wordChipMode = true
    private var fontSize: CGFloat = 17
    private var showReading = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(segment: TextSegment) {
        self.segment = segment
        super.init(frame: .zero)
        wantsLayer = true

        for label in [readingLabel, sentenceLabel, translationLabel] {
            label.isSelectable = false
            label.isEditable = false
            label.isBezeled = false
            label.drawsBackground = false
            label.backgroundColor = .clear
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.cell?.wraps = true
            label.cell?.isScrollable = false
            label.refusesFirstResponder = true
            addSubview(label)
        }
        readingLabel.textColor = .secondaryLabelColor
        sentenceLabel.textColor = .labelColor
        translationLabel.textColor = .secondaryLabelColor

        addSubview(wordView)
        wordView.onTap = { [weak self] token, additive in
            guard let self else { return }
            self.onWordTap?(token, self.segment, additive)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }

        if wordChipMode, !wordView.isHidden {
            let inWord = convert(local, to: wordView)
            if wordView.bounds.contains(inWord) {
                return wordView
            }
        }
        return self
    }

    func apply(
        mode: ReaderViewMode,
        wordChipMode: Bool,
        fontSize: CGFloat,
        showReadingLine: Bool,
        languageHint: String?,
        isSelected: Bool,
        selectedWordIDs: Set<String>,
        width: CGFloat
    ) {
        self.wordChipMode = wordChipMode && mode != .translation
        self.fontSize = fontSize
        showReading = showReadingLine && mode != .translation

        let reading = segment.readingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        readingLabel.stringValue = (showReading && !reading.isEmpty) ? reading : ""
        readingLabel.font = .monospacedSystemFont(ofSize: fontSize * 0.55, weight: .regular)
        readingLabel.preferredMaxLayoutWidth = max(width - 12, 40)
        readingLabel.isHidden = readingLabel.stringValue.isEmpty

        if mode == .translation {
            let gloss = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sentenceLabel.stringValue = gloss.isEmpty ? "…" : gloss
            sentenceLabel.font = .systemFont(ofSize: fontSize)
            sentenceLabel.preferredMaxLayoutWidth = max(width - 12, 40)
            sentenceLabel.isHidden = false
            wordView.isHidden = true
            translationLabel.isHidden = true
        } else if self.wordChipMode {
            let tokens = WordTokenizer.tokens(
                in: segment.text,
                languageHint: languageHint,
                segmentID: segment.id
            )
            wordView.isHidden = false
            sentenceLabel.isHidden = true
            configureTranslationLabel(visible: mode == .bilingual, fontSize: fontSize, width: width)
            // Frame first, then apply — so layout uses the real width.
            let contentWidth = max(width - 12, 40)
            let wordHeight = wordView.height(forWidth: contentWidth)
            var y: CGFloat = 4
            if !readingLabel.isHidden {
                y += labelHeight(readingLabel, width: contentWidth) + 2
            }
            wordView.frame = CGRect(x: 6, y: y, width: contentWidth, height: wordHeight)
            wordView.apply(
                tokens: tokens,
                fontSize: fontSize,
                selectedIDs: selectedWordIDs,
                textColor: .labelColor,
                mutedColor: .secondaryLabelColor,
                selectionFill: .quaternaryLabelColor
            )
        } else {
            sentenceLabel.stringValue = segment.text
            sentenceLabel.font = .systemFont(ofSize: fontSize)
            sentenceLabel.preferredMaxLayoutWidth = max(width - 12, 40)
            sentenceLabel.isHidden = false
            wordView.isHidden = true
            configureTranslationLabel(visible: mode == .bilingual, fontSize: fontSize, width: width)
        }

        layer?.cornerRadius = 6
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor

        let height = fittingHeight(forWidth: width)
        frame.size = NSSize(width: width, height: height)
        layoutChildren(width: width)
    }

    private func configureTranslationLabel(visible: Bool, fontSize: CGFloat, width: CGFloat) {
        let gloss = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard visible, !gloss.isEmpty else {
            translationLabel.isHidden = true
            translationLabel.stringValue = ""
            return
        }
        translationLabel.stringValue = gloss
        translationLabel.font = .systemFont(ofSize: fontSize * 0.88)
        translationLabel.preferredMaxLayoutWidth = max(width - 18, 40)
        translationLabel.isHidden = false
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        var y: CGFloat = 4
        let contentWidth = max(width - 12, 40)
        if !readingLabel.isHidden {
            y += labelHeight(readingLabel, width: contentWidth) + 2
        }
        if !wordView.isHidden {
            y += wordView.height(forWidth: contentWidth)
        } else if !sentenceLabel.isHidden {
            y += labelHeight(sentenceLabel, width: contentWidth)
        }
        if !translationLabel.isHidden {
            y += 6 + labelHeight(translationLabel, width: contentWidth)
        }
        return max(y + 4, fontSize * 1.4)
    }

    private func layoutChildren(width: CGFloat) {
        var y: CGFloat = 4
        let x: CGFloat = 6
        let contentWidth = max(width - 12, 40)

        if !readingLabel.isHidden {
            let h = labelHeight(readingLabel, width: contentWidth)
            readingLabel.frame = CGRect(x: x, y: y, width: contentWidth, height: h)
            y += h + 2
        } else {
            readingLabel.frame = .zero
        }

        if !wordView.isHidden {
            let h = wordView.height(forWidth: contentWidth)
            wordView.frame = CGRect(x: x, y: y, width: contentWidth, height: h)
            wordView.refreshFrames()
            y += h
        } else if !sentenceLabel.isHidden {
            let h = labelHeight(sentenceLabel, width: contentWidth)
            sentenceLabel.frame = CGRect(x: x, y: y, width: contentWidth, height: h)
            y += h
        }

        if !translationLabel.isHidden {
            y += 6
            let h = labelHeight(translationLabel, width: contentWidth)
            translationLabel.frame = CGRect(x: x + 6, y: y, width: contentWidth - 6, height: h)
        } else {
            translationLabel.frame = .zero
        }
    }

    private func labelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        let size = label.sizeThatFits(NSSize(width: width, height: 10_000))
        return ceil(max(size.height, fontSize * 0.8))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if wordChipMode, !wordView.isHidden {
            wordView.mouseDown(with: event)
            if wordView.didHandleLastMouseDown { return }
        }
        onSelectSegment?(segment)
    }
}

// MARK: - Words

final class WordChipProseView: NSView {
    var onTap: ((_ token: WordToken, _ additive: Bool) -> Void)?
    private(set) var didHandleLastMouseDown = false

    private var tokens: [WordToken] = []
    private var selectedIDs: Set<String> = []
    private var fontSize: CGFloat = 17
    private var textColor: NSColor = .labelColor
    private var mutedColor: NSColor = .secondaryLabelColor
    private var selectionFill: NSColor = .quaternaryLabelColor
    private var frames: [CGRect] = []
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    func apply(
        tokens: [WordToken],
        fontSize: CGFloat,
        selectedIDs: Set<String>,
        textColor: NSColor,
        mutedColor: NSColor,
        selectionFill: NSColor
    ) {
        self.tokens = tokens
        self.fontSize = fontSize
        self.selectedIDs = selectedIDs
        self.textColor = textColor
        self.mutedColor = mutedColor
        self.selectionFill = selectionFill
        refreshFrames()
        needsDisplay = true
        updateTracking()
    }

    func refreshFrames() {
        let w = bounds.width > 1 ? bounds.width : 320
        frames = layoutFrames(width: w)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let laid = layoutFrames(width: width)
        guard let last = laid.last else { return fontSize * 1.25 }
        return ceil(last.maxY)
    }

    override func layout() {
        super.layout()
        refreshFrames()
        updateTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard frames.count == tokens.count else { return }
        let font = NSFont.systemFont(ofSize: fontSize)

        for index in tokens.indices {
            let token = tokens[index]
            let frame = frames[index]
            guard frame.intersects(dirtyRect) else { continue }

            let selected = token.isWord && selectedIDs.contains(token.id)
            let hovered = token.isWord && hoveredIndex == index

            if selected {
                let bg = NSBezierPath(
                    roundedRect: frame.insetBy(dx: -1, dy: -1),
                    xRadius: 2,
                    yRadius: 2
                )
                selectionFill.withAlphaComponent(0.55).setFill()
                bg.fill()
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            if selected || hovered {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = mutedColor.withAlphaComponent(selected ? 0.9 : 0.45)
            }
            (token.text as NSString).draw(at: frame.origin, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        didHandleLastMouseDown = false
        let point = convert(event.locationInWindow, from: nil)
        guard let token = token(at: point), token.isWord else { return }
        didHandleLastMouseDown = true
        let additive = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        onTap?(token, additive)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tokenIndex(at: point)
        if index != hoveredIndex {
            hoveredIndex = index
            if index != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil {
            hoveredIndex = nil
            NSCursor.arrow.set()
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func token(at point: CGPoint) -> WordToken? {
        guard let index = tokenIndex(at: point) else { return nil }
        return tokens[index]
    }

    private func tokenIndex(at point: CGPoint) -> Int? {
        guard frames.count == tokens.count else { return nil }
        var best: (Int, CGFloat)?
        for index in tokens.indices where tokens[index].isWord {
            let hit = frames[index].insetBy(dx: -2, dy: -3)
            guard hit.contains(point) else { continue }
            let area = hit.width * hit.height
            if best == nil || area < best!.1 {
                best = (index, area)
            }
        }
        return best?.0
    }

    private func layoutFrames(width: CGFloat) -> [CGRect] {
        let maxWidth = max(width, 1)
        let font = NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lineSpacing = max(6, fontSize * 0.35)

        var result: [CGRect] = []
        result.reserveCapacity(tokens.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for token in tokens {
            let size = (token.text as NSString).size(withAttributes: attrs)
            let w = ceil(size.width)
            let h = ceil(max(size.height, fontSize * 1.2))
            if x > 0, x + w > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            result.append(CGRect(x: x, y: y, width: w, height: h))
            rowHeight = max(rowHeight, h)
            x += w
        }
        return result
    }
}
