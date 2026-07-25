import SwiftUI

/// Waveform trim UI over a just-finished recording. Draws real metering levels from
/// `VoiceRecorderService` via `Canvas` — no synthetic waveform — with draggable start/end
/// handles, Play/Stop preview of the selection, and Keep/Discard actions.
struct VoiceTrimView: View {
    @Environment(\.theme) private var theme
    let recorder: VoiceRecorderService
    var onKeep: (URL) -> Void
    var onDiscard: () -> Void

    @State private var startFraction: Double = 0
    @State private var endFraction: Double = 1
    @State private var isExporting = false
    @State private var exportError: String?

    private enum Handle { case start, end }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            waveform
                .frame(height: 64)

            HStack {
                Text(timeLabel(startFraction * recorder.duration))
                Spacer()
                previewControls
                Spacer()
                Text(timeLabel(endFraction * recorder.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(theme.mutedForeground)

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(theme.destructive)
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    recorder.stopPlayback()
                    recorder.discard()
                    onDiscard()
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await keep() }
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Keep", systemImage: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(isExporting || recorder.recordingURL == nil)
            }
        }
        .onAppear {
            recorder.refreshDurationFromFile()
        }
        .onDisappear {
            recorder.stopPlayback()
        }
    }

    private var previewControls: some View {
        HStack(spacing: 8) {
            Button {
                do {
                    if recorder.duration <= 0 {
                        recorder.refreshDurationFromFile()
                    }
                    try recorder.playSelection(
                        start: startFraction * recorder.duration,
                        end: endFraction * recorder.duration
                    )
                } catch {
                    exportError = "Couldn’t play the selection."
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(recorder.recordingURL == nil || recorder.isPlaying)

            Button {
                recorder.stopPlayback()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!recorder.isPlaying)
        }
        .controlSize(.small)
    }

    private var waveform: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let levels = recorder.levels
                    guard !levels.isEmpty else { return }
                    let barWidth = size.width / CGFloat(levels.count)
                    for (index, level) in levels.enumerated() {
                        let x = CGFloat(index) * barWidth
                        let barHeight = max(2, CGFloat(level) * size.height)
                        let rect = CGRect(
                            x: x,
                            y: (size.height - barHeight) / 2,
                            width: max(1, barWidth - 1),
                            height: barHeight
                        )
                        let fraction = Double(index) / Double(max(levels.count - 1, 1))
                        let inSelection = fraction >= startFraction && fraction <= endFraction
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(inSelection ? theme.primary : theme.mutedForeground.opacity(0.35))
                        )
                    }
                }

                Rectangle()
                    .fill(theme.background.opacity(0.6))
                    .frame(width: max(0, geo.size.width * startFraction))

                Rectangle()
                    .fill(theme.background.opacity(0.6))
                    .frame(width: max(0, geo.size.width * (1 - endFraction)))
                    .offset(x: geo.size.width * endFraction)

                handle(fraction: startFraction, target: .start, geo: geo)
                handle(fraction: endFraction, target: .end, geo: geo)
            }
        }
        .background(theme.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OKRadius.chip, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        .accessibilityLabel("Recording waveform")
    }

    private func handle(fraction: Double, target: Handle, geo: GeometryProxy) -> some View {
        Rectangle()
            .fill(theme.primary)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -8))
            .offset(x: geo.size.width * fraction - 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        recorder.stopPlayback()
                        let newFraction = min(max(0, value.location.x / max(geo.size.width, 1)), 1)
                        switch target {
                        case .start:
                            startFraction = min(newFraction, endFraction - 0.02)
                        case .end:
                            endFraction = max(newFraction, startFraction + 0.02)
                        }
                    }
            )
            .accessibilityLabel(target == .start ? "Trim start" : "Trim end")
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func keep() async {
        recorder.stopPlayback()
        if recorder.duration <= 0 {
            recorder.refreshDurationFromFile()
        }
        isExporting = true
        defer { isExporting = false }
        do {
            let start = startFraction * recorder.duration
            let end = endFraction * recorder.duration
            let url = try await recorder.exportTrimmed(start: start, end: end)
            exportError = nil
            onKeep(url)
        } catch {
            exportError = "Couldn’t trim the recording."
        }
    }
}
