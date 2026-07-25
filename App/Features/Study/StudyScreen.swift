import SwiftUI

/// Shared chrome so Study destinations always fill the detail column and stay visible
/// inside `NavigationSplitView` → `NavigationStack` (avoids blank white pages).
struct StudyScreen<Content: View>: View {
    @Environment(\.theme) private var theme
    var mode: StudyDestination?
    var maxContentWidth: CGFloat = 720
    @ViewBuilder var content: () -> Content

    init(
        mode: StudyDestination? = nil,
        maxContentWidth: CGFloat = 720,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.mode = mode
        self.maxContentWidth = maxContentWidth
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .trackStudyActivity(mode: mode?.rawValue ?? "study")
    }
}

struct StudyCallout: View {
    @Environment(\.theme) private var theme
    var text: String
    /// Icons optional — Study hub prefers text-only callouts (no colored glyphs).
    var systemImage: String? = nil

    var body: some View {
        Group {
            if let systemImage {
                Label {
                    Text(text)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(theme.mutedForeground)
                }
            } else {
                Text(text)
            }
        }
        .font(.callout)
        .foregroundStyle(theme.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.muted.opacity(0.45), in: RoundedRectangle(cornerRadius: OKRadius.control, style: .continuous))
    }
}
