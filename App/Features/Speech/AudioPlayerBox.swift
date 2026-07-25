import Foundation
import AVFoundation

/// Tiny retained wrapper so SwiftUI views can fire-and-forget playback of a user's
/// recorded pronunciation without holding an `@State` `AVAudioPlayer` per row.
@MainActor
final class AudioPlayerBox: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    init(url: URL) {
        super.init()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
    }

    func play() {
        player?.play()
    }
}
