import SwiftUI

/// Layout / type tokens adapted from Revu’s DesignSystem — kept separate from
/// `ThemeTokens` (system colors) so Melingo stays accent-native while gaining
/// consistent spacing and type hierarchy.
enum DesignTokens {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let card: CGFloat = 14
        static let sheet: CGFloat = 20
    }

    enum Typography {
        static var hero: Font { .system(.largeTitle, design: .default).weight(.bold) }
        static var title: Font { .system(.title, design: .default).weight(.semibold) }
        static var heading: Font { .system(.title2, design: .default).weight(.semibold) }
        static var subheading: Font { .system(.title3, design: .default).weight(.medium) }
        static var body: Font { .system(.body, design: .default) }
        static var bodyMedium: Font { .system(.body, design: .default).weight(.medium) }
        static var caption: Font { .system(.caption, design: .default) }
        static var captionMedium: Font { .system(.caption, design: .default).weight(.medium) }
        static var mono: Font { .system(.body, design: .monospaced).weight(.medium) }
    }

    enum Animation {
        static let snappy = SwiftUI.Animation.snappy(duration: 0.22)
        static let soft = SwiftUI.Animation.easeInOut(duration: 0.2)
    }
}
