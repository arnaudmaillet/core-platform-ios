import AVFoundation
import MediaPlayback

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
///
/// A song over HTTP(S) reads through the device's byte cache, as the clips
/// do (#895): `items` is the playback pool's `soundItem(for:)` in the app, so
/// a song heard on one page and again on the next is fetched once, and plays
/// with the network gone once it has been heard.
@MainActor
final class FeedSongPlayer {
    private var player: AVPlayer?
    private(set) var playingURL: URL?
    private var loop: NSObjectProtocol?
    private let items: @MainActor (URL) -> AVPlayerItem

    /// - Parameter items: the item for a song's URL. Without a pool, the URL
    ///   opened directly.
    init(items: @escaping @MainActor (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) }) {
        self.items = items
    }

    /// Songs through `playback`'s byte cache (`soundItem(for:)`), or opened
    /// directly without a pool.
    convenience init(playback: VideoPlaybackController?) {
        self.init(items: { url in playback?.soundItem(for: url) ?? AVPlayerItem(url: url) })
    }

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
            let item = items(url)
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

    /// The song's item, for the tests.
    var currentItem: AVPlayerItem? { player?.currentItem }
}
