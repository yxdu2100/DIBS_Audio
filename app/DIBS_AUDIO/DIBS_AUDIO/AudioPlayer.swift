import AVFoundation

/// Plays one recording at a time.
@Observable
final class AudioPlayer: NSObject {
    private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    /// Playback position; read it from a TimelineView to animate.
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    override init() {
        super.init()
        // Play through the speaker even with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playingURL = url
        } catch {
            playingURL = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
