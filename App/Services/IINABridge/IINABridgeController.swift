import AppKit
import Domain
import Foundation
import NaturalLanguage

/// One selection sent by the IINA plugin.
struct SubtitleLookup: Identifiable, Equatable, Sendable {
    let id: String
    /// The word or phrase the learner selected.
    let text: String
    /// The full subtitle line — becomes the card's example sentence.
    let context: String
    let title: String?
    /// Detected content language → the learner's explanation language.
    let languagePair: LanguagePair
}

/// Receives selections from the IINA plugin (`IINAPlugin/melingo-subtitles.iinaplugin`)
/// over a loopback HTTP bridge and shows the lookup panel.
///
/// Protocol (all GET, header `X-Melingo-Bridge` required):
///   /ping                     → { ok, app, ready }
///   /lookup?text&context&title&position&trackLang → { id, source, target }
///   /status?id                → { state: "open" | "closed" }   (plugin resumes on "closed")
///   /dismiss?id               → { ok }
@MainActor
final class IINABridgeController {
    static let shared = IINABridgeController()

    /// Must match `BRIDGE` in the plugin's `main.js`.
    static let port: UInt16 = 51_730

    /// Injected after the library store boots.
    weak var store: AppLibraryStore?

    private var server: LoopbackHTTPServer?
    private let panel = SubtitleLookupPanel()
    private var activeLookupID: String?

    private init() {}

    func bootstrap() {
        guard server == nil else { return }
        let server = LoopbackHTTPServer(port: Self.port) { request in
            await IINABridgeController.shared.handle(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Melingo IINA bridge failed to start: %@", String(describing: error))
        }
    }

    // MARK: - Requests

    func handle(_ request: BridgeHTTPRequest) -> BridgeHTTPResponse {
        // Web pages cannot attach custom headers to cross-site requests without a
        // CORS preflight (which this server never answers), so this keeps browsers out.
        guard request.headers["x-melingo-bridge"] != nil else {
            return .json(["error": "forbidden"], status: 403)
        }

        switch request.path {
        case "/ping":
            return .json(["ok": true, "app": "Melingo", "ready": readyStore != nil])

        case "/lookup":
            return lookup(request.parameters)

        case "/status":
            let id = request.parameters["id"] ?? ""
            let isOpen = !id.isEmpty && id == activeLookupID && panel.isVisible
            return .json(["state": isOpen ? "open" : "closed"])

        case "/dismiss":
            let id = request.parameters["id"] ?? ""
            if id.isEmpty || id == activeLookupID {
                panel.close()
            }
            return .json(["ok": true])

        default:
            return .json(["error": "not-found"], status: 404)
        }
    }

    private var readyStore: AppLibraryStore? {
        guard let store, store.profile.hasCompletedOnboarding else { return nil }
        return store
    }

    private func lookup(_ parameters: [String: String]) -> BridgeHTTPResponse {
        guard let store = readyStore else {
            return .json(["error": "not-ready"], status: 503)
        }
        let text = Self.collapse(parameters["text"] ?? "")
        guard !text.isEmpty, text.count <= 400 else {
            return .json(["error": "bad-text"], status: 400)
        }
        let line = Self.collapse(parameters["context"] ?? "")
        let context = line.isEmpty ? text : line
        let title = Self.collapse(parameters["title"] ?? "")

        let profilePair = store.profile.preferredLanguagePair
        let source = Self.detectSourceLanguage(
            line: context,
            trackLanguage: parameters["trackLang"],
            fallback: profilePair.source
        )
        let lookupID = UUID().uuidString
        let selection = SubtitleLookup(
            id: lookupID,
            text: text,
            context: context,
            title: title.isEmpty ? nil : title,
            languagePair: LanguagePair(source: source, target: profilePair.target)
        )

        activeLookupID = lookupID
        panel.present(selection, store: store) { [weak self] in
            guard let self, self.activeLookupID == lookupID else { return }
            self.activeLookupID = nil
        }
        return .json(["id": lookupID, "source": source, "target": profilePair.target])
    }

    // MARK: - Source language

    /// Videos are not always in the profile's content language, so decide per line:
    /// a confident guess from the subtitle text first, then the subtitle track's
    /// language tag, then the "Content language" from Settings.
    static func detectSourceLanguage(line: String, trackLanguage: String?, fallback: String) -> String {
        if line.count >= 6 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(line)
            if let best = recognizer.languageHypotheses(withMaximum: 1).first,
               best.value >= 0.85,
               best.key != .undetermined {
                return baseCode(best.key.rawValue)
            }
        }
        if let trackLanguage, let code = languageCode(fromTrackTag: trackLanguage) {
            return code
        }
        return fallback
    }

    /// "zh-Hans" → "zh", "en-US" → "en" (matches the codes used in Settings).
    private static func baseCode(_ code: String) -> String {
        let lowered = code.lowercased()
        return lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lowered
    }

    /// mpv reports track languages as ISO 639-1 ("en") or 639-2 ("eng", "chi", "ger").
    private static func languageCode(fromTrackTag tag: String) -> String? {
        let head = baseCode(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        if head.count == 2 { return head }
        return threeLetterCodes[head]
    }

    private static let threeLetterCodes: [String: String] = [
        "eng": "en", "jpn": "ja", "chi": "zh", "zho": "zh", "cmn": "zh", "yue": "zh",
        "kor": "ko", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
        "ita": "it", "por": "pt", "rus": "ru", "vie": "vi", "tha": "th", "ara": "ar",
        "hin": "hi", "dut": "nl", "nld": "nl", "swe": "sv", "nor": "no", "nob": "nb",
        "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr", "ukr": "uk", "ces": "cs",
        "cze": "cs", "ell": "el", "gre": "el", "heb": "he", "hun": "hu", "ind": "id",
        "may": "ms", "msa": "ms", "ron": "ro", "rum": "ro", "cat": "ca", "bul": "bg",
        "hrv": "hr", "srp": "sr", "slk": "sk", "slo": "sk", "fas": "fa", "per": "fa",
    ]

    private static func collapse(_ raw: String) -> String {
        raw.split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
    }
}
