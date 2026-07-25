import SwiftUI

/// Keyboard cheat sheet — Help → Keyboard Shortcuts (⌘/).
struct ShortcutsHelpView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppL10n.t("help.shortcuts"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(AppL10n.t("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(AppL10n.t("help.section.reader"), rows: [
                        ("← / →", AppL10n.t("help.reader.move")),
                        ("S", AppL10n.t("help.reader.speak")),
                        ("E", AppL10n.t("help.reader.explain")),
                        ("T", AppL10n.t("help.reader.translate")),
                        ("R", AppL10n.t("help.reader.reading")),
                        ("Esc", AppL10n.t("help.reader.escape")),
                        ("⌘-click", AppL10n.t("help.reader.multi")),
                    ])
                    section(AppL10n.t("help.section.review"), rows: [
                        ("Space", AppL10n.t("help.review.reveal")),
                        ("1", AppL10n.t("help.review.again")),
                        ("2", AppL10n.t("help.review.hard")),
                        ("3", AppL10n.t("help.review.good")),
                        ("4", AppL10n.t("help.review.easy")),
                        ("S", AppL10n.t("help.review.speak")),
                        ("H", AppL10n.t("help.review.hint")),
                        ("Z", AppL10n.t("help.review.undo")),
                        ("B", AppL10n.t("help.review.bury")),
                        ("P", AppL10n.t("help.review.suspend")),
                    ])
                    section(AppL10n.t("help.section.global"), rows: [
                        ("⌘K", AppL10n.t("help.global.quickFind")),
                        ("⌘R", AppL10n.t("help.global.review")),
                        ("⌘⌥R", AppL10n.t("help.global.reviewWindow")),
                        ("⌘N", AppL10n.t("help.global.newCard")),
                        ("⌘,", AppL10n.t("help.global.settings")),
                        ("⌘/", AppL10n.t("help.global.this")),
                        ("⌘V", AppL10n.t("help.global.pasteOCR")),
                        ("⌘⇧R", AppL10n.t("help.global.readingMode")),
                    ])
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 520)
        .background(theme.background)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.foreground)
            ForEach(rows, id: \.0) { key, desc in
                HStack(alignment: .firstTextBaseline) {
                    Text(key)
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 88, alignment: .leading)
                    Text(desc)
                        .font(.body)
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
