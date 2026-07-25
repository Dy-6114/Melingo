import AppKit
import SwiftUI

/// Lifecycle state of the reading-mode capsule. Drives the animated accent line
/// and the recording indicator.
enum ReadingModePhase: Equatable {
    case idle
    case listening
    case processing
    case saved
}

/// Wide black capsule hanging under the notch: circular icon + word + translation on
/// the left, live waveform + timer + close on the right, with an animated accent line.
struct ReadingModeHUDView: View {
    @Bindable var model: ReadingModeHUDModel
    var onClose: () -> Void

    @State private var appeared = false

    private var needsAccessibility: Bool {
        !AccessibilityPermission.isTrusted
    }

    private var showsTranslation: Bool {
        !model.translation.isEmpty || model.isTranslating
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: NotchGeometry.topCornerRadius,
            bottomLeadingRadius: NotchGeometry.bottomCornerRadius,
            bottomTrailingRadius: NotchGeometry.bottomCornerRadius,
            topTrailingRadius: NotchGeometry.topCornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        content
            .frame(height: NotchGeometry.capsuleHeight)
            .frame(maxWidth: .infinity)
            .background(capsuleBackground)
            .overlay(alignment: .bottom) { accentLine }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            }
            .clipShape(shape)
            // Shadow only below — the top edge stays fused with the notch.
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            .padding(.horizontal, NotchGeometry.horizontalInset)
            .padding(.vertical, NotchGeometry.shadowPadding)
            .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
            .opacity(appeared ? 1 : 0)
            .onAppear { animateAppearance(to: true) }
            .onChange(of: model.isVisible) { _, visible in
                animateAppearance(to: visible)
            }
    }

    private func animateAppearance(to visible: Bool) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            appeared = visible
        }
    }

    // MARK: - Content

    private var content: some View {
        HStack(spacing: 0) {
            wordZone
                .frame(maxWidth: .infinity, alignment: .leading)
            // Empty column sized to the physical notch so content wraps around it.
            Color.clear
                .frame(width: NotchGeometry.centerGap())
            controlZone
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
    }

    // MARK: - Left: word information

    private var wordZone: some View {
        HStack(spacing: 12) {
            leadingIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(barWord)
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if showsTranslation {
                    Text(translationText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            // Crossfade + gentle vertical slide whenever the word changes.
            .id(model.sourceText)
            .transition(.opacity.combined(with: .offset(x: 0, y: 7)))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.sourceText)
        }
    }

    private var barWord: String {
        if needsAccessibility { return AppL10n.t("readingMode.needAccessibility") }
        if model.sourceText.isEmpty { return AppL10n.t("readingMode.hint") }
        return model.sourceText
    }

    private var translationText: String {
        if model.isTranslating, model.translation.isEmpty { return "…" }
        return model.translation
    }

    private var leadingIcon: some View {
        Group {
            if needsAccessibility {
                Circle()
                    .fill(Color.orange.opacity(0.9))
                    .overlay {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            } else if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Circle()
                    .fill(Color.accentColor)
                    .overlay {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
        .contentShape(Circle())
        .onTapGesture {
            if needsAccessibility {
                AccessibilityPermission.requestIfNeeded()
                AccessibilityPermission.openSystemSettings()
            }
        }
    }

    // MARK: - Right: recording controls

    private var controlZone: some View {
        HStack(spacing: 12) {
            if model.phase == .saved {
                successChip
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                ReadingModeWaveform(active: isRecording)
                    .frame(width: 18, height: 15)
                    .transition(.opacity)
                Text(model.elapsedFormatted)
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity)
            }
            closeButton
        }
        // Nudge the right group up ~1px to sit on the optical center.
        .offset(y: -1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.phase)
    }

    private var isRecording: Bool {
        model.isActive
            && !model.sourceText.isEmpty
            && !needsAccessibility
            && model.phase != .saved
    }

    private var successChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(AppL10n.t("readingMode.added"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(AppL10n.t("readingMode.close"))
    }

    // MARK: - Background

    private var capsuleBackground: some View {
        // Pure, opaque black to exactly match the physical notch in any appearance
        // (light or dark) — the capsule reads as a continuation of the notch, not a HUD.
        Color.black
    }

    // MARK: - Accent line (state indicator)

    private var accentLine: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.04))
            GeometryReader { geo in
                accentIndicator(width: geo.size.width)
            }
        }
        .frame(height: 2)
        // Start/end with the same insets as the content, not edge-to-edge.
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.bottom, 3)
        .opacity(0.7)
        // Soft, diffuse glow instead of a hard neon line.
        .shadow(color: Color.accentColor.opacity(0.3), radius: 4, y: 0)
    }

    @ViewBuilder
    private func accentIndicator(width: CGFloat) -> some View {
        switch model.phase {
        case .idle:
            Color.clear
        case .listening:
            // Gentle breathing pulse across the full width, kept subtle (~50–70%).
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.4 + 0.3 * (sin(t * 2.2) + 1) / 2
                Capsule()
                    .fill(Color.accentColor.opacity(pulse))
                    .frame(width: width, height: 2)
            }
        case .processing:
            // Indeterminate sliding segment.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let span = width * 0.42
                let x = CGFloat((sin(t * 2) + 1) / 2) * (width - span)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: span, height: 2)
                    .offset(x: x)
            }
        case .saved:
            Capsule()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: width, height: 2)
        }
    }
}

// MARK: - Waveform

private struct ReadingModeWaveform: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let bars = 4
                let gap: CGFloat = 1.5
                let barWidth = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
                for i in 0..<bars {
                    let phase = t * (active ? 3.4 : 0) + Double(i) * 0.75
                    let amp = active
                        ? (0.3 + 0.7 * abs(sin(phase)))
                        : (0.22 + 0.14 * Double(i % 2))
                    let h = size.height * CGFloat(amp)
                    let x = CGFloat(i) * (barWidth + gap)
                    let y = (size.height - h) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: max(2, h))
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(active ? .accentColor : Color.white.opacity(0.4))
                    )
                }
            }
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class ReadingModeHUDModel {
    var isVisible = false
    var isActive = false
    var isTranslating = false
    var sourceText = ""
    var translation = ""
    var elapsedSeconds: Int = 0
    var phase: ReadingModePhase = .idle

    var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
