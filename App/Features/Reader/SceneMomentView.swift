import AppKit
import SwiftUI
import Domain

/// Full-bleed hero or mid-article “scene” from a web import illustration.
struct SceneMomentView: View {
    @Environment(\.theme) private var theme
    let illustration: ArticleIllustration
    let localURL: URL?
    var isHero: Bool = false

    @State private var appear = false
    @State private var lightbox = false

    var body: some View {
        Button {
            lightbox = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    imageLayer
                        .frame(maxWidth: .infinity)
                        .frame(height: isHero ? 220 : 160)
                        .clipped()
                        .scaleEffect(appear ? 1.0 : 1.06)
                        .animation(.easeOut(duration: 1.2), value: appear)

                    LinearGradient(
                        colors: [.clear, .black.opacity(isHero ? 0.45 : 0.28)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    if let caption = illustration.altText, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: isHero ? 13 : 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                            .padding(12)
                    } else if isHero {
                        Text(AppL10n.t("reader.scene.hero"))
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: isHero ? 14 : 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: isHero ? 14 : 10, style: .continuous)
                        .strokeBorder(theme.border.opacity(0.35), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { appear = true }
        }
        .sheet(isPresented: $lightbox) {
            SceneLightboxView(illustration: illustration, localURL: localURL)
        }
        .accessibilityLabel(illustration.altText ?? AppL10n.t("reader.scene.hero"))
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let localURL,
           let nsImage = NSImage(contentsOf: localURL) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else if let url = URL(string: illustration.remoteURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    placeholder.overlay { ProgressView().controlSize(.small) }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(theme.muted.opacity(0.35))
    }
}

private struct SceneLightboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let illustration: ArticleIllustration
    let localURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let caption = illustration.altText, !caption.isEmpty {
                    Text(caption)
                        .font(.headline)
                        .lineLimit(2)
                } else {
                    Text(AppL10n.t("reader.scene.hero"))
                        .font(.headline)
                }
                Spacer()
                Button(AppL10n.t("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Group {
                if let localURL, let nsImage = NSImage(contentsOf: localURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                } else if let url = URL(string: illustration.remoteURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        AppL10n.t("reader.scene.unavailable"),
                        systemImage: "photo"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(theme.background)
    }
}
