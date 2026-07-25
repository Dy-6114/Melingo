import Foundation
import Domain
import Observation

/// Simple persisted pack order for DnD (avoids SwiftData schema bump in Lab).
@MainActor
@Observable
final class PackOrderStore {
    static let shared = PackOrderStore()

    /// Bumped after every reorder so views refresh.
    private(set) var revision: Int = 0

    private let key = "melingo.lab.packSortOrder"

    func ordered(_ packs: [WordPack]) -> [WordPack] {
        _ = revision
        let order = load()
        guard !order.isEmpty else {
            return packs.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        var rank: [UUID: Int] = [:]
        for (i, id) in order.enumerated() { rank[id] = i }
        return packs.sorted { a, b in
            let ra = rank[a.id] ?? Int.max
            let rb = rank[b.id] ?? Int.max
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Reorder within a visible subset without dropping other pack IDs.
    func move(packs: [WordPack], from source: IndexSet, to destination: Int) {
        let subset = ordered(packs).map(\.id)
        guard !subset.isEmpty else { return }
        var subsetOrder = subset
        subsetOrder.move(fromOffsets: source, toOffset: destination)

        let subsetSet = Set(subset)
        var full = load()
        if full.isEmpty {
            full = subsetOrder
        } else {
            let insertAt = full.firstIndex(where: { subsetSet.contains($0) }) ?? full.count
            full.removeAll { subsetSet.contains($0) }
            full.insert(contentsOf: subsetOrder, at: min(insertAt, full.count))
        }
        // Keep any packs not in this subset that weren't in storage yet.
        save(full)
        revision &+= 1
    }

    func reconcile(with packs: [WordPack]) {
        let existing = Set(packs.map(\.id))
        var ids = load().filter { existing.contains($0) }
        let missing = packs.map(\.id).filter { !ids.contains($0) }
        ids.append(contentsOf: missing)
        save(ids)
        revision &+= 1
    }

    private func load() -> [UUID] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return raw.compactMap(UUID.init(uuidString:))
    }

    private func save(_ ids: [UUID]) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }
}
