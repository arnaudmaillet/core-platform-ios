import AVFoundation
import CoreMedia
import Foundation

/// The app-wide video playback subsystem for the snap feed: a small pool of
/// reused `AVPlayer`s (video playback is memory-heavy — never one player per
/// cell), plus preroll for the next page. It plugs into the snap feed's
/// active-cell lifecycle: the active cell calls `play(_:in:)`, and `stop(_:)`
/// on resign returns the player to the pool.
///
/// The public API takes only `URL` and `VideoRenderView` — no AVFoundation
/// types leak to callers. Playback is muted by default under the `.ambient`
/// audio session (obeys the ringer, mixes with other audio); clips loop by
/// seeking to zero at end of item. Unmute-on-tap is a later refinement.
@MainActor
public final class VideoPlaybackController {
    private let source: any VideoSource
    private let poolSize: Int
    private var idlePlayers: [AVPlayer] = []
    /// Player currently bound to each render view.
    private var activePlayers: [ObjectIdentifier: AVPlayer] = [:]
    /// Bumped on every play/stop for a view so a slow `playableURL` resolution
    /// that lost the race is discarded instead of attaching to a recycled cell.
    private var generation: [ObjectIdentifier: Int] = [:]
    private var loopObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    public init(source: any VideoSource, poolSize: Int = 3) {
        self.source = source
        self.poolSize = poolSize
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback)
    }

    /// Resolves `mediaURL`, loans a pooled player, binds it to `view`, and
    /// starts looping muted playback. Safe to call repeatedly; a superseding
    /// `play`/`stop` for the same view cancels an in-flight resolution.
    public func play(_ mediaURL: URL, in view: VideoRenderView) async {
        let key = ObjectIdentifier(view)
        let token = (generation[key] ?? 0) + 1
        generation[key] = token

        guard let playableURL = try? await source.playableURL(for: mediaURL) else { return }
        // Lost the race to a newer play/stop while resolving: drop this result.
        guard generation[key] == token else { return }

        detach(key: key, view: view)
        let player = idlePlayers.popLast() ?? AVPlayer()
        let item = AVPlayerItem(url: playableURL)
        installLoop(for: player, item: item)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        view.attach(player)
        activePlayers[key] = player
        player.play()
    }

    /// Unbinds `view` and returns its player to the pool. Also cancels any
    /// in-flight `play` for the view.
    public func stop(_ view: VideoRenderView) {
        let key = ObjectIdentifier(view)
        generation[key] = (generation[key] ?? 0) + 1
        detach(key: key, view: view)
    }

    /// Toggles play/pause for the player bound to `view` (a user tapping the
    /// full-screen cell). Returns the new paused state. No-op returning `false`
    /// when no player is active for the view (e.g. an image/text cell).
    @discardableResult
    public func togglePlayback(in view: VideoRenderView) -> Bool {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return false }
        if player.timeControlStatus == .paused {
            player.play()
            return false
        } else {
            player.pause()
            return true
        }
    }

    /// Attaches the player currently rendering in `view` to `mirrorView` as an
    /// additional surface. Both layers are driven by the *same* `AVPlayer`, so
    /// they show the same frame with no clock to synchronize — the seam the
    /// hero transition uses to fly a live pin without freezing it. The mirror
    /// is passive: it holds no pool loan, and discarding `mirrorView` (or
    /// `stop(_:)` on the primary view) simply ends it. Returns whether `view`
    /// actually had a player to mirror.
    @discardableResult
    public func mirror(from view: VideoRenderView, to mirrorView: VideoRenderView) -> Bool {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return false }
        mirrorView.attach(player)
        return true
    }

    /// Warms the source (synthesis/cache) for an upcoming page so its `play` is
    /// instant. No player is loaned.
    public func preroll(_ mediaURL: URL) {
        let source = source
        Task { _ = try? await source.playableURL(for: mediaURL) }
    }

    // MARK: - Internals

    private func detach(key: ObjectIdentifier, view: VideoRenderView) {
        view.detach()
        guard let player = activePlayers.removeValue(forKey: key) else { return }
        player.pause()
        removeLoop(for: player)
        player.replaceCurrentItem(with: nil)
        if idlePlayers.count < poolSize {
            idlePlayers.append(player)
        }
    }

    private func installLoop(for player: AVPlayer, item: AVPlayerItem) {
        removeLoop(for: player)
        loopObservers[ObjectIdentifier(player)] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                player?.play()
            }
        }
    }

    private func removeLoop(for player: AVPlayer) {
        if let observer = loopObservers.removeValue(forKey: ObjectIdentifier(player)) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Test hooks

    #if DEBUG
    var idlePlayerCount: Int { idlePlayers.count }
    func activePlayer(in view: VideoRenderView) -> AVPlayer? { activePlayers[ObjectIdentifier(view)] }
    #endif
}
