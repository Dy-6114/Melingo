import AppKit
import SwiftUI

/// Borderless panel: compact bar under the menu bar + translation capsule.
@MainActor
final class ReadingModeHUDWindow {
    private var panel: NSPanel?
    private let model = ReadingModeHUDModel()

    var hudModel: ReadingModeHUDModel { model }

    private var savedResetWork: DispatchWorkItem?

    func show(onClose: @escaping () -> Void) {
        if panel == nil {
            installPanel(onClose: onClose)
        }
        model.isVisible = true
        model.isActive = true
        model.phase = .listening
        reposition(animated: false)
        panel?.orderFrontRegardless()
    }

    func hide(animated: Bool = true) {
        model.isVisible = false
        model.isActive = false
        model.phase = .idle
        let panel = self.panel
        let delay = animated ? 0.32 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.model.isVisible == false else { return }
            panel?.orderOut(nil)
        }
    }

    func updateContent(source: String, translation: String, translating: Bool) {
        model.sourceText = source
        model.translation = translation
        model.isTranslating = translating
        if model.phase != .saved {
            model.phase = translating ? .processing : .listening
        }
        let width = preferredWidth(for: source, translation: translation, translating: translating)
        reposition(width: width, animated: true)
    }

    func setElapsed(_ seconds: Int) {
        model.elapsedSeconds = seconds
    }

    /// Briefly flashes a "Added" success state, then returns to listening.
    func markSaved() {
        savedResetWork?.cancel()
        model.phase = .saved
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.isVisible else { return }
            self.model.phase = self.model.isTranslating ? .processing : .listening
        }
        savedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    func reposition(width: CGFloat? = nil, animated: Bool = false) {
        guard let panel else { return }
        let w = width ?? panel.frame.width
        let frame = NotchGeometry.hudFrame(preferredWidth: max(w, NotchGeometry.minWidth))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Private

    private func installPanel(onClose: @escaping () -> Void) {
        let panel = NSPanel(
            contentRect: NotchGeometry.hudFrame(preferredWidth: NotchGeometry.minWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        let root = ReadingModeHUDView(model: model, onClose: onClose)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition(animated: false)
            }
        }
    }

    private func preferredWidth(for source: String, translation: String, translating: Bool) -> CGFloat {
        // Left zone: 24pt icon + 12pt gap + word (18pt semibold ≈ 10.5pt/char).
        let wordChars = source.isEmpty ? 16 : source.count
        let wordWidth = CGFloat(max(wordChars, 10)) * 10.5 + 24 + 12
        // Translation sits under the word (13pt medium ≈ 7.5pt/char).
        let glossChars = translating ? 4 : translation.count
        let glossWidth = glossChars > 0 ? CGFloat(glossChars) * 7.5 + 36 : 0
        let leftZone = max(wordWidth, glossWidth)
        // Right zone: waveform + timer + close + inter-item spacing.
        let rightZone: CGFloat = 130
        // Leading/trailing padding (20 + 16) + center gap reserved for the notch.
        let capsule = leftZone + rightZone + 20 + 16 + NotchGeometry.centerGap()
        let clamped = min(NotchGeometry.maxWidth, max(NotchGeometry.minWidth, capsule))
        // Panel is wider than the capsule by the horizontal inset on each side.
        return clamped + NotchGeometry.horizontalInset * 2
    }
}
