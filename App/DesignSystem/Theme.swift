import SwiftUI
import AppKit

/// Semantic color tokens — always derived from macOS system appearance + accent.
struct ThemeTokens: Sendable {
    var background: Color
    var foreground: Color
    var card: Color
    var cardForeground: Color
    var primary: Color
    var primaryForeground: Color
    var secondary: Color
    var secondaryForeground: Color
    var muted: Color
    var mutedForeground: Color
    var accent: Color
    var accentForeground: Color
    var destructive: Color
    var destructiveForeground: Color
    var border: Color
    var input: Color
    var ring: Color

    var explained: Color { Color(nsColor: .systemGreen) }
    var translatedHint: Color { Color(nsColor: .systemYellow) }
    var vocabAccent: Color { Color(nsColor: .systemOrange) }
    var grammarAccent: Color { Color(nsColor: .systemPurple) }

    var srsStrong: Color { Color(nsColor: .systemGreen) }
    var srsFading: Color { Color(nsColor: .systemOrange) }
    var srsWeak: Color { Color(nsColor: .systemRed) }

    func srsColor(for retention: Double) -> Color {
        if retention >= 0.9 { return srsStrong }
        if retention >= 0.7 { return srsFading }
        return srsWeak
    }

    /// Dynamic AppKit system colors (light/dark + accent follow System Settings).
    static var system: ThemeTokens {
        ThemeTokens(
            background: Color(nsColor: .windowBackgroundColor),
            foreground: Color(nsColor: .labelColor),
            card: Color(nsColor: .controlBackgroundColor),
            cardForeground: Color(nsColor: .labelColor),
            primary: Color(nsColor: .controlAccentColor),
            primaryForeground: Color(nsColor: .alternateSelectedControlTextColor),
            secondary: Color(nsColor: .controlColor),
            secondaryForeground: Color(nsColor: .labelColor),
            muted: Color(nsColor: .underPageBackgroundColor),
            mutedForeground: Color(nsColor: .secondaryLabelColor),
            accent: Color(nsColor: .controlAccentColor),
            accentForeground: Color(nsColor: .alternateSelectedControlTextColor),
            destructive: Color(nsColor: .systemRed),
            destructiveForeground: Color(nsColor: .white),
            border: Color(nsColor: .separatorColor),
            input: Color(nsColor: .separatorColor),
            ring: Color(nsColor: .controlAccentColor)
        )
    }
}

enum OKRadius {
    static let control: CGFloat = 8
    static let chip: CGFloat = 12
    static let field: CGFloat = 14
    static let card: CGFloat = 16
    static let sheet: CGFloat = 20
}

@MainActor
@Observable
final class ThemeManager {
    /// Always mirrors System Settings — no custom palettes.
    func tokens(for _: ColorScheme) -> ThemeTokens {
        .system
    }
}

extension EnvironmentValues {
    @Entry var theme: ThemeTokens = .system
}
