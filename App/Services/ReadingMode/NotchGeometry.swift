import AppKit

/// Single wide capsule hanging just below the menu bar, an extension of the notch:
/// word + translation on the left, waveform + timer + close on the right.
enum NotchGeometry {
    /// Fixed capsule height — content never makes the container jump.
    /// Compact (~menu-bar scale) so it reads as an extension of the notch.
    static var capsuleHeight: CGFloat { 62 }
    /// Square top so the capsule top edge merges flush with the screen top / notch.
    static var topCornerRadius: CGFloat { 0 }
    /// Large bottom radius for the Dynamic-Island silhouette hanging from the notch.
    static var bottomCornerRadius: CGFloat { 26 }
    /// Breathing room on the left/right of the capsule so the soft shadow isn't clipped
    /// into a hard square edge (must exceed the shadow blur radius).
    static var horizontalInset: CGFloat { 28 }
    /// Breathing room above/below the capsule for the drop shadow (blur radius + offset).
    static var shadowPadding: CGFloat { 30 }
    /// Extra clearance kept on each side of the physical notch so content wraps around
    /// it (never behind it).
    static var notchClearance: CGFloat { 24 }
    /// Narrowest the capsule is allowed to shrink to (keeps the wide look).
    static var minWidth: CGFloat { 440 }
    /// Widest the capsule is allowed to grow (accommodates the reserved notch gap).
    static var maxWidth: CGFloat { 660 }

    /// Full panel height including the invisible padding used for the shadow.
    static func panelHeight() -> CGFloat {
        capsuleHeight + shadowPadding * 2
    }

    /// Width of the physical camera-housing notch, or 0 on displays without one.
    static func notchWidth(on screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, screen.frame.width - left.width - right.width)
    }

    /// Empty center column reserved so the left/right content groups wrap around the
    /// notch instead of disappearing behind it.
    static func centerGap(on screen: NSScreen? = NSScreen.main) -> CGFloat {
        let notch = notchWidth(on: screen)
        return notch > 0 ? notch + notchClearance : 16
    }

    /// Wide capsule centered horizontally, hanging just below the menu-bar band so it
    /// reads as a continuation of the notch and never collides with the physical notch.
    static func hudFrame(
        preferredWidth: CGFloat,
        on screen: NSScreen? = NSScreen.main
    ) -> NSRect {
        let panelH = panelHeight()
        guard let screen else {
            return NSRect(x: 0, y: 0, width: preferredWidth, height: panelH)
        }
        let frame = screen.frame
        let capsuleWidth = min(max(preferredWidth, minWidth), min(maxWidth, frame.width - 120))
        let panelWidth = capsuleWidth + horizontalInset * 2
        let x = frame.midX - panelWidth / 2
        // Pin the capsule top to the very top edge of the screen so it grows straight
        // out of the notch (no gap). Content wraps around the notch via the center gap.
        let capsuleTop = frame.maxY
        let y = capsuleTop - capsuleHeight - shadowPadding
        return NSRect(x: x, y: y, width: panelWidth, height: panelH)
    }
}
