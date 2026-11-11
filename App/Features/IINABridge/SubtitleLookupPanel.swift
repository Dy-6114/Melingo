import AppKit
import Domain
import SwiftUI

/// Floating lookup panel for selections made in IINA.
///
/// It never activates Melingo: activating would pull the user out of IINA's
/// full-screen Space. The panel joins every Space (including full-screen ones)
/// and takes clicks without becoming the key window, so IINA keeps its shortcuts.
@MainActor
final class SubtitleLookupPanel {
    private static let size = NSSize(width: 380, height: 330)
    /// Gap between the pointer and the panel so the subtitle line stays readable.
    private static let pointerGap: CGFloat = 40

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var outsideClickMonitor: Any?
    private var onClose: (() -> Void)?
    private var presentedAt = Date.distantPast

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(_ lookup: SubtitleLookup, store: AppLibraryStore, onClose: @escaping () -> Void) {
        let panel = self.panel ?? makePanel()
        self.onClose = onClose
        presentedAt = Date()

        let root = SubtitleLookupView(lookup: lookup, onClose: { [weak self] in self?.close() })
            .environment(store)
            .environment(\.theme, ThemeTokens.system)
            .tint(ThemeTokens.system.primary)
        hosting?.rootView = AnyView(root)

        panel.setFrame(Self.frame(near: NSEvent.mouseLocation), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        installOutsideClickMonitor()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        removeOutsideClickMonitor()
        // Drop the SwiftUI tree so speech and in-flight lookups stop.
        hosting?.rootView = AnyView(EmptyView())
        let callback = onClose
        onClose = nil
        callback?()
    }

    // MARK: - Private

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        let hosting = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.hosting = hosting
        self.panel = panel
        return panel
    }

    /// Above the pointer when there is room, otherwise below; always fully on the
    /// pointer's screen. Uses the full screen frame because IINA may be full screen.
    private static func frame(near point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        let bounds = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 12

        var x = point.x - size.width / 2
        var y = point.y + pointerGap
        if y + size.height > bounds.maxY - margin {
            y = point.y - pointerGap - size.height
        }
        x = min(max(x, bounds.minX + margin), bounds.maxX - size.width - margin)
        y = min(max(y, bounds.minY + margin), bounds.maxY - size.height - margin)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // Global monitors only see clicks delivered to other apps, i.e. outside the panel.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleOutsideClick()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func handleOutsideClick() {
        // The mouse-down that started the current selection can be delivered just
        // after the panel appears; it must not close the panel it opened.
        guard Date().timeIntervalSince(presentedAt) > 0.3 else { return }
        close()
    }
}

/// The panel is never the key window and Melingo is usually not the active app,
/// so buttons must react to the first click instead of swallowing it.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Header + the standard word lookup (translation, IPA, definition, add card).
struct SubtitleLookupView: View {
    @Environment(\.theme) private var theme

    let lookup: SubtitleLookup
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                WordLookupPopover(
                    word: lookup.text,
                    segment: TextSegment(documentID: UUID(), order: 0, text: lookup.context),
                    documentTitle: lookup.title,
                    canSpeak: true,
                    languagePairOverride: lookup.languagePair
                )
            }
        }
        // A fresh identity per selection resets the popover's loading state.
        .id(lookup.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.card, style: .continuous)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.rectangle.fill")
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
            Text(lookup.title ?? "IINA")
                .font(.caption)
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(theme.mutedForeground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}
