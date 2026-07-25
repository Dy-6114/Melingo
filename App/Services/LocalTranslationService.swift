import Foundation
import Translation
import SwiftUI
import AppKit

/// On-device Apple Translation. Never invents text — returns nil / throws when unavailable.
///
/// `TranslationSession.init(installedSource:target:)` only exists on macOS 26+. On macOS
/// 15–25 the only supported way to obtain a `TranslationSession` is SwiftUI's
/// `.translationTask` view modifier, so this service hosts a throwaway, invisible SwiftUI
/// view to acquire a real session and never fabricates translated text.
@MainActor
final class LocalTranslationService {
    enum ServiceError: Error, LocalizedError {
        case unavailable
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Language pack unavailable. Install it in System Settings → Language & Region."
            case .emptyInput:
                return "Nothing to translate."
            }
        }
    }

    func translate(
        _ text: String,
        from source: String,
        to target: String
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.emptyInput }
        let sourceCode = normalize(source)
        let targetCode = normalize(target)
        if sourceCode == targetCode { return trimmed }

        if #available(macOS 26.0, *) {
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            )
            do {
                let response = try await session.translate(trimmed)
                return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw ServiceError.unavailable
            }
        }

        do {
            let host = TranslationHostController()
            let box = try await host.awaitSession(
                source: Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            )
            let response = try await box.session.translate(trimmed)
            host.close()
            return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ServiceError.unavailable
        }
    }

    func translateBatch(
        _ texts: [String],
        from source: String,
        to target: String
    ) async throws -> [String] {
        let sourceCode = normalize(source)
        let targetCode = normalize(target)
        if sourceCode == targetCode { return texts }

        if #available(macOS 26.0, *) {
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            )
            var out: [String] = []
            out.reserveCapacity(texts.count)
            for text in texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { out.append(""); continue }
                do {
                    let response = try await session.translate(trimmed)
                    out.append(response.targetText.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    throw ServiceError.unavailable
                }
            }
            return out
        }

        do {
            let host = TranslationHostController()
            let box = try await host.awaitSession(
                source: Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            )
            var out: [String] = []
            out.reserveCapacity(texts.count)
            for text in texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { out.append(""); continue }
                let response = try await box.session.translate(trimmed)
                out.append(response.targetText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            host.close()
            return out
        } catch {
            throw ServiceError.unavailable
        }
    }

    private func normalize(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        switch base {
        case "jp": return "ja"
        case "cn", "zh-cn", "cmn": return "zh-Hans"
        case "tw", "zh-tw": return "zh-Hant"
        default: return base
        }
    }
}

/// `TranslationSession` isn't `Sendable`, but by construction exactly one task creates,
/// uses, and discards each session this service produces, so the data race Swift's
/// strict-concurrency checker guards against cannot actually occur here.
private final class SessionBox: @unchecked Sendable {
    let session: TranslationSession
    init(_ session: TranslationSession) { self.session = session }
}

/// Minimal off-screen window hosting `TranslationHostView` purely to obtain a real
/// `TranslationSession` via `.translationTask(source:target:action:)` (macOS 15+),
/// outside of a normally-displayed view hierarchy.
@MainActor
private final class TranslationHostController {
    private var window: NSWindow?

    func awaitSession(source: Locale.Language, target: Locale.Language) async throws -> SessionBox {
        try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else { return }
            let box = ContinuationBox(continuation: continuation)
            let hostingView = NSHostingView(
                rootView: TranslationHostView(source: source, target: target) { session in
                    box.resume(with: session)
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 2, height: 2),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.contentView = hostingView
            window.orderFrontRegardless()
            self.window = window
        }
    }

    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

/// Bridges a single-fire continuation resume so it can be called from a `nonisolated`
/// SwiftUI task closure without re-entering it more than once.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SessionBox, Error>?

    init(continuation: CheckedContinuation<SessionBox, Error>) {
        self.continuation = continuation
    }

    func resume(with session: TranslationSession) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: SessionBox(session))
    }
}

private struct TranslationHostView: View {
    let source: Locale.Language
    let target: Locale.Language
    let onSession: (TranslationSession) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(source: source, target: target) { session in
                onSession(session)
            }
    }
}
