import SwiftUI
import Domain

/// Generates a candidate pack from a topic via the active language model, previews the
/// cards, then either creates a brand-new pack or appends into an existing one.
struct GeneratePackSheet: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var preselectedPackID: WordPack.ID?

    @State private var topic = ""
    @State private var targetPackID: WordPack.ID?
    @State private var isDone = false

    private var existingPacks: [WordPack] {
        store.packs.filter { $0.kind == .learningPack && $0.id != WordPack.systemUngroupedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppL10n.t("pack.gen.title"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.foreground)

            TextField(AppL10n.t("pack.gen.topicPlaceholder"), text: $topic)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await generate() } }

            Button {
                Task { await generate() }
            } label: {
                Label(AppL10n.t("pack.gen.action"), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .disabled(store.isGeneratingPack || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if store.isGeneratingPack {
                progressBlock
            }

            if let error = store.packGenerationError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(theme.destructive)
                        .textSelection(.enabled)
                    Button(AppL10n.t("pack.gen.retry")) {
                        Task { await generate() }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let draft = store.generatedDraft {
                Divider()
                HStack {
                    Text(draft.title)
                        .font(.headline)
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Text(String(format: AppL10n.t("pack.gen.cardCount"), draft.cards.count))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.primary.opacity(0.14), in: Capsule())
                }
                if !draft.description.isEmpty {
                    Text(draft.description)
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.cards) { card in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.term).font(.subheadline.weight(.medium))
                                    Text(card.translation).font(.caption).foregroundStyle(theme.mutedForeground)
                                    if let context = card.context, !context.isEmpty {
                                        Text(context)
                                            .font(.caption2.italic())
                                            .foregroundStyle(theme.mutedForeground)
                                    }
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 260)

                if !existingPacks.isEmpty {
                    Picker(AppL10n.t("pack.gen.addTo"), selection: $targetPackID) {
                        Text(AppL10n.t("pack.gen.createNew")).tag(WordPack.ID?.none)
                        ForEach(existingPacks) { pack in
                            Text(pack.name).tag(WordPack.ID?.some(pack.id))
                        }
                    }
                }

                HStack {
                    Spacer()
                    if let targetPackID {
                        Button(String(format: AppL10n.t("pack.gen.addN"), draft.cards.count)) {
                            Task {
                                await store.appendGeneratedCards(packID: targetPackID)
                                isDone = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.primary)
                    } else {
                        Button(AppL10n.t("pack.gen.createPack")) {
                            Task {
                                await store.importPack(draft: draft)
                                store.discardGeneratedDraft()
                                isDone = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.primary)
                    }
                }
            }

            HStack {
                Spacer()
                Button(AppL10n.t("common.cancel")) {
                    store.clearPackGenerationError()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 560)
        .frame(minHeight: 280)
        .background(theme.background)
        .tint(theme.primary)
        .onAppear {
            targetPackID = preselectedPackID
            store.clearPackGenerationError()
            store.dismissError()
        }
        .onDisappear {
            store.clearPackGenerationError()
        }
        .onChange(of: isDone) { _, done in
            if done { dismiss() }
        }
    }

    @ViewBuilder
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = store.packGenerationProgress {
                switch progress.phase {
                case .requesting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(AppL10n.t("pack.gen.requesting"))
                            .font(.caption)
                            .foregroundStyle(theme.mutedForeground)
                    }
                case .translating(let done, let total):
                    Text(String(format: AppL10n.t("pack.gen.progress"), done, total))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.foreground)
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(theme.primary)
                    if let hint = progress.cardCountHint {
                        Text(String(format: AppL10n.t("pack.gen.cardCount"), hint))
                            .font(.caption2)
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppL10n.t("pack.gen.requesting"))
                        .font(.caption)
                        .foregroundStyle(theme.mutedForeground)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
    }

    private func generate() async {
        store.dismissError()
        _ = await store.generatePackCards(topic: topic)
    }
}
