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
    /// ⚠️ WHO EACH KEY ACTUALLY NAMES — held weakly, and the reason it exists
    /// is that `ObjectIdentifier` is an ADDRESS.
    ///
    /// Every table here is keyed by `ObjectIdentifier(view)` and none of them
    /// keeps the view alive. A surface deallocated without `stop` — a feed page
    /// torn down by a pop, a cell released mid-resolution — therefore leaves
    /// its entries behind, and the allocator is free to hand the same address
    /// to the NEXT render view. That view then inherits a stranger's player:
    /// `play` finds a binding that is already "correct" and starts nothing, the
    /// clip the viewer asked for never appears, and a flight that donates the
    /// surface carries the PREVIOUS clip. Reported exactly that way — "the new
    /// video's player disappeared, and the transition shows the old one".
    ///
    /// A weak box turns a stale key into a detectable one: `forgetDeadSurfaces`
    /// sweeps every entry whose view is gone, giving its player back properly
    /// instead of leaving it decoding for nobody.
    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]

    private struct WeakSurface {
        weak var view: VideoRenderView?
    }
    /// Bumped on every play/stop for a view so a slow `playableURL` resolution
    /// that lost the race is discarded instead of attaching to a recycled cell.
    ///
    /// Entries end with the binding (`detach` clears them) — the table used to
    /// keep one Int per surface ever played, because the dead-surface sweep
    /// only walks `surfaces` and a properly-stopped view was already gone from
    /// there. Tokens come from `generationCounter`, never per-key arithmetic:
    /// a cleared key restarts nothing, so a resolution from before the clear
    /// can never collide with a token minted after it.
    private var generation: [ObjectIdentifier: Int] = [:]
    private var generationCounter = 0
    private var loopObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Stall observers, keyed by PLAYER like the loop observers and removed
    /// with them. Diagnostic, armed by `-carousel-audit` and empty otherwise —
    /// which is exactly why the bookkeeping has to be tight: this used to be
    /// an append-only array whose closures held every `AVPlayerItem` ever
    /// played, so the diagnostic flag was itself the leak it was hunting.
    private var stallObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Where each paused player's picture was, so a resume can put it back.
    /// Keyed by PLAYER: two surfaces can share one, and they share its playhead.
    private var pausedAnchors: [ObjectIdentifier: CMTime] = [:]

    /// Where a clip had got to when its player was let go, so opening the same
    /// post again picks the picture up instead of starting it over.
    ///
    /// ⚠️ KEYED BY POST AND ASSET, never by asset alone — the identity rule this
    /// file states at length for `playingScope`. Two rows carrying the same file
    /// are two viewings with two positions, and one key for both would drag one
    /// viewer's place onto the other's screen.
    ///
    /// ⚠️ AND KEYED BY NEITHER PLAYER NOR SURFACE, which is why this is not
    /// `pausedAnchors`. That anchor lives exactly as long as one loan: `retire`
    /// deletes it precisely because the pool hands the same player to a
    /// different clip next. This has to OUTLIVE the loan — the whole event it
    /// remembers is the loan ending — so it hangs off the two things that are
    /// still true afterwards.
    private var resumeTimes: [ResumeKey: CMTime] = [:]
    /// Insertion order, so the memory can be capped without keeping every post
    /// a session ever played. Small on purpose: this is "the clip you were just
    /// watching", not a viewing history.
    private var resumeOrder: [ResumeKey] = []
    private static let resumeMemory = 32
    /// Below this, resuming is indistinguishable from starting and costs a seek
    /// on every cold start in the app.
    private static let minimumResumeSeconds = 0.5

    private struct ResumeKey: Hashable {
        let scope: String
        let url: URL
    }

    /// Files the playhead of a loan that is ending. Called from `detach`, and
    /// only where the playback itself is ending rather than one of several
    /// surfaces leaving it.
    private func rememberResume(scope: String?, url: URL?, player: AVPlayer) {
        guard let scope, let url, player.currentItem != nil else { return }
        rememberResume(scope: scope, url: url, at: player.currentTime())
    }

    /// The bookkeeping half, reachable without a player.
    ///
    /// Split out because the rules that can rot here — the scope is part of the
    /// key, a position is spent once, the memory is capped, a position too near
    /// the start is not worth keeping — are all about the ledger, and a test
    /// driving a real `AVPlayer` over a stub URL can only ever observe time
    /// zero. Asserting them through playback would assert nothing.
    func rememberResume(scope: String, url: URL, at time: CMTime) {
        guard time.isValid, time.seconds.isFinite,
              time.seconds > Self.minimumResumeSeconds else { return }
        let key = ResumeKey(scope: scope, url: url)
        if resumeTimes[key] == nil { resumeOrder.append(key) }
        resumeTimes[key] = time
        while resumeOrder.count > Self.resumeMemory {
            resumeTimes.removeValue(forKey: resumeOrder.removeFirst())
        }
        VideoPlaybackTrace.emit(String(
            format: "resume filed %@ scope=%@ at=%.2fs",
            url.lastPathComponent, scope, time.seconds
        ))
    }

    /// The playhead a fresh player for this post should start from, if any.
    /// Consumed, not read: a resume answers once, and a clip the viewer has
    /// since watched to the end must not be dragged back to a stale position by
    /// a later start.
    func takeResume(scope: String?, url: URL) -> CMTime? {
        guard let scope else { return nil }
        let key = ResumeKey(scope: scope, url: url)
        guard let time = resumeTimes.removeValue(forKey: key) else { return nil }
        resumeOrder.removeAll { $0 == key }
        VideoPlaybackTrace.emit(String(
            format: "resume applied %@ scope=%@ at=%.2fs",
            url.lastPathComponent, scope, time.seconds
        ))
        return time
    }
    /// Which POST each bound view is playing for.
    ///
    /// ⚠️ THE URL IS NOT AN IDENTITY, and treating it as one is a defect the
    /// fixtures made visible and production would have hit on any repost.
    ///
    /// "One asset, one player" was written for a real case: a card holds a clip
    /// paused on its page while the post opens the SAME clip, and minting a
    /// second player there gives one asset two decoders on two clocks. But the
    /// rule was applied by URL alone — so two DIFFERENT posts that happen to
    /// carry the same file also shared a player, and pausing one froze the
    /// other. Three mock posts share `trailer.mp4`, which is how it was found;
    /// two posts of the same reposted video would do it in production.
    ///
    /// Sharing is therefore scoped: same asset AND same post.
    private var playingScope: [ObjectIdentifier: String] = [:]

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
    /// - Parameter scope: which POST this playback belongs to. Two surfaces
    ///   may share one player only when the asset AND the scope match — see
    ///   `playingScope` for why the asset alone is not an identity. Passing nil
    ///   means "share with nobody", which is the safe answer for a caller that
    ///   does not know whose media this is.
    public func play(
        _ mediaURL: URL, in view: VideoRenderView,
        peakBitRate: Double = 0, scope: String? = nil
    ) async {
        // ⚠️ BEFORE THE KEY IS COMPUTED, because the key is an address and the
        // previous tenant of this one may still be on file. Swept here, the
        // bookkeeping below describes THIS view; swept later, it inherits.
        forgetDeadSurfaces()
        let key = ObjectIdentifier(view)
        let token = nextGenerationToken()
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
            surfaces[key] = WeakSurface(view: view)
            playingURL[key] = mediaURL
            playingScope[key] = scope
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
        if let shared = sharedActivePlayer(playing: mediaURL, scope: scope),
           shared !== activePlayers[key] {
            detach(key: key, view: view)
            shared.currentItem?.preferredPeakBitRate = peakBitRate
            bind(shared, to: view)
            activePlayers[key] = shared
            surfaces[key] = WeakSurface(view: view)
            playingURL[key] = mediaURL
            playingScope[key] = scope
            shared.play()
            return
        }

        // ⚠️ THE ONE STEP THAT COULD FAIL IN SILENCE.
        //
        // A resolution that throws returned from here with nothing bound, no
        // trace, and no way to tell the result apart from a player that simply
        // had not arrived yet. Four starts, zero frames and zero "attached but
        // frozen" reports pointed straight at it: the picture was never frozen,
        // it was never started.
        let resolved: URL
        do {
            resolved = try await source.playableURL(for: mediaURL)
        } catch {
            VideoPlaybackTrace.emit(
                "resolve FAILED \(mediaURL.lastPathComponent): \(error)"
            )
            return
        }
        let playableURL = resolved
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
        if let shared = sharedActivePlayer(playing: mediaURL, scope: scope), shared !== activePlayers[key] {
            detach(key: key, view: view)
            shared.currentItem?.preferredPeakBitRate = peakBitRate
            bind(shared, to: view)
            activePlayers[key] = shared
            surfaces[key] = WeakSurface(view: view)
            playingURL[key] = mediaURL
            playingScope[key] = scope
            shared.play()
            return
        }

        detach(key: key, view: view)
        let player = idlePlayers.popLast() ?? AVPlayer()
        let item = AVPlayerItem(url: playableURL)
        itemCreations += 1
        // Set BEFORE the item goes live, so the very first segment request
        // already asks for the capped rung — set afterwards, the player has
        // usually committed to a higher one and the cap only takes effect at
        // the next switch point.
        item.preferredPeakBitRate = peakBitRate
        installLoop(for: player, item: item)
        player.replaceCurrentItem(with: item)
        // ⚠️ AFTER the item is in and BEFORE `play`, so the first frame decoded
        // is the one the viewer left on rather than the clip's first.
        //
        // Only a COLD mint reaches here. The two branches above — adopting a
        // parked player and joining an active one — carry a live playhead
        // already, and seeking either would drag a picture the viewer is
        // currently watching.
        if let resume = takeResume(scope: scope, url: mediaURL) {
            // ⚠️ The completion handler is what picks the SYNCHRONOUS overload.
            // This runs inside an `async` function, where the bare call resolves
            // to `await player.seek(...)` — which would suspend this start until
            // the seek finished, between `replaceCurrentItem` and `play`.
            player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        renderer(for: player)?.setItem(item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        bind(player, to: view)
        activePlayers[key] = player
        surfaces[key] = WeakSurface(view: view)
        playingURL[key] = mediaURL
        playingScope[key] = scope
        player.play()
        VideoPlaybackTrace.emit("bound \(mediaURL.lastPathComponent) scope=\(scope ?? "-")")
    }

    /// Brings a clip to its first frame and stops there, so arriving at it
    /// later costs nothing.
    ///
    /// ⚠️ PLAY-THEN-PAUSE, deliberately, rather than a player left un-started.
    ///
    /// A player that has never run has not necessarily decoded anything: under
    /// the sample-buffer backing the frames come from a video output that only
    /// fills while playback is running, so a "prepared" player would still show
    /// the poster and the delay would simply move. Starting and stopping puts a
    /// real frame on the surface, which is the whole point — the picture is
    /// there before the viewer is.
    ///
    /// It advances a few frames doing so. That is invisible on a muted looping
    /// preview and is the honest price of having something to show.
    ///
    /// Every duplicate-avoiding rule in `play` applies unchanged: prewarming a
    /// clip another surface is already running joins that player rather than
    /// minting a second.
    public func prewarm(
        _ mediaURL: URL, in view: VideoRenderView,
        peakBitRate: Double = 0, scope: String? = nil
    ) async {
        await play(mediaURL, in: view, peakBitRate: peakBitRate, scope: scope)
        _ = setPaused(true, in: view)
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
        generation[key] = nextGenerationToken()
        activePlayers[key] = nil
        playingURL[key] = nil
        playingScope[key] = nil
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
        surfaces[key] = WeakSurface(view: view)
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
        // The same retirement `detach` runs — one implementation, so the two
        // routes to "this playback is over" cannot drift apart in what they
        // leave behind (they did: this copy of the wind-down predated the
        // pause-anchor purge and would have kept the anchor).
        retire(parked.player)
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
    /// ⚠️ DROPS EVERY KEY WHOSE SURFACE IS GONE, and gives its player back.
    ///
    /// Called before any lookup that could ALIAS — see `surfaces`. The window
    /// is not theoretical: a render view is deallocated with its cell, and
    /// nothing in this file is notified, so the only honest moment to notice is
    /// the next question somebody asks.
    ///
    /// The player is released exactly as `detach` would, minus the view calls a
    /// deallocated view cannot receive: paused, un-looped, and returned to the
    /// idle cache — unless another surface is still rendering it, which is the
    /// same "one leaving, not the end of a playback" rule.
    private func forgetDeadSurfaces() {
        let dead = surfaces.filter { $0.value.view == nil }.map(\.key)
        guard !dead.isEmpty else { return }
        for key in dead {
            VideoPlaybackTrace.emit(
                "forget dead surface \(playingURL[key]?.lastPathComponent ?? "-")"
            )
            surfaces[key] = nil
            generation[key] = nil
            playingURL[key] = nil
            playingScope[key] = nil
            guard let player = activePlayers.removeValue(forKey: key) else { continue }
            let stillInUse = activePlayers.values.contains { $0 === player }
                || parked.map { $0.player === player } ?? false
            guard !stillInUse else { continue }
            retire(player)
        }
    }

    public func stop(_ view: VideoRenderView) {
        forgetDeadSurfaces()
        let key = ObjectIdentifier(view)
        VideoPlaybackTrace.emit("stop \(playingURL[key]?.lastPathComponent ?? "-")")
        // No token bump: `detach` clears the entry outright, and a cleared key
        // fails the resolution guard just as hard as a newer token would.
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
    /// Whether `view`'s player is REALLY playing, as opposed to merely not
    /// paused.
    ///
    /// ⚠️ THE DISTINCTION `isAdvancing` CANNOT MAKE, and it cost a whole round
    /// of diagnosis. `timeControlStatus != .paused` is true for
    /// `.waitingToPlayAtSpecifiedRate` — a player that has been asked to play,
    /// has bound its item, and is stalled fetching data it may never get. From
    /// outside, that is indistinguishable from playing: attached, unpaused, and
    /// showing nothing. Which is exactly the state reported as "the player is
    /// attached but the image stays frozen".
    ///
    /// `isAdvancing` keeps its meaning because callers use it to read INTENT —
    /// did a pause take, did a resume take — and intent is what they need. This
    /// answers the other question, and diagnostics should ask this one.
    public func isPlayingForReal(in view: VideoRenderView) -> Bool {
        activePlayers[ObjectIdentifier(view)]?.timeControlStatus == .playing
    }

    public func isAdvancing(in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        return player.timeControlStatus != .paused
    }

    /// Whether `view` is already bound to a player for **this** asset.
    ///
    /// ⚠️ The question a caller must ask before starting something, or it throws
    /// away a decode it has already paid for. `play` on a surface that is
    /// already showing the URL replaces the item and begins again at zero — so
    /// arriving at a clip that was warmed for exactly this moment restarted it
    /// from the beginning, which is the opposite of the point.
    public func isBound(_ mediaURL: URL, in view: VideoRenderView) -> Bool {
        let key = ObjectIdentifier(view)
        return activePlayers[key] != nil && playingURL[key] == mediaURL
    }

    /// How many `AVPlayerItem`s this pool has created.
    ///
    /// The only honest way to see a restart from outside: a resumed clip keeps
    /// its item, a restarted one gets a new one, and nothing else about them
    /// differs from the caller's side.
    public private(set) var itemCreations = 0

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
        guard let player = watchedPlayer(in: view) else { return false }
        if paused {
            // ⚠️ WHERE THE PICTURE WAS, remembered — because an adaptive stream
            // does not necessarily come back to it.
            //
            // A progressive file resumes exactly where it stopped. An HLS one
            // re-anchors its timebase on resume and makes up the interval it was
            // stopped for: measured at 5x to 17.5x for seconds, with the clock
            // itself advancing 0.111s per 0.017s of real time. That is not the
            // display being wrong — playback really is somewhere else.
            pausedAnchors[ObjectIdentifier(player)] = player.currentTime()
            player.pause()
        } else {
            // ⚠️ Whatever is queued belongs to BEFORE the pause.
            //
            // The picture resumes at the playhead, and anything still waiting in
            // the layer was decoded for a moment that has passed. Shown, those
            // frames read as the video hurrying to catch up — the effect
            // reported on a long stream, where the gap can grow, and never on a
            // ten-second one, where it wraps. Dropped, the surface holds its
            // frozen frame for one dispatch and then shows the present.
            view.flushPendingSamples()
            // ⚠️ PINNED BACK to where it was, and only when it has drifted.
            //
            // The seek is exact on both sides — a tolerant one would let the
            // player choose a keyframe further on and reintroduce the jump it is
            // there to prevent. The threshold keeps it off the common path: a
            // progressive file returns within a frame of its anchor and is left
            // alone, so this costs nothing where nothing is wrong.
            let key = ObjectIdentifier(player)
            if let anchor = pausedAnchors.removeValue(forKey: key), anchor.isValid {
                let drift = (player.currentTime() - anchor).seconds
                // ⚠️ Reported on EVERY resume, not only when it acts.
                //
                // "The re-pin never fired" and "there was never any drift to
                // pin" are the same silence, and this session has spent four
                // runs mistaking one for the other. The number is printed so the
                // next run says which — and so a threshold that turns out to be
                // wrong is visibly wrong rather than quietly inert.
                VideoPlaybackTrace.emit(String(
                    format: "resume drift=%.3fs anchor=%.3fs", drift, anchor.seconds
                ))
                if drift.isFinite, abs(drift) > 0.15 {
                    player.seek(to: anchor, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            player.play()
        }
        return true
    }

    /// Where the clip `view` is drawing has got to, as a fraction of its
    /// length, with the length in seconds beside it.
    ///
    /// ⚠️ NIL IS AN ANSWER, and the caller must draw it as one. There is no
    /// playhead when there is no player, and none worth reporting while the
    /// length is unknown — a stream still resolving, or a live one that has no
    /// end at all. A bar that draws zero for those is a bar that says "at the
    /// beginning" when the truth is "not yet known", which is the reading a
    /// viewer will act on.
    ///
    /// Asked of the WATCHED player, so a page that joined a grid tile's clip
    /// answers about the picture in front of the viewer — see `watchedPlayer`.
    public func playhead(in view: VideoRenderView) -> (fraction: Double, seconds: Double)? {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return nil }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let time = item.currentTime().seconds
        guard time.isFinite else { return nil }
        return (min(max(time / duration, 0), 1), duration)
    }

    /// A still from the clip `view` is drawing, at `fraction` of its length —
    /// the picture a scrubber shows above the thumb.
    ///
    /// ⚠️ BEST EFFORT, AND NIL IS ORDINARY. Not every asset will give up a
    /// frame on demand: a stream may refuse outright, and one that obliges may
    /// take longer than the thumb waits. The caller draws nil as "no picture
    /// yet", never as an error — the time beside it is the part that always
    /// works.
    ///
    /// ⚠️ TOLERANT BY HALF A SECOND, for the reason the seek is: an exact frame
    /// means decoding forward from the nearest keyframe, and a scrubber asks
    /// again before that finishes. What the viewer is reading is roughly where
    /// they are, and the roughness is invisible at the size this is drawn.
    public func previewFrame(
        atFraction fraction: Double, in view: VideoRenderView, maximumWidth: CGFloat
    ) async -> CGImage? {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return nil }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let generator = frameGenerator(for: item.asset)
        generator.maximumSize = CGSize(width: maximumWidth * 2, height: 0)
        let seconds = duration * min(max(fraction, 0), 1)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // ⚠️ The callback form, not `image(at:)`. The async one would carry the
        // generator across an isolation boundary — it is not `Sendable`, and
        // the compiler is right to refuse. Here the generator is only touched
        // where it lives and the frame comes back through the continuation,
        // which is the shape `VideoExporter.posterImage` already uses.
        return try? await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }
    }

    /// One generator per asset, kept for the length of a scrub rather than
    /// built per frame: a generator carries the reader it has already opened,
    /// and building one per request pays for that open thirty times a second.
    private func frameGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let key = ObjectIdentifier(asset)
        if let existing = frameGenerators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // Bounded: a post's clips are few, and an entry costs a reader.
        if frameGenerators.count >= 4 {
            frameGenerators.removeAll()
        }
        frameGenerators[key] = generator
        return generator
    }

    private var frameGenerators: [ObjectIdentifier: AVAssetImageGenerator] = [:]

    /// Moves the playhead of the clip `view` is drawing.
    ///
    /// ⚠️ TOLERANT, not exact. A finger on a scrubber asks for a new position
    /// thirty times a second and every exact seek is a decode from the nearest
    /// keyframe forward: asked exactly, the picture falls behind the thumb and
    /// then catches up in lurches. A quarter-second either way is inside what
    /// the eye reads as "there", and it lets the player answer from frames it
    /// already has.
    public func seek(toFraction fraction: Double, in view: VideoRenderView) {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let seconds = duration * min(max(fraction, 0), 1)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        )
    }

    /// Toggles play/pause for the player bound to `view` (a user tapping the
    /// full-screen cell). Returns the new paused state. No-op returning `false`
    /// when no player is active for the view (e.g. an image/text cell).
    @discardableResult
    public func togglePlayback(in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
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
        forgetDeadSurfaces()
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
        // ⚠️ THE SCOPE MOVES WITH THE LOAN, and for a long time it did not.
        //
        // This function moved `activePlayers`, `playingURL` and `surfaces` and
        // left `playingScope` where it was — so the surface that ended a
        // dismissal owning the asset owned it under NO post identity, while the
        // key that had handed it over kept a scope entry naming a loan it no
        // longer held. Two consequences, both silent: the next present's
        // scope-gated join (`sharedActivePlayer(playing:scope:)`) cannot match,
        // so it mints beside a player already running the asset — the very
        // "one asset, two clocks" this file is built to prevent — and the
        // playhead ledger, which is keyed by the post, has nothing to file
        // under when that loan ends.
        let previousScope = playingURL.first(where: { $0.value == mediaURL })
            .flatMap { playingScope[$0.key] }
        if let previous = playingURL.first(where: { $0.value == mediaURL })?.key,
           previous != ObjectIdentifier(view) {
            // Clear the old owner's registration WITHOUT `detach` — detaching
            // pauses the player and hands it back to the pool, which is exactly
            // the teardown this exists to get ahead of.
            activePlayers[previous] = nil
            playingURL[previous] = nil
            playingScope[previous] = nil
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
        generation[key] = nextGenerationToken()
        activePlayers[key] = player
        surfaces[key] = WeakSurface(view: view)
        playingURL[key] = mediaURL
        // Kept if the new owner already had one — a caller that joined before
        // taking ownership knows its own post — and inherited otherwise.
        playingScope[key] = playingScope[key] ?? previousScope
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
    /// A player already running this asset FOR THIS POST, if any.
    ///
    /// ⚠️ Both halves, and the scope is the half that was missing. Matching on
    /// the asset alone made two different posts carrying the same file share one
    /// player and one clock: pausing either froze both, with the other left
    /// attached and still — which is exactly how it was reported.
    ///
    /// ⚠️ NIL IS A SCOPE, not an absence of one — two unscoped requests for the
    /// same asset are the same media as far as anyone here can tell, and they
    /// share. Refusing to share on nil was tried and broke the rule this exists
    /// to keep: every caller that does not distinguish posts would get its own
    /// decoder for an asset already playing.
    private func sharedActivePlayer(playing mediaURL: URL, scope: String?) -> AVPlayer? {
        let key = playingURL.first {
            $0.value == mediaURL && playingScope[$0.key] == scope
        }?.key
        guard let key else { return nil }
        return activePlayers[key]
    }

    /// The player `view` is DRAWING — its own loan first, and failing that the
    /// playback it joined.
    ///
    /// ⚠️ The pool answers two different questions about a surface, and this is
    /// the viewer's one. `hasPlayer(in:)` is the other: who holds the loan,
    /// whose `stop` retires the player, who the pool will bill. Ownership is
    /// the right basis for lifetime decisions and the wrong one for "pause what
    /// I am looking at" — a page that joined a grid tile's clip (every hero
    /// landing) owns nothing, and asking the loan table about it answered
    /// "nothing is playing here" while the viewer watched it move. The controls
    /// returned false and did nothing, which is a defect with no error in it:
    /// reported as the post screen's tap-to-pause being dead.
    ///
    /// Reads the binding off the SURFACE (`boundPlayer`) rather than looking a
    /// URL up in the pool, because two surfaces can carry the same asset and
    /// only the one in front of the viewer may be stopped.
    private func watchedPlayer(in view: VideoRenderView) -> AVPlayer? {
        activePlayers[ObjectIdentifier(view)] ?? view.boundPlayer
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
        // Read BEFORE the ledger is cleared: these two are what the playhead is
        // filed under, and three lines down they are gone.
        let leavingURL = playingURL[key]
        let leavingScope = playingScope[key]
        surfaces[key] = nil
        playingURL[key] = nil
        playingScope[key] = nil
        // The whole ledger ends here, generation included: a cleared key fails
        // the resolution guard (nil matches no token), and tokens are globally
        // unique so the next tenant of this address cannot collide with a
        // resolution from before the clear.
        generation[key] = nil
        guard let player = activePlayers.removeValue(forKey: key) else { return }
        // ⚠️ STILL IN USE? Then this is one surface leaving, not the end of a
        // playback.
        let stillInUse = activePlayers.values.contains { $0 === player }
            || parked.map { $0.player === player } ?? false
        guard !stillInUse else { return }
        // ⚠️ THE ONE MOMENT THE PLAYHEAD IS STILL KNOWN. One line down `retire`
        // replaces the item with nil and the position is gone for good — which
        // is why every re-open of a post started its clip again from zero. The
        // pool is doing exactly what it is for; nothing was writing down what it
        // was about to discard.
        rememberResume(scope: leavingScope, url: leavingURL, player: player)
        //
        // The loan became shareable the moment `play` started joining an active
        // player, and tearing it down here would pause the asset — and return it
        // to the idle pool — while another surface is still rendering it. That
        // is a frozen picture with no cause visible from the side that froze it.
        retire(player)
    }

    /// Winds a player down and returns it to the idle cache. The tail of
    /// `detach`, shared with `forgetDeadSurfaces` — which reaches the same
    /// state by a different route and must leave the pool in the same one.
    private func retire(_ player: AVPlayer) {
        player.pause()
        removeLoop(for: player)
        // The anchor dies with the loan. It is keyed by the PLAYER, and the
        // pool reuses players — one left behind here belongs to a clip that no
        // longer exists, and the reused player's first resume would compare a
        // fresh playhead against it and seek the NEW clip to wherever the OLD
        // one was paused.
        pausedAnchors.removeValue(forKey: ObjectIdentifier(player))
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

    /// Records the one thing that can move a playhead without anyone asking.
    ///
    /// ⚠️ THE OBJECTION THAT REDIRECTED THIS: a pause cannot make a video run
    /// fast. Whatever is happening is not pause-then-resume, so the remaining
    /// candidate is playback that ran out of data and jumped when it came back
    /// — which is also the only mechanism that would explain the effect showing
    /// on a long remote HLS stream and never on a short one.
    ///
    /// A stall next to a `fast` dispatch in the log is that story confirmed. A
    /// `fast` dispatch with no stall anywhere near it kills it, and the cause is
    /// ours after all. The instrument is what makes those two distinguishable
    /// instead of arguable.
    private func observeStalls(for item: AVPlayerItem, player: AVPlayer) {
        guard VideoPlaybackTrace.isEnabled else { return }
        // Keyed by player and removed with the loop observer: the diagnostic
        // must not outlive what it diagnoses. `item` is weak for the same
        // reason — the old strong capture kept every item ever played alive
        // for as long as its entry did, which used to be forever.
        stallObservers[ObjectIdentifier(player)] = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main
        ) { [weak item] _ in
            MainActor.assumeIsolated {
                VideoPlaybackTrace.emit(
                    String(format: "STALLED at=%.3fs", item?.currentTime().seconds ?? -1)
                )
            }
        }
    }

    private func installLoop(for player: AVPlayer, item: AVPlayerItem) {
        removeLoop(for: player)
        observeStalls(for: item, player: player)
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
        if let observer = stallObservers.removeValue(forKey: ObjectIdentifier(player)) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Globally unique play/stop tokens. Never per-key arithmetic: a key that
    /// was cleared and re-populated would restart a per-key count at 1, and a
    /// resolution still in flight from an earlier tenant of the same address
    /// could then match it and bind stale content over a fresh request.
    private func nextGenerationToken() -> Int {
        generationCounter += 1
        return generationCounter
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

    /// Census of the tables that must not outlive what they describe. Public
    /// because the hero-transition audit reads them from the app target; each
    /// is a leak the moment it exceeds the live state it mirrors.
    public var debugPausedAnchorCount: Int { pausedAnchors.count }
    public var debugStallObserverCount: Int { stallObservers.count }
    public var debugGenerationEntryCount: Int { generation.count }
    public var debugIdlePlayerCount: Int { idlePlayers.count }

    func activePlayer(in view: VideoRenderView) -> AVPlayer? { activePlayers[ObjectIdentifier(view)] }
    func peakBitRate(in view: VideoRenderView) -> Double? {
        activePlayers[ObjectIdentifier(view)]?.currentItem?.preferredPeakBitRate
    }
    func currentItem(in view: VideoRenderView) -> AVPlayerItem? {
        activePlayers[ObjectIdentifier(view)]?.currentItem
    }
    #endif
}
