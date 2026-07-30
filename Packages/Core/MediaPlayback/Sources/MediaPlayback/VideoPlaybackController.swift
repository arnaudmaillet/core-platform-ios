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
    /// The media URL each bound view is playing, so a parked player can be
    /// matched back to the same asset.
    private var playingURL: [ObjectIdentifier: URL] = [:]
    /// A player detached from its view but still running, waiting for the next
    /// `play` of the same URL to adopt it. See `parkPlayback(from:)`.
    private var parked: (url: URL, player: AVPlayer)?

    /// `poolSize` is the size of the **idle-player cache**, not a concurrency
    /// limit: `play` mints a new `AVPlayer` when the cache is empty, and the
    /// number of simultaneous players is set by the calling surface (the grid's
    /// `maxConcurrent`). Sizing it to match that surface is what keeps a scroll
    /// from allocating and discarding players continuously — a cache smaller
    /// than the working set drops every returned player on the floor.
    public init(source: any VideoSource, poolSize: Int = 6) {
        self.source = source
        self.poolSize = poolSize
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback)
    }

    /// Resolves `mediaURL`, loans a pooled player, binds it to `view`, and
    /// starts looping muted playback. Safe to call repeatedly; a superseding
    /// `play`/`stop` for the same view cancels an in-flight resolution.
    ///
    /// `peakBitRate` caps which rung of an adaptive ladder the item may select,
    /// in bits per second; `0` (the default) means uncapped. See
    /// `setPeakBitRate(_:in:)` for why this is a property of the item and not
    /// of the URL.
    public func play(_ mediaURL: URL, in view: VideoRenderView, peakBitRate: Double = 0) async {
        let key = ObjectIdentifier(view)
        let token = (generation[key] ?? 0) + 1
        generation[key] = token

        // A player parked for this exact asset is adopted whole — same item,
        // same playhead — instead of starting a second one at zero. This is the
        // grid → full-screen handoff, and it is synchronous: no resolution, no
        // await, so the destination is already showing the running video by the
        // time the flight begins. `peakBitRate` re-caps it on the way in, which
        // is how a tile pinned to the ladder's floor becomes an uncapped
        // full-screen player without the item ever being replaced.
        if let parked, parked.url == mediaURL {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print(String(format: "[zoom-live] %.3f ADOPTED parked player", CACurrentMediaTime()))
            }
            #endif
            self.parked = nil
            detach(key: key, view: view)
            parked.player.currentItem?.preferredPeakBitRate = peakBitRate
            view.attach(parked.player)
            activePlayers[key] = parked.player
            playingURL[key] = mediaURL
            parked.player.play()
            return
        }

        guard let playableURL = try? await source.playableURL(for: mediaURL) else { return }
        // Lost the race to a newer play/stop while resolving: drop this result.
        guard generation[key] == token else { return }

        detach(key: key, view: view)
        let player = idlePlayers.popLast() ?? AVPlayer()
        let item = AVPlayerItem(url: playableURL)
        // Set BEFORE the item goes live, so the very first segment request
        // already asks for the capped rung — set afterwards, the player has
        // usually committed to a higher one and the cap only takes effect at
        // the next switch point.
        item.preferredPeakBitRate = peakBitRate
        installLoop(for: player, item: item)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        view.attach(player)
        activePlayers[key] = player
        playingURL[key] = mediaURL
        player.play()
    }

    /// Detaches the player bound to `view` but keeps it **running**, parked
    /// under the URL it is playing, so the next `play` of that same URL adopts
    /// it rather than starting a second item.
    ///
    /// This is what carries the playhead from a grid tile into the full-screen
    /// page. The alternative — letting the destination open its own item —
    /// restarts at `CMTime.zero`, which is the break the hero transition exists
    /// to avoid; see `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §0.2.
    ///
    /// Only one player parks at a time: a second call returns the previous
    /// occupant to the pool, so a rapid double-tap cannot strand one. Returns
    /// whether there was anything to park.
    @discardableResult
    public func parkPlayback(from view: VideoRenderView) -> Bool {
        let key = ObjectIdentifier(view)
        guard let player = activePlayers[key], let url = playingURL[key] else { return false }
        discardParkedPlayback()
        // Cancel any in-flight resolution for this view so a late arrival can't
        // attach a fresh item over the surface we just cleared.
        generation[key] = (generation[key] ?? 0) + 1
        activePlayers[key] = nil
        playingURL[key] = nil
        view.detach()
        parked = (url, player)
        return true
    }

    /// Retires an unclaimed parked player — the flight was cancelled, or the
    /// destination never played it. Without this the player would keep decoding
    /// with nothing on screen.
    public func discardParkedPlayback() {
        guard let parked else { return }
        self.parked = nil
        parked.player.pause()
        removeLoop(for: parked.player)
        parked.player.replaceCurrentItem(with: nil)
        if idlePlayers.count < poolSize {
            idlePlayers.append(parked.player)
        }
    }

    /// Re-caps the bit rate of the item already playing in `view`, in bits per
    /// second; `0` lifts the cap entirely.
    ///
    /// **This mutates the live `AVPlayerItem` and never replaces it**, which is
    /// the entire point. The playhead belongs to the item, so swapping items to
    /// change quality would reset `currentTime` to zero — the restart the hero
    /// transition exists to avoid. Changing the cap in place lets ABR climb to a
    /// higher rung at its next switch point while the clock keeps running, which
    /// is how a grid tile capped to the ladder's floor becomes a full-quality
    /// full-screen player without a visible break.
    ///
    /// A no-op when `view` has no active player. See
    /// `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §0.3.
    public func setPeakBitRate(_ peakBitRate: Double, in view: VideoRenderView) {
        activePlayers[ObjectIdentifier(view)]?.currentItem?.preferredPeakBitRate = peakBitRate
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

    /// Re-asserts `view` as its own player's display surface. With multiple
    /// `AVPlayerLayer`s on one player, only the most recently attached one is
    /// guaranteed to display — after a mirror surface goes away (a cancelled
    /// hero flight), the original view reclaims the render slot. No-op if
    /// `view` has no active player.
    public func reclaim(_ view: VideoRenderView) {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return }
        view.attach(player)
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
        playingURL[key] = nil
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
    /// What rung an adaptive stream actually settled on, for QA.
    ///
    /// `preferred` is the ceiling we asked for; `indicated` is the declared
    /// bitrate of the variant AVFoundation chose. Comparing them is the only
    /// direct evidence that a cap did anything — byte counting can't tell a
    /// capped ladder from a progressive file, which ignores the cap entirely.
    /// `nil` when nothing is playing or the stream has produced no access log
    /// yet (progressive assets never do).
    public struct BitRateReport: Sendable {
        public let preferred: Double
        public let indicated: Double
        public let observed: Double
    }

    public func debugBitRateReport(in view: VideoRenderView) -> BitRateReport? {
        guard let item = activePlayers[ObjectIdentifier(view)]?.currentItem,
              let event = item.accessLog()?.events.last
        else { return nil }
        return BitRateReport(
            preferred: item.preferredPeakBitRate,
            indicated: event.indicatedBitrate,
            observed: event.observedBitrate
        )
    }

    var idlePlayerCount: Int { idlePlayers.count }
    func activePlayer(in view: VideoRenderView) -> AVPlayer? { activePlayers[ObjectIdentifier(view)] }
    func peakBitRate(in view: VideoRenderView) -> Double? {
        activePlayers[ObjectIdentifier(view)]?.currentItem?.preferredPeakBitRate
    }
    func currentItem(in view: VideoRenderView) -> AVPlayerItem? {
        activePlayers[ObjectIdentifier(view)]?.currentItem
    }
    #endif
}
