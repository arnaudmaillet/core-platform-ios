import AVFoundation

/// Plays the sound of a page that is NOT a clip — a photograph, a collection
/// of them, a text post — while that page owns the screen.
///
/// A clip carries its sound in its own player, which the playback controller
/// makes audible (`setAudibleSurface`). A photograph has no player to hear,
/// so the feed keeps this one, looping the sound the page is set to, under
/// the same rules: the page that owns the screen, the session's mute, and
/// nothing while the screen is covered or in the background.
///
/// Under the app's `.ambient` session, like the clips: a feed that starts
/// playing on its own respects the ring switch.
@MainActor
final class FeedSongPlayer {
    private var player: AVPlayer?
    private(set) var playingURL: URL?
    private var loop: NSObjectProtocol?

    /// Plays `url` from its start, or resumes it where it paused when it is
    /// the one already loaded. Nil pauses — the position is kept, so a sheet
    /// that covered the page gives it back mid-song.
    func play(_ url: URL?) {
        guard let url else {
            player?.pause()
            return
        }
        if url != playingURL {
            if let loop { NotificationCenter.default.removeObserver(loop) }
            let item = AVPlayerItem(url: url)
            let player = self.player ?? AVPlayer()
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .none
            loop = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak player] _ in
                MainActor.assumeIsolated { player?.seek(to: .zero) }
            }
            self.player = player
            playingURL = url
        }
        player?.play()
    }

    /// Drops the song — the page it belonged to is gone.
    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let loop { NotificationCenter.default.removeObserver(loop) }
        loop = nil
        playingURL = nil
    }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }
}
