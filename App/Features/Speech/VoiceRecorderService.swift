import Foundation
import AVFoundation
import Observation

/// Microphone recorder with metering samples for waveform UI. No fabricated audio.
@MainActor
@Observable
final class VoiceRecorderService: NSObject {
    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var levels: [Float] = []
    private(set) var recordingURL: URL?
    private(set) var duration: TimeInterval = 0
    private(set) var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.permissionDenied = !granted
                    cont.resume(returning: granted)
                }
            }
        }
    }

    func start() throws {
        levels = []
        duration = 0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melingo-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else {
            throw VoiceRecorderError.failedToStart
        }
        self.recorder = recorder
        recordingURL = url
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickMeter()
            }
        }
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        // Capture length *before* stop — `currentTime` resets to 0 after stop on macOS.
        let captured = recorder?.currentTime ?? 0
        recorder?.stop()
        if captured > 0 {
            duration = captured
        }
        isRecording = false
        // Fall back to the finalized file duration if metering never wrote one.
        if duration <= 0 {
            duration = fileDuration() ?? duration
        }
    }

    func discard() {
        stop()
        stopPlayback()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        levels = []
        duration = 0
    }

    func play() throws {
        try playSelection(start: 0, end: duration > 0 ? duration : .greatestFiniteMagnitude)
    }

    /// Preview a trimmed range without exporting.
    func playSelection(start: TimeInterval, end: TimeInterval) throws {
        guard let url = recordingURL else { throw VoiceRecorderError.noRecording }
        stopPlayback()
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        // Prefer the file's own duration — more reliable than the recorder's last tick.
        if player.duration > 0, duration <= 0 || abs(duration - player.duration) > 0.25 {
            duration = player.duration
        }
        let total = player.duration > 0 ? player.duration : max(duration, end)
        let safeStart = max(0, min(start, total))
        let safeEnd = max(safeStart + 0.05, min(end.isFinite ? end : total, total))
        player.currentTime = safeStart
        self.player = player
        guard player.play() else { throw VoiceRecorderError.playbackFailed }
        isPlaying = true
        let remaining = safeEnd - safeStart
        stopTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopPlayback()
            }
        }
    }

    func stopPlayback() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// Trim with AVAssetExportSession; returns new temp m4a URL.
    func exportTrimmed(start: TimeInterval, end: TimeInterval) async throws -> URL {
        guard let source = recordingURL else { throw VoiceRecorderError.noRecording }
        let asset = AVURLAsset(url: source)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("melingo-trim-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw VoiceRecorderError.exportFailed
        }
        let total = duration > 0 ? duration : (fileDuration() ?? end)
        let safeStart = max(0, start)
        let safeEnd = max(safeStart + 0.05, min(end, total > 0 ? total : end))
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: safeStart, preferredTimescale: 600),
            duration: CMTime(seconds: safeEnd - safeStart, preferredTimescale: 600)
        )
        await session.export()
        guard session.status == .completed else {
            throw VoiceRecorderError.exportFailed
        }
        recordingURL = out
        duration = safeEnd - safeStart
        return out
    }

    private func fileDuration() -> TimeInterval? {
        guard let url = recordingURL else { return nil }
        let t = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
        return t > 0 ? t : nil
    }

    /// Re-read length from the m4a after recording stops (UI safety net).
    func refreshDurationFromFile() {
        if let t = fileDuration() {
            duration = t
        }
    }

    private func tickMeter() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        // Map dB (-60...0) → 0...1
        let normalized = max(0, min(1, (power + 60) / 60))
        levels.append(normalized)
        if levels.count > 240 { levels.removeFirst(levels.count - 240) }
        duration = recorder.currentTime
    }
}

extension VoiceRecorderService: AVAudioRecorderDelegate {}

enum VoiceRecorderError: Error {
    case failedToStart
    case noRecording
    case exportFailed
    case playbackFailed
}
