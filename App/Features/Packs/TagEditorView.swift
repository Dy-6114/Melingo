import SwiftUI
import Domain

/// Persisted look for tags (icon + color) without a SwiftData migration.
@MainActor
enum TagStyleStore {
    private static let key = "tags.style.v1"

    struct Style: Codable, Equatable, Sendable {
        var symbolName: String
        var colorHex: String

        static let defaults: Style = .init(symbolName: "tag.fill", colorHex: "#FF2D55")
    }

    static func style(for packID: UUID) -> Style {
        all()[packID.uuidString] ?? .defaults
    }

    static func setStyle(_ style: Style, for packID: UUID) {
        var map = all()
        map[packID.uuidString] = style
        persist(map)
    }

    static func remove(packID: UUID) {
        var map = all()
        map.removeValue(forKey: packID.uuidString)
        persist(map)
    }

    private static func all() -> [String: Style] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Style].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persist(_ map: [String: Style]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 45, 85)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// Dedicated CRUD UI for tag packs: name, SF Symbol, color, delete.
struct TagEditorView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var editing: WordPack?
    @State private var editName = ""
    @State private var editSymbol = "tag.fill"
    @State private var editColor = "#FF2D55"
    @State private var confirmDelete: WordPack?

    private static let symbolChoices = [
        "tag.fill", "book.fill", "bubble.left.fill", "briefcase.fill",
        "headphones", "flame.fill", "star.fill", "heart.fill",
        "flag.fill", "bookmark.fill", "graduationcap.fill", "globe",
    ]

    private static let colorChoices = [
        "#FF2D55", "#FF9500", "#FFCC00", "#34C759",
        "#5AC8FA", "#007AFF", "#5856D6", "#AF52DE",
        "#8E8E93", "#A2845E",
    ]

    private var tags: [WordPack] {
        store.packs.filter { $0.kind == .tag }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField(AppL10n.t("tags.new"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await create() } }
                    Button {
                        Task { await create() }
                    } label: {
                        Label(AppL10n.t("tags.new"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)

                if tags.isEmpty {
                    ContentUnavailableView(
                        AppL10n.t("tags.empty"),
                        systemImage: "tag",
                        description: Text(AppL10n.t("tags.new"))
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(tags) { tag in
                            let style = TagStyleStore.style(for: tag.id)
                            HStack(spacing: 12) {
                                Image(systemName: style.symbolName)
                                    .foregroundStyle(Color(hex: style.colorHex))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tag.name)
                                        .font(.body.weight(.medium))
                                    Text(String(format: AppL10n.t("tags.cards"), store.cardCount(for: tag)))
                                        .font(.caption)
                                        .foregroundStyle(theme.mutedForeground)
                                }
                                Spacer()
                                if tag.isSystem {
                                    Text("System")
                                        .font(.caption2)
                                        .foregroundStyle(theme.mutedForeground)
                                }
                                Button {
                                    beginEdit(tag)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help(AppL10n.t("tags.rename"))
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button(AppL10n.t("tags.rename")) { beginEdit(tag) }
                                Button(AppL10n.t("tags.delete"), role: .destructive) {
                                    confirmDelete = tag
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle(AppL10n.t("tags.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppL10n.t("common.done")) { dismiss() }
                }
            }
            .sheet(item: $editing) { tag in
                tagEditSheet(tag)
            }
            .confirmationDialog(
                "Delete tag “\(confirmDelete?.name ?? "")”?",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(AppL10n.t("tags.delete"), role: .destructive) {
                    guard let tag = confirmDelete else { return }
                    Task {
                        await store.deleteTag(tag.id)
                        TagStyleStore.remove(packID: tag.id)
                        confirmDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("Cards keep their other tags. This only removes the tag itself.")
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private func beginEdit(_ tag: WordPack) {
        let style = TagStyleStore.style(for: tag.id)
        editName = tag.name
        editSymbol = style.symbolName
        editColor = style.colorHex
        editing = tag
    }

    @ViewBuilder
    private func tagEditSheet(_ tag: WordPack) -> some View {
        NavigationStack {
            Form {
                TextField(AppL10n.t("tags.rename"), text: $editName)
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(Self.symbolChoices, id: \.self) { symbol in
                            Button {
                                editSymbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(editSymbol == symbol
                                                  ? Color(hex: editColor).opacity(0.2)
                                                  : Color.clear)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                editSymbol == symbol ? Color(hex: editColor) : Color.secondary.opacity(0.2),
                                                lineWidth: editSymbol == symbol ? 2 : 1
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                        ForEach(Self.colorChoices, id: \.self) { hex in
                            Button {
                                editColor = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if editColor == hex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tag.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveEdit(tag) }
                    }
                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 420, height: 460)
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if await store.createTag(name: name) {
            if let created = store.packs.first(where: { $0.kind == .tag && $0.name == name }) {
                TagStyleStore.setStyle(.defaults, for: created.id)
            }
            newName = ""
        }
    }

    private func saveEdit(_ tag: WordPack) async {
        _ = await store.renameTag(tag.id, name: editName)
        TagStyleStore.setStyle(
            .init(symbolName: editSymbol, colorHex: editColor),
            for: tag.id
        )
        editing = nil
    }
}
