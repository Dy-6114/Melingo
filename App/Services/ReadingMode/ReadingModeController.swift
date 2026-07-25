import AppKit
import Domain
import Foundation

/// Owns reading-mode session lifecycle: hotkey, HUD, selection → translation, timer.
@MainActor
final class ReadingModeController {
    static let shared = ReadingModeController()

    private let hotKey = GlobalHotKey()
    private let hud = ReadingModeHUDWindow()
    private let poller = SelectionPoller()
    private let translator = TranslationService()

    private var isActive = false
    private var sessionStartedAt: Date?
    private var tickTimer: Timer?
    private var translateTask: Task<Void, Never>?
    private var lastSource = ""

    /// Injected after store boots — returns learning → native pair.
    var languagePairProvider: (() -> LanguagePair)?

    private init() {}

    func bootstrap() {
        hotKey.registerCommandShiftR { [weak self] in
            self?.toggle()
        }
    }

    var isReadingModeActive: Bool { isActive }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        sessionStartedAt = Date()
        lastSource = ""
        hud.setElapsed(0)

        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.requestIfNeeded()
            hud.updateContent(
                source: AppL10n.t("readingMode.needAccessibility"),
                translation: "",
                translating: false
            )
        } else {
            hud.updateContent(source: AppL10n.t("readingMode.hint"), translation: "", translating: false)
        }
        hud.show { [weak self] in
            self?.stop()
        }

        poller.onSelection = { [weak self] text in
            self?.handleSelection(text)
        }
        poller.start()

        tickTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        NotificationCenter.default.post(name: .readingModeDidChange, object: nil, userInfo: ["active": true])
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        poller.stop()
        translateTask?.cancel()
        translateTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
        sessionStartedAt = nil
        hud.hide(animated: true)
        NotificationCenter.default.post(name: .readingModeDidChange, object: nil, userInfo: ["active": false])
    }

    // MARK: - Private

    private func updateElapsed() {
        guard let start = sessionStartedAt else { return }
        hud.setElapsed(Int(Date().timeIntervalSince(start)))
    }

    private func handleSelection(_ text: String) {
        let normalized = Self.normalizeSelection(text)
        guard !normalized.isEmpty, normalized != lastSource else { return }
        lastSource = normalized
        hud.updateContent(source: normalized, translation: "", translating: true)

        translateTask?.cancel()
        translateTask = Task { [weak self] in
            guard let self else { return }
            let pair = languagePairProvider?() ?? LanguagePair(source: "en", target: "ru")
            do {
                let gloss = try await translator.translate(
                    normalized,
                    from: pair.source,
                    to: pair.target
                )
                guard !Task.isCancelled, self.lastSource == normalized else { return }
                self.hud.updateContent(source: normalized, translation: gloss, translating: false)
            } catch {
                guard !Task.isCancelled, self.lastSource == normalized else { return }
                self.hud.updateContent(
                    source: normalized,
                    translation: AppL10n.t("readingMode.translateFailed"),
                    translating: false
                )
            }
        }
    }

    private static func normalizeSelection(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse internal whitespace for single-line HUD.
        let parts = trimmed.split { $0.isWhitespace || $0.isNewline }
        return parts.joined(separator: " ")
    }
}

extension Notification.Name {
    static let readingModeDidChange = Notification.Name("melingo.readingModeDidChange")
}
