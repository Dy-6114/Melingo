import Foundation
import Domain

/// In-memory Quick Find index over packs + vocabulary (Revu SearchService, slim).
@MainActor
@Observable
final class QuickCommandController {
    var query: String = "" {
        didSet { rebuild() }
    }
    private(set) var results: [QuickCommandResult] = []

    private weak var store: AppLibraryStore?

    func attach(store: AppLibraryStore) {
        self.store = store
        rebuild()
    }

    func prepare() {
        query = ""
        rebuild()
    }

    private func rebuild() {
        guard let store else {
            results = []
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items: [QuickCommandResult] = []

        // Actions always first when query empty or matches.
        let actions: [(String, String, String, QuickCommandAction, String?)] = [
            ("action.study", AppL10n.t("sidebar.study"), "graduationcap", .go(.study), store.dueCount > 0 ? "\(store.dueCount)" : nil),
            ("action.review", AppL10n.t("quick.action.review"), "rectangle.stack", .startReview, store.dueCount > 0 ? "\(store.dueCount)" : nil),
            ("action.newCard", AppL10n.t("sidebar.newCard"), "plus.rectangle.on.folder", .go(.newCard), nil),
            ("action.vocabulary", AppL10n.t("sidebar.vocabulary"), "character.book.closed", .go(.vocabulary), nil),
            ("action.library", AppL10n.t("sidebar.articles"), "books.vertical", .go(.library), nil),
            ("action.packs", AppL10n.t("sidebar.myPacks"), "square.stack.3d.up", .go(.myPacks), nil),
            ("action.stats", AppL10n.t("sidebar.stats"), "chart.bar.fill", .go(.stats), nil),
            ("action.history", AppL10n.t("sidebar.history"), "clock.arrow.circlepath", .go(.history), nil),
            ("action.settings", AppL10n.t("sidebar.settings"), "gearshape", .openSettings, nil),
            ("action.smart.due", AppL10n.t("smart.due"), "clock.badge.exclamationmark", .go(.smart(.due)), store.dueCount > 0 ? "\(store.dueCount)" : nil),
            ("action.smart.new", AppL10n.t("smart.new"), "sparkles", .go(.smart(.new)), nil),
            ("action.smart.weak", AppL10n.t("smart.weak"), "brain.head.profile", .go(.smart(.weak)), nil),
            ("action.smart.suspended", AppL10n.t("smart.suspended"), "pause.circle", .go(.smart(.suspended)), nil),
        ]

        for (id, title, icon, action, badge) in actions {
            if q.isEmpty || title.lowercased().contains(q) || id.contains(q) {
                items.append(QuickCommandResult(
                    id: id,
                    title: title,
                    subtitle: AppL10n.t("quick.subtitle.action"),
                    icon: icon,
                    badge: badge,
                    action: action
                ))
            }
        }

        for pack in store.packs.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let matches = q.isEmpty
                ? (pack.isPinned || pack.kind == .tag)
                : pack.name.lowercased().contains(q)
            guard matches else { continue }
            if q.isEmpty, items.filter({ $0.id.hasPrefix("pack.") }).count >= 8 { break }
            let dest: QuickCommandAction = pack.isPinned
                ? .go(.pinnedPack(pack.id))
                : (pack.kind == .tag ? .go(.tag(pack.id)) : .openPack(pack.id))
            items.append(QuickCommandResult(
                id: "pack.\(pack.id.uuidString)",
                title: pack.name,
                subtitle: pack.kind == .tag ? AppL10n.t("quick.subtitle.tag") : AppL10n.t("quick.subtitle.pack"),
                icon: pack.isPinned ? "pin.fill" : (pack.kind == .tag ? "tag" : "square.stack.3d.up"),
                badge: nil,
                action: dest
            ))
        }

        let vocabLimit = q.isEmpty ? 0 : 40
        var vocabHits = 0
        for entry in store.vocabulary {
            if vocabHits >= vocabLimit { break }
            let hay = [entry.word, entry.meaning, entry.reading ?? ""]
                .joined(separator: " ")
                .lowercased()
            if hay.contains(q) {
                items.append(QuickCommandResult(
                    id: "vocab.\(entry.id.uuidString)",
                    title: entry.word,
                    subtitle: entry.meaning,
                    icon: "character.book.closed",
                    badge: entry.srsState == .new ? AppL10n.t("quick.badge.new") : nil,
                    action: .openVocabulary(entry.id)
                ))
                vocabHits += 1
            }
        }

        results = items
    }
}
