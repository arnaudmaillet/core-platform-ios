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
    /// The frame renderer for each pooled player, under `-avsbdl-render`.
    ///
    /// Keyed by **player**, not by view, and that is the whole idea: the
    /// renderer owns the player's video output, so it travels with the player
    /// through park → adopt and survives being handed between surfaces. A view
    /// joining or leaving its surface set is bookkeeping that draws nothing.
    /// Empty when the flag is off.
    private var renderers: [ObjectIdentifier: VideoFrameRenderer] = [:]

    /// How many players may be bound to surfaces at once.
    ///
    /// ⚠️ NOT `poolSize`, and the two were conflated for as long as nothing
    /// asked. `poolSize` is the idle cache; this is the working set. A caller
    /// deciding how much of the budget it may hold — a carousel keeping its
    /// clips warm across a page change — asks THIS one.
    ///
    /// It is a budget rather than an enforced ceiling: `play` still binds what
    /// it is told to bind, because a surface that asked for a picture and got
    /// silence is a worse failure than one player too many. What the number
    /// buys is that every claimant can size itself against the same figure
    /// instead of inventing its own.
    ///
    /// Six, because the ceiling that actually bites is the device's video
    /// decoders, not memory — simultaneous hardware decode sessions are a small
    /// number on every phone this ships to, and a seventh clip does not stutter
    /// politely, it starves one of the six already playing.
    public let capacity: Int

    /// How many surfaces are holding a player right now. The measurement the
    /// capacity claim is worth nothing without — see `VideoPoolIdentityTests`,
    /// which asserts it against the number of distinct clips on screen.
    public var activePlayerCount: Int { activePlayers.count }

    /// `poolSize` is the size of the **idle-player cache**, not a concurrency
    /// limit: `play` mints a new `AVPlayer` when the cache is empty, and the
    /// number of simultaneous players is `capacity`. Sizing the cache to match
    /// the working set is what keeps a scroll from allocating and discarding
    /// players continuously — a cache smaller than the working set drops every
    /// returned player on the floor. They default to the same number for that
    /// reason, and are separate because they answer different questions.
    public init(source: any VideoSource, poolSize: Int = 6, capacity: Int = 6) {
        self.source = source
        self.poolSize = poolSize
        self.capacity = capacity
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
            bind(parked.player, to: view)
            activePlayers[key] = parked.player
            playingURL[key] = mediaURL
            parked.player.play()
            return
        }

        // ⚠️ ONE ASSET, ONE PLAYER — including one that is already ACTIVE.
        //
        // The branch above adopts a PARKED player, which is the handoff. It
        // left a second case open: a player running this same asset for another
        // surface. That happens by construction now — a card holds a clip
        // paused on its page while the post opens the same clip — and minting a
        // second one gives the asset two decoders on two clocks. The codebase
        // has met that before (see `startDeferredPlayback`'s note on the
        // cold-open race): the surface a viewer is looking at ends up bound to
        // whichever of them a lookup happens to find, and a paused one behind a
        // visible surface is a picture that has stopped for no visible reason.
        //
        // Joining is cheap and synchronous — no resolution, no await — so it
        // also removes a start-up delay on the second surface.
        // ⚠️ ONE ASSET, ONE PLAYER — including one that is already ACTIVE.
        //
        // The branch above adopts a PARKED player, which is the handoff. It
        // left a second case open: a player running this same asset for another
        // surface. That happens by construction now — a card holds a clip
        // paused on its page while the post opens the same clip — and minting a
        // second one gives the asset two decoders on two clocks. The codebase
        // has met that before (see `startDeferredPlayback`'s note on the
        // cold-open race): the surface a viewer is looking at ends up bound to
        // whichever of them a lookup happens to find, and a paused one behind a
        // visible surface is a picture that has stopped for no visible reason.
        //
        // Joining is cheap and synchronous — no resolution, no await — so it
        // also removes a start-up delay on the second surface.
        if let shared = sharedActivePlayer(playing: mediaURL),
           shared !== activePlayers[key] {
            detach(key: key, view: view)
            shared.currentItem?.preferredPeakBitRate = peakBitRate
            bind(shared, to: view)
            activePlayers[key] = shared
            playingURL[key] = mediaURL
            shared.play()
            return
        }

        guard let playableURL = try? await source.playableURL(for: mediaURL) else { return }
        // Lost the race to a newer play/stop while resolving: drop this result.
        guard generation[key] == token else { return }
        // ⚠️ AND ASK AGAIN, because the check above happened before an await.
        //
        // Two surfaces asking for the same asset at once — a grid row and the
        // page opening over it — both passed the first check while neither had
        // registered yet, and both minted. That is the cold-open race this
        // file's other notes describe, and it is why the fast path alone left
        // duplicates in the log: measured at 12 in one battery, always on the
        // asset that two surfaces reach for simultaneously.
        //
        // Cheap: one dictionary lookup on a path that has just done I/O.
        if let shared = sharedActivePlayer(playing: mediaURL), shared !== activePlayers[key] {
            detach(key: key, view: view)
            shared.currentItem?.preferredPeakBitRate = peakBitRate
            bind(shared, to: view)
            activePlayers[key] = shared
            playingURL[key] = mediaURL
            shared.play()
            return
        }

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
        renderer(for: player)?.setItem(item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        bind(player, to: view)
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
    /// `keepingSurfaceAttached` leaves `view` bound to the player instead of
    /// clearing it. Used when the surface has been DONATED to a flight card:
    /// the card is that same view, already rendering, and detaching would blank
    /// the layer — which is the flash this exists to avoid. The surface stops
    /// displaying naturally when the adopter attaches its own layer, since only
    /// the most recently attached one renders.
    @discardableResult
    public func parkPlayback(from view: VideoRenderView, keepingSurfaceAttached: Bool = false) -> Bool {
        let key = ObjectIdentifier(view)
        guard let player = activePlayers[key], let url = playingURL[key] else { return false }
        discardParkedPlayback()
        // Cancel any in-flight resolution for this view so a late arrival can't
        // attach a fresh item over the surface we just cleared.
        generation[key] = (generation[key] ?? 0) + 1
        activePlayers[key] = nil
        playingURL[key] = nil
        if !keepingSurfaceAttached { view.detach() }
        parked = (url, player)
        return true
    }
    /// The URL of the player currently parked for a handoff, if any. Read by
    /// diagnostics that need to explain why an unpark was refused.
    public var parkedURL: URL? { parked?.url }

    /// Cancels a park, re-registering the parked player as `view`'s active one.
    ///
    /// For a dismissal the viewer abandons: the surface was donated to a flight
    /// card and its player parked, and both have to come back without the item
    /// being touched. The view is re-attached rather than assumed still bound,
    /// so this works whether or not the donation kept the surface attached.
    @discardableResult
    public func unparkPlayback(to view: VideoRenderView, mediaURL: URL) -> Bool {
        guard let parked, parked.url == mediaURL else { return false }
        self.parked = nil
        let key = ObjectIdentifier(view)
        bind(parked.player, to: view)
        activePlayers[key] = parked.player
        playingURL[key] = mediaURL
        parked.player.play()
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
        renderers[ObjectIdentifier(parked.player)]?.invalidate()
        if idlePlayers.count < poolSize {
            idlePlayers.append(parked.player)
        } else {
            // Same rule as `detach`: a dropped player takes its renderer entry
            // with it, or the map retains both forever.
            renderers.removeValue(forKey: ObjectIdentifier(parked.player))
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
        VideoPlaybackTrace.emit("stop \(playingURL[key]?.lastPathComponent ?? "-")")
        generation[key] = (generation[key] ?? 0) + 1
        detach(key: key, view: view)
    }

    /// How many DISTINCT players are currently on each asset.
    ///
    /// ⚠️ The answer should always be one. Two players on one URL means two
    /// decoders on two clocks: the surface a viewer is looking at can be bound
    /// to whichever of them a lookup happens to find, and a paused one behind a
    /// visible surface is a picture that has stopped moving for no reason the
    /// caller can see. The codebase has met this before — `startDeferredPlayback`
    /// carries a note about the cold-open race minting a second player — and it
    /// is measured here rather than reasoned about.
    public var playerCountByURL: [URL: Int] {
        var players: [URL: Set<ObjectIdentifier>] = [:]
        for (key, url) in playingURL {
            guard let player = activePlayers[key] else { continue }
            players[url, default: []].insert(ObjectIdentifier(player))
        }
        if let parked {
            players[parked.url, default: []].insert(ObjectIdentifier(parked.player))
        }
        return players.mapValues(\.count)
    }

    /// Whether the player bound to `view` is actually advancing.
    ///
    /// ⚠️ Distinct from "has a player" and from "is visible", and the gap
    /// between the three is what a frozen picture IS: a surface on screen,
    /// bound to a player, that is not moving. Paused is a legitimate state —
    /// a clip one page over is meant to be paused — so the question only means
    /// something next to whether the viewer is looking at it.
    public func isAdvancing(in view: VideoRenderView) -> Bool {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return false }
        return player.timeControlStatus != .paused
    }

    /// Whether `view` currently has a player bound to it.
    ///
    /// Exists for the carousel audit: "this cell is playing" is a fact the
    /// coordinator holds, and "this surface can draw" is a fact the pool holds,
    /// and the whole class of defects this session chased lives in the gap
    /// between the two.
    public func hasPlayer(in view: VideoRenderView) -> Bool {
        activePlayers[ObjectIdentifier(view)] != nil
    }

    /// Pauses or resumes the player rendering in `view`, without releasing it.
    ///
    /// ⚠️ Explicit, not a toggle, because this one is used for RECONCILIATION.
    /// A toggle answers "flip whatever you are", which is right for a tap and
    /// wrong for "make this match the world": two reconciles in a row would
    /// undo each other, and one missed edge leaves the state inverted for good.
    ///
    /// The loan is untouched — the player, its item and its decoded frame stay
    /// exactly where they are, which is the whole point: a paused surface keeps
    /// showing its last frame, and resuming costs nothing.
    ///
    /// Returns whether there was a player to move.
    @discardableResult
    public func setPaused(_ paused: Bool, in view: VideoRenderView) -> Bool {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return false }
        if paused {
            player.pause()
        } else {
            player.play()
        }
        return true
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
        bind(player, to: mirrorView)
        return true
    }

    /// Re-asserts `view` as its own player's display surface. With multiple
    /// `AVPlayerLayer`s on one player, only the most recently attached one is
    /// guaranteed to display — after a mirror surface goes away (a cancelled
    /// hero flight), the original view reclaims the render slot. No-op if
    /// `view` has no active player.
    public func reclaim(_ view: VideoRenderView) {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return }
        bind(player, to: view)
    }

    // MARK: - Surfaces

    /// Makes `view` show whatever is already playing `mediaURL`, alongside the
    /// surfaces already showing it. Returns whether anything was playing it.
    ///
    /// **This is the one mechanism `park` / `unpark` / `donate` / `adopt` /
    /// `mirror` / `hold` were six approximations of** (#83, criterion 8). All
    /// six exist because an `AVPlayer` renders into exactly one
    /// `AVPlayerLayer`, so "show this video somewhere else" had to mean *move*
    /// the render slot, and every move costs a decode round-trip during which
    /// neither layer draws. Under `-avsbdl-render` there is no slot to move:
    /// the renderer dispatches each decoded frame to every attached surface, so
    /// a second surface is an insertion into a set and the first one never
    /// notices.
    ///
    /// Keyed by URL rather than by a source view because the caller usually
    /// does not have the source view — a flight card knows which post it is
    /// flying, not which cell currently owns its layer. That indirection is
    /// what let the transition stop reaching into the grid's internals.
    ///
    /// Passive, exactly like `mirror` was: the attached surface holds no pool
    /// loan, so releasing it (or `stop`ping the owning view) simply ends it.
    ///
    /// **Degrades honestly with the flag off.** In `AVPlayerLayer` mode this
    /// still steals the render slot, because that is all one player can do — so
    /// call sites can be written once against this API, and the A/B measures a
    /// real difference in behaviour rather than a difference in code paths.
    @discardableResult
    public func attachSurface(_ view: VideoRenderView, to mediaURL: URL) -> Bool {
        guard let player = activePlayer(playing: mediaURL) else {
            VideoPlaybackTrace.emit("attachSurface REFUSED \(mediaURL.lastPathComponent)")
            return false
        }
        VideoPlaybackTrace.emit("attachSurface \(mediaURL.lastPathComponent)")
        bind(player, to: view)
        return true
    }

    /// Makes `view` show the SAME playback `sibling` is currently showing —
    /// resolved by view IDENTITY, never by URL.
    ///
    /// URL lookup is ambiguous the moment two players exist for one asset
    /// (the cold-open warm-attach race minted a second), and
    /// `activePlayer(playing:)` then answers from dictionary order — a
    /// dismissal's card could prime from the TILE's playhead while the
    /// viewer watches the PAGE's, a visible jump at frame 0 of the return.
    /// The sibling is the surface the viewer is literally watching, so it is
    /// the one answer that cannot show the wrong frames. Passive exactly
    /// like `attachSurface(_:to:)`: the new surface holds no pool loan.
    /// Returns false when the sibling is bound to nothing.
    @discardableResult
    public func attachSurface(_ view: VideoRenderView, alongsideSurface sibling: VideoRenderView) -> Bool {
        if let player = activePlayers[ObjectIdentifier(sibling)] {
            bind(player, to: view)
            return true
        }
        // The sibling may itself be a JOINED surface with no loan — reach its
        // binding directly.
        return view.attachAlongside(sibling)
    }

    /// Releases a surface attached with `attachSurface`, leaving the playback
    /// and every other surface untouched.
    ///
    /// Not `stop(_:)`: that returns a pool loan and tears the player down.
    /// This surface never held one.
    public func detachSurface(_ view: VideoRenderView, reason: String = "detachSurface") {
        guard activePlayers[ObjectIdentifier(view)] == nil else { return }
        view.detach(reason: reason)
    }

    /// How many surfaces are currently showing `mediaURL`.
    ///
    /// The direct evidence that a flight is flying live media rather than
    /// handing it over: during a hero flight this reads 2 or 3, and at no point
    /// does it pass through 0. `nil` when nothing is playing that URL, which is
    /// distinct from "playing on no surfaces".
    public func surfaceCount(for mediaURL: URL) -> Int? {
        guard let player = activePlayer(playing: mediaURL) else { return nil }
        guard let renderer = renderers[ObjectIdentifier(player)] else {
            // Player-layer mode: exactly one layer can be rendering, whatever
            // else is attached. Reporting the truth of that mode rather than a
            // flattering count is the point of measuring it.
            return 1
        }
        return renderer.surfaceCount
    }

    /// Moves the pool loan for `mediaURL` to `view`, leaving every attached
    /// surface exactly as it is.
    ///
    /// The dismissal's missing piece, and the reason `attachSurface` alone is
    /// not enough. A joined surface holds no loan, so when the feed page that
    /// owns the player is torn down, `stop` returns that player to the pool and
    /// every surface joined to it — including the grid tile the flight just
    /// landed on — goes dark. Ownership has to move before the owner dies.
    ///
    /// **This touches no layer.** It is the bookkeeping half of what
    /// `park`/`unpark` did, with the rendering half deleted, because under
    /// N-surface rendering was never what needed to move. `view` is also
    /// attached as a surface if it is not one already, which is a no-op when
    /// the caller has already joined it.
    @discardableResult
    public func transferOwnership(of mediaURL: URL, to view: VideoRenderView) -> Bool {
        guard let player = activePlayer(playing: mediaURL) else {
            VideoPlaybackTrace.emit("transferOwnership REFUSED \(mediaURL.lastPathComponent)")
            return false
        }
        VideoPlaybackTrace.emit("transferOwnership \(mediaURL.lastPathComponent)")
        if let previous = playingURL.first(where: { $0.value == mediaURL })?.key,
           previous != ObjectIdentifier(view) {
            // Clear the old owner's registration WITHOUT `detach` — detaching
            // pauses the player and hands it back to the pool, which is exactly
            // the teardown this exists to get ahead of.
            activePlayers[previous] = nil
            playingURL[previous] = nil
        }
        // Claimed from the park — but only when the park holds THIS asset.
        // Clearing unconditionally orphaned a parked player of a DIFFERENT
        // URL: never paused, never re-pooled, decoding forever with nothing on
        // screen. A mismatched park stays put for its own claimant, or for the
        // next discard sweep.
        if parked?.url == mediaURL { parked = nil }
        let key = ObjectIdentifier(view)
        // Supersede any in-flight resolution for this view, so a late `play`
        // cannot attach a second item over the one just adopted.
        generation[key] = (generation[key] ?? 0) + 1
        activePlayers[key] = player
        playingURL[key] = mediaURL
        bind(player, to: view)
        player.play()
        return true
    }

    /// Re-caps the item playing `mediaURL`, wherever it is bound.
    ///
    /// The URL-keyed twin of `setPeakBitRate(_:in:)`, and necessary for the
    /// same reason `attachSurface` is: a surface that joined an existing
    /// playback holds no pool loan, so it cannot be looked up by view. Without
    /// this a full-screen page that joins a grid tile's player inherits the
    /// tile's rung — `tileBitRateCap`, sized for a thumbnail — and stays there.
    public func setPeakBitRate(_ peakBitRate: Double, for mediaURL: URL) {
        activePlayer(playing: mediaURL)?.currentItem?.preferredPeakBitRate = peakBitRate
    }

    /// A player bound to some surface and playing `mediaURL`. Deliberately
    /// blind to the parked slot: parking is the handoff's own mechanism and has
    /// its own branch in `play`, which un-parks rather than sharing.
    private func sharedActivePlayer(playing mediaURL: URL) -> AVPlayer? {
        guard let key = playingURL.first(where: { $0.value == mediaURL })?.key else { return nil }
        return activePlayers[key]
    }

    private func activePlayer(playing mediaURL: URL) -> AVPlayer? {
        if let key = playingURL.first(where: { $0.value == mediaURL })?.key,
           let player = activePlayers[key] {
            return player
        }
        // A parked player is still running and still the thing showing this
        // asset; a dismissal attaches its landing surface while the page that
        // owned it has already let go.
        if let parked, parked.url == mediaURL { return parked.player }
        return nil
    }

    /// Warms the source (synthesis/cache) for an upcoming page so its `play` is
    /// instant. No player is loaned.
    public func preroll(_ mediaURL: URL) {
        let source = source
        Task { _ = try? await source.playableURL(for: mediaURL) }
    }

    // MARK: - Internals

    /// The renderer for `player`, minted on first use. `nil` when
    /// `-avsbdl-render` is off, which is what keeps every call site below a
    /// single line that does the right thing in both modes.
    private func renderer(for player: AVPlayer) -> VideoFrameRenderer? {
        guard VideoRenderFlags.usesSampleBufferLayer else { return nil }
        let key = ObjectIdentifier(player)
        if let existing = renderers[key] { return existing }
        let renderer = VideoFrameRenderer(player: player)
        renderers[key] = renderer
        return renderer
    }

    /// Makes `view` display `player`: a layer binding in player-layer mode, a
    /// surface-set insertion in sample-buffer mode.
    private func bind(_ player: AVPlayer, to view: VideoRenderView) {
        view.attach(player, renderer: renderer(for: player))
    }

    private func detach(key: ObjectIdentifier, view: VideoRenderView) {
        view.detach(reason: "controller.stop")
        playingURL[key] = nil
        guard let player = activePlayers.removeValue(forKey: key) else { return }
        // ⚠️ STILL IN USE? Then this is one surface leaving, not the end of a
        // playback.
        let stillInUse = activePlayers.values.contains { $0 === player }
            || parked.map { $0.player === player } ?? false
        guard !stillInUse else { return }
        //
        // The loan became shareable the moment `play` started joining an active
        // player, and tearing it down here would pause the asset — and return it
        // to the idle pool — while another surface is still rendering it. That
        // is a frozen picture with no cause visible from the side that froze it.
        player.pause()
        removeLoop(for: player)
        player.replaceCurrentItem(with: nil)
        // The renderer stays in the map, keyed to this player, and is reused
        // when the player is loaned out again. Invalidating only drops its
        // output and its clock registration — an idle pooled player must not
        // keep the app-wide display link running.
        renderers[ObjectIdentifier(player)]?.invalidate()
        if idlePlayers.count < poolSize {
            idlePlayers.append(player)
        } else {
            // A player the pool has no room for is dropped — and its renderer
            // entry must go with it. The map's chain is strong (renderer →
            // frame source → player), so a surviving entry kept every
            // over-pool player, its video output and its renderer alive for
            // the life of the app; the map only ever grew.
            renderers.removeValue(forKey: ObjectIdentifier(player))
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
