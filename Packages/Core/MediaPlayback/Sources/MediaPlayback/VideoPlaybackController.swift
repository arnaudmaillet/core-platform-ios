import AVFoundation
import CacheKit
import CoreMedia
import Foundation
import UIKit

/// Where a loaded arrangement begins, and what it loops.
public struct VideoLoadLanding: Sendable, Equatable {
    /// The played second the new item begins at.
    public var seconds: Double
    /// The stretch of played seconds to loop, or nil for the whole item.
    public var loop: ClosedRange<Double>?

    public init(seconds: Double, loop: ClosedRange<Double>? = nil) {
        self.seconds = seconds
        self.loop = loop
    }
}

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
    let source: any VideoSource
    private var poolSize: Int
    var idlePlayers: [AVPlayer] = []
    /// Player currently bound to each render view.
    var activePlayers: [ObjectIdentifier: AVPlayer] = [:]
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
    var surfaces: [ObjectIdentifier: WeakSurface] = [:]

    struct WeakSurface {
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
    var generation: [ObjectIdentifier: Int] = [:]
    private var generationCounter = 0
    private var loopObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Stall observers, keyed by PLAYER like the loop observers and removed
    /// with them. Diagnostic, armed by `-carousel-audit` and empty otherwise —
    /// which is exactly why the bookkeeping has to be tight: this used to be
    /// an append-only array whose closures held every `AVPlayerItem` ever
    /// played, so the diagnostic flag was itself the leak it was hunting.
    var stallObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Where each paused player's picture was, so a resume can put it back.
    /// Keyed by PLAYER: two surfaces can share one, and they share its playhead.
    var pausedAnchors: [ObjectIdentifier: CMTime] = [:]

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
    var resumeTimes: [ResumeKey: CMTime] = [:]
    /// Insertion order, so the memory can be capped without keeping every post
    /// a session ever played. Small on purpose: this is "the clip you were just
    /// watching", not a viewing history.
    private var resumeOrder: [ResumeKey] = []
    private static let resumeMemory = 32
    /// Below this, resuming is indistinguishable from starting and costs a seek
    /// on every cold start in the app.
    private static let minimumResumeSeconds = 0.5

    struct ResumeKey: Hashable {
        let scope: String
        let url: URL
    }

    /// Files the playhead of a loan that is ending. Called from `detach`, and
    /// only where the playback itself is ending rather than one of several
    /// surfaces leaving it.
    func rememberResume(scope: String?, url: URL?, player: AVPlayer) {
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

    /// The next fresh player for `url` under `scope` starts at `seconds`
    /// instead of the beginning — the hero flight's picture was showing that
    /// moment of the clip (#625). Spent by that start, like a resume.
    ///
    /// ⚠️ NOTHING WHEN THAT POST'S CLIP IS ALREADY RUNNING. The next `play`
    /// then JOINS that player instead of minting one, so a start filed here
    /// would never be spent — and the post's next cold start, opened from
    /// anywhere, would seek to it. A map marker warms its page's player at
    /// touch-down (#646); the page asks again at take-off and must not leave
    /// that second answer lying in the ledger.
    public func prepareStart(of url: URL, scope: String, at seconds: TimeInterval) {
        guard sharedActivePlayer(playing: url, scope: scope) == nil else { return }
        rememberResume(scope: scope, url: url, at: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Drops whatever start position is filed for `url` under `scope` — a
    /// prepared start that was never spent, or the position a stop filed for
    /// a clip nobody watched (#646).
    public func forgetStart(of url: URL, scope: String) {
        _ = takeResume(scope: scope, url: url)
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
    var playingScope: [ObjectIdentifier: String] = [:]

    /// The media URL each bound view is playing, so a parked player can be
    /// matched back to the same asset.
    var playingURL: [ObjectIdentifier: URL] = [:]

    /// The surfaces their owner paused (`setPaused(true)`).
    var pausedSurfaces: Set<ObjectIdentifier> = []

    /// The paused surfaces holding a still while the player they share plays
    /// for another surface (`holdStill`).
    ///
    /// ⚠️ A PAUSE STILL STOPS THE SHARED CLOCK. One asset, one player: a
    /// post's card and its page share one, and a viewer's pause must stop
    /// both — the card behind the page included, sound and all. Only when
    /// ANOTHER surface then plays that player do the paused ones stop showing
    /// it (#1914, the owner's device, 2026-10-31: the post behind a profile,
    /// paused at a fifth of the screen, played in step with the profile's
    /// tile of the same post).
    var stilledSurfaces: Set<ObjectIdentifier> = []

    /// The player each still was taken from, so the surface can take it back
    /// — a surface that only JOINED a playback has no loan to find it by.
    var stilledPlayers: [ObjectIdentifier: WeakPlayer] = [:]

    struct WeakPlayer {
        weak var player: AVPlayer?
    }

    /// Every surface this pool has bound to a player, owners and joined ones
    /// alike, held weakly: which surfaces share a player, whatever backs them.
    ///
    /// ⚠️ NOT THE RENDERER'S LIST: under `-avplayer-render` there is no
    /// renderer, and a surface that only joined a player was found by
    /// nothing — the legacy lane's `aJoinedSurfaceHoldsAStillToo` (#1960).
    let boundSurfaces = NSHashTable<VideoRenderView>.weakObjects()
    /// A player detached from its view but still running, waiting for the next
    /// `play` of the same URL to adopt it. See `parkPlayback(from:)`.
    var parked: (url: URL, player: AVPlayer)?
    /// The frame renderer for each pooled player, under `-avsbdl-render`.
    ///
    /// Keyed by **player**, not by view, and that is the whole idea: the
    /// renderer owns the player's video output, so it travels with the player
    /// through park → adopt and survives being handed between surfaces. A view
    /// joining or leaving its surface set is bookkeeping that draws nothing.
    /// Empty when the flag is off.
    var renderers: [ObjectIdentifier: VideoFrameRenderer] = [:]
    /// What each player's arrangement laid for its sound, and which players
    /// are being heard — kept for `VideoPlaybackController+Sound.swift`, keyed by
    /// PLAYER and emptied by `retire` like every other per-player table here.
    var soundBindings: [ObjectIdentifier: SoundBinding] = [:]
    var audiblePlayers: Set<ObjectIdentifier> = []
    /// The heard clip's level (`setAudibleVolume`, #1914).
    var audibleVolume: Float = 1
    /// The feed's sound (#1931): turned on by a volume key, it keeps the
    /// session `.playback`. The app's one session; tests pass their own.
    public var feedSound: FeedSoundSession = .shared {
        didSet { settleAudioSession() }
    }
    private var feedSoundObservers: [NSObjectProtocol] = []
    /// The one surface a viewer is listening to, and the player last made
    /// heard for it — see `setAudibleSurface`.
    weak var audibleSurface: VideoRenderView?
    weak var surfaceHeardPlayer: AVPlayer?
    /// Background Play (#483): the surface, and its player, kept playing
    /// while the app is off screen. See `continueInBackground`.
    weak var backgroundSurface: VideoRenderView?
    weak var backgroundPlayer: AVPlayer?
    /// Picture in Picture (#483): the clip readied for the floating window,
    /// and who hears it open and close. See `armPictureInPicture`.
    var pictureInPicture: PictureInPictureSession?
    var pictureInPictureObserver: ((Bool) -> Void)?

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
    public private(set) var capacity: Int

    /// Resizes the pool live (Settings' player pool, #702): the working-set
    /// budget and the idle cache both follow `size`, and idle players past the
    /// new cache are dropped now — with their renderers, as `recycle` drops an
    /// over-pool player. Players bound to surfaces are never taken away: the
    /// budget is what claimants size themselves against next.
    public func resize(to size: Int) {
        let size = max(1, size)
        capacity = size
        poolSize = size
        while idlePlayers.count > poolSize {
            let dropped = idlePlayers.removeLast()
            renderers.removeValue(forKey: ObjectIdentifier(dropped))
        }
    }

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
    ///
    /// - Parameter byteCache: the device cache's video bytes (#895). With
    ///   one, every progressive HTTP(S) file a player opens reads through it
    ///   (`VideoByteCache.asset(for:priority:)`), and `makeLookahead` can plan
    ///   the vertical feed's preload. Without one (tests, the upload preview),
    ///   players open the URL directly, as before.
    public init(source: any VideoSource, poolSize: Int = 6, capacity: Int = 6, byteCache: VideoByteCache? = nil) {
        self.source = source
        self.poolSize = poolSize
        self.capacity = capacity
        self.byteCache = byteCache
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback)
        // A volume key turned the feed's sound on (#1931) — heard through the
        // silent switch once the key's ringer read says silent (#2185) — until
        // the phone is put on silent again.
        feedSoundObservers = [
            FeedSoundSession.didTurnOn, FeedSoundSession.didNeedPlayThrough, FeedSoundSession.didTurnOff,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // The sender's identity, read here: a `Notification` cannot
                // cross into the main actor's isolation.
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, sender == ObjectIdentifier(self.feedSound) else { return }
                    self.settleAudioSession()
                }
            }
        }
        // Return players are a convenience the close can do without (#923):
        // under memory pressure they go first, and the close lands on a still.
        // Lookahead players (#895) are speculative too, and go with them.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseAllReturnPlaybacks()
                self?.releaseAllLookaheadPlaybacks()
            }
        }
    }

    /// The device cache's video bytes, when the app gave the pool one.
    public let byteCache: VideoByteCache?

    /// The item for a resolved URL: read through the byte cache when there is
    /// one and the file is cacheable, straight from the URL otherwise.
    func makeItem(
        for playableURL: URL, priority: CacheFillPriority, content: VideoByteCache.Content = .clip
    ) -> AVPlayerItem {
        guard let byteCache, VideoByteCache.isCacheable(playableURL) else { return AVPlayerItem(url: playableURL) }
        return AVPlayerItem(asset: byteCache.asset(for: playableURL, priority: priority, content: content))
    }

    /// An item for a song or a sound preview (#895): a progressive file over
    /// HTTP(S), MP3, M4A or a clip played for its sound, reads through the
    /// byte cache as a clip does (same chunks, same tiers, pinned while it
    /// plays), so a sound heard twice is fetched once. A local file, or a pool
    /// with no cache, opens the URL directly.
    ///
    /// Its bytes go to the sound namespaces, counted and cleared as Music &
    /// Sounds in Settings → Storage (#1068), except for a file the clip
    /// namespaces already hold: a post's original sound IS its clip
    /// (`SnapSoundState.sound(for:)`), and a preview of it reads
    /// the chunks the clip's playback already wrote instead of a second copy.
    public func soundItem(for url: URL) -> AVPlayerItem {
        makeItem(for: url, priority: .visible, content: .sound)
    }

    /// Never removed: the block holds this pool weakly, and a pool lives as
    /// long as the app.
    private var memoryWarningObserver: NSObjectProtocol?

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
        let requested = CACurrentMediaTime()
        // Asked to play: no longer paused, and a still it held gives way to
        // whichever player binds it below (#1914).
        pausedSurfaces.remove(key)
        stilledPlayers[key] = nil
        let wasStilled = stilledSurfaces.remove(key) != nil
        if wasStilled { view.releaseStill() }

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

        // ⚠️ ALREADY ON THIS CLIP: CARRY ON. "Safe to call repeatedly" was
        // true only while a start awaited its resolution — a second call
        // bumped the token and the first dropped out. A JOIN completes with no
        // await, so a second call found this view's player as "shared", fell
        // through and minted a fresh one at zero over it. A post page starts
        // from two doors two milliseconds apart (viewport, activation), and a
        // map marker's touch-down warm (#646) makes its page's start a join:
        // filmed as `JOIN`, then `STOP` + `MINT start=0` 3 ms later, the warm
        // and the flight's start position both thrown away. A view bound to a
        // live player on this clip and post is playing what was asked.
        if let current = activePlayers[key], playingURL[key] == mediaURL, playingScope[key] == scope,
           current.currentItem.map({ $0.status != .failed }) ?? false {
            if wasStilled { bind(current, to: view) }
            current.currentItem?.preferredPeakBitRate = peakBitRate
            current.play()
            stillPausedSurfaces(sharing: current, besides: key)
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
        if let shared = sharedActivePlayer(playing: mediaURL, scope: scope),
           shared !== activePlayers[key] {
            detach(key: key, view: view)
            shared.currentItem?.preferredPeakBitRate = peakBitRate
            bind(shared, to: view)
            activePlayers[key] = shared
            surfaces[key] = WeakSurface(view: view)
            playingURL[key] = mediaURL
            playingScope[key] = scope
            VideoProducerLog.emit("JOIN \(VideoProducerLog.name(shared)) owner+=\(view.debugProducerName) \(mediaURL.lastPathComponent)")
            playsForAnotherSurface(shared)
            shared.play()
            stillPausedSurfaces(sharing: shared, besides: key)
            return
        }

        // A player the vertical feed's lookahead kept for this clip and post
        // (#895) — the next page warmed, or the page just left — is adopted
        // whole, as a parked one is: no resolution, no await, a frame ready.
        if let scope, let entry = takeLookaheadPlayback(of: mediaURL, scope: scope) {
            adoptLookahead(entry, in: view, key: key, url: mediaURL, scope: scope, peakBitRate: peakBitRate)
            measureFirstFrame(of: entry.player, in: view, since: requested)
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
            VideoProducerLog.emit("JOIN \(VideoProducerLog.name(shared)) owner+=\(view.debugProducerName) \(mediaURL.lastPathComponent)")
            playsForAnotherSurface(shared)
            shared.play()
            stillPausedSurfaces(sharing: shared, besides: key)
            return
        }

        let item = makeItem(for: playableURL, priority: .visible)
        // Set BEFORE the item goes live, so the very first segment request
        // already asks for the capped rung — set afterwards, the player has
        // usually committed to a higher one and the cap only takes effect at
        // the next switch point.
        item.preferredPeakBitRate = peakBitRate
        // ⚠️ AFTER the item is in and BEFORE `play`, so the first frame decoded
        // is the one the viewer left on rather than the clip's first.
        //
        // Only a COLD mint reaches here. The two branches above — adopting a
        // parked player and joining an active one — carry a live playhead
        // already, and seeking either would drag a picture the viewer is
        // currently watching.
        bindFresh(
            item, in: view, key: key, url: mediaURL, scope: scope,
            startingAt: takeResume(scope: scope, url: mediaURL)
        )
        VideoPlaybackTrace.emit("bound \(mediaURL.lastPathComponent) scope=\(scope ?? "-")")
        if let player = activePlayers[key] { measureFirstFrame(of: player, in: view, since: requested) }
    }

    /// Times a player a `play` minted or adopted to its first frame on `view`,
    /// for the coordinator's prefetch counters (#900, `-cache-audit`). Only
    /// with a byte cache; gives up after 10 s, or once the view holds another
    /// player.
    private func measureFirstFrame(of player: AVPlayer, in view: VideoRenderView, since start: CFTimeInterval) {
        guard let byteCache else { return }
        let key = ObjectIdentifier(view)
        Task { @MainActor [weak self, weak view, weak player] in
            for _ in 0..<Self.firstFramePolls {
                guard let self, let view, let player, activePlayers[key] === player else { return }
                if view.isReadyForDisplay {
                    let elapsed = CACurrentMediaTime() - start
                    byteCache.recordTimeToFirstFrame(elapsed)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// 10 s at 50 ms.
    private static let firstFramePolls = 200

    /// Loans a player, gives it `item`, binds it to `view` and starts it — the
    /// tail every first start shares.
    ///
    /// ⚠️ **`url` IS NIL FOR AN ARRANGEMENT, AND THAT IS ITS IDENTITY RULE.** A
    /// player registered under a URL can be joined, parked and resumed by any
    /// surface asking for that URL; a player running an EDITED arrangement of
    /// the file is not that file, and must not be handed to a surface that asked
    /// for the file as shot.
    private func bindFresh(
        _ item: AVPlayerItem, in view: VideoRenderView, key: ObjectIdentifier,
        url: URL?, scope: String?, startingAt start: CMTime?, looping loop: Looping? = nil,
        composing composed: ComposedVideo? = nil
    ) {
        detach(key: key, view: view)
        let player = idlePlayers.popLast() ?? AVPlayer()
        itemCreations += 1
        installLoop(for: player, item: item)
        settle(loop, on: item, of: player)
        player.replaceCurrentItem(with: item)
        if let start {
            // ⚠️ The completion handler is what picks the SYNCHRONOUS overload.
            // This runs under an `async` caller, where the bare call resolves to
            // `await player.seek(...)` — which would suspend this start until
            // the seek finished, between `replaceCurrentItem` and `play`.
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        renderer(for: player)?.setItem(item, composing: composed)
        player.isMuted = true
        player.actionAtItemEnd = .none
        bind(player, to: view)
        activePlayers[key] = player
        surfaces[key] = WeakSurface(view: view)
        playingURL[key] = url
        playingScope[key] = scope
        VideoProducerLog.emit("MINT \(VideoProducerLog.name(player)) owner=\(view.debugProducerName) "
            + "\(url?.lastPathComponent ?? "arrangement") start=\(start.map { String(format: "%.2fs", $0.seconds) } ?? "0")")
        player.play()
    }

    /// Plays an ARRANGEMENT of a file in `view`: its pieces laid end to end in
    /// the order given, each at its own rate, as ONE item — the very composition
    /// `VideoExporter` builds.
    ///
    /// ⚠️ **ONE ITEM, SO A PIECE BOUNDARY IS AN EDIT AND NOT A SEEK.** The
    /// editor used to play the file and, at each piece's end, SEEK it to the
    /// next piece's start — which after a re-order is a jump across the file,
    /// asynchronous, decoded forward from a keyframe, and reported as *"une
    /// mini pause / glitch"* between the pieces. Inside one composition
    /// AVFoundation has the next piece ready before it is needed.
    ///
    /// ⚠️ **THE ITEM'S SECONDS ARE THE ARRANGEMENT'S PLAYED SECONDS.** Rates are
    /// built into the item, so the player itself always runs at 1 — a `setRate`
    /// on top would play a 2× piece at 4×.
    ///
    /// ⚠️ **ALREADY BOUND? THE ITEM IS SWAPPED IN PLACE.** No detach, no poster,
    /// no restart: the surface keeps its last frame until the new item draws,
    /// and a clip the author paused stays paused. An empty plan plays the file
    /// as shot, where played seconds and file seconds are the same thing.
    ///
    /// `start` is asked AFTER everything asynchronous has happened, on the main
    /// actor, just before the item goes in: where the new item should begin, or
    /// nil to abandon a load that the world has moved past.
    public func load(
        _ plan: VideoExportPlan, in view: VideoRenderView,
        at start: @MainActor () -> Double?
    ) async {
        await load(plan, in: view) { start().map { VideoLoadLanding(seconds: $0) } }
    }

    /// Plays an arrangement, as `load(_:in:at:)` does, landing where `landing`
    /// says — and, when it names one, looping a stretch of the arrangement's
    /// played seconds instead of the whole item.
    ///
    /// ⚠️ **THE RANGE IS ASKED WITH THE START, AFTER EVERYTHING ASYNCHRONOUS.**
    /// A range decided when the load was asked for may belong to a cut the
    /// author has since left.
    ///
    /// ⚠️ **AND A FILE NEVER TAKES ONE.** When the arrangement cannot be built
    /// the item is the file as shot, whose seconds are not the arrangement's: a
    /// range written on it would loop some other stretch of film.
    public func load(
        _ plan: VideoExportPlan, in view: VideoRenderView,
        landing: @MainActor () -> VideoLoadLanding?
    ) async {
        forgetDeadSurfaces()
        let key = ObjectIdentifier(view)
        let token = nextGenerationToken()
        generation[key] = token
        // ⚠️ A BOARD PER LOAD, SEEDED WITH THE PLAN'S LOOK — and reachable from
        // before the first suspension, so a look set while the load is on its
        // way reaches the item this load brings, not only the one it replaces.
        // ⚠️ THE LEGACY LAYER PATH GETS NONE — see below.
        let board = VideoRenderFlags.usesSampleBufferLayer ? VideoLiveLook(plan.finish.look) : nil
        loadingBoards[key] = board
        defer { if let board, loadingBoards[key] === board { loadingBoards[key] = nil } }
        let resolved: URL
        do {
            resolved = try await source.playableURL(for: plan.sourceURL)
        } catch {
            VideoPlaybackTrace.emit("load resolve FAILED \(plan.sourceURL.lastPathComponent): \(error)")
            return
        }
        guard generation[key] == token else { return }
        let asset = asShotAsset(resolved)
        if asShotOrientation?.url != resolved {
            // The handle's file-as-shot view needs the same turn, and nothing
            // else — never a finish or a board. Worked out once per file: a few
            // header reads the asset has already made.
            asShotOrientation = (
                resolved,
                try? await VideoExporter.arrangement(
                    of: asset, cut: [], orientation: .always, longestSide: Self.previewLongestSide
                ).composed
            )
            guard generation[key] == token else { return }
        }
        let item: AVPlayerItem
        let built: Bool
        var composed: ComposedVideo?
        var sound: VideoExporter.SoundtrackLayout?
        // ⚠️ ANY PIECE AT ALL IS A COMPOSITION HERE, UNLIKE THE EXPORT. One piece
        // at 1x is a `timeRange` to an export session, but a player's clock would
        // then read the FILE's seconds, and the item's seconds are promised to be
        // the arrangement's.
        // ⚠️ AND ALWAYS UPRIGHT. The sample-buffer path ignores a track's
        // transform, so a phone clip plays on its side unless a video composition
        // turns it — and a canvas that turned upright only while it carried a
        // transition would rotate under the author as they edited.
        // ⚠️ AND ALWAYS UNDER A LIVE BOARD ON THE SAMPLE-BUFFER PATH, which
        // composes even an untouched clip: the author's first filter must reach
        // the playing picture without a new item. The legacy layer path would
        // hand every such composition to its item, which fails on the iOS 27
        // simulator, so it takes no live look — a look reaches it with a load.
        // ⚠️ OVERLAYS ARE NOT DRAWN HERE: the editor shows them as views, and
        // drawing them into the picture as well would show each one twice.
        // ⚠️ AND ONE THAT CANNOT BE BUILT FALLS BACK TO THE FILE. Nothing bound at
        // all is worse than the clip as shot: the author loses the picture, not
        // just the edit.
        if let arranged = try? await VideoExporter.arrangement(
            of: asset, cut: plan.segments, orientation: .always,
            longestSide: Self.previewLongestSide, soundtrack: plan.soundtrack,
            finish: FrameFinish(crop: plan.finish.crop, look: plan.finish.look), live: board
        ) {
            item = AVPlayerItem(asset: arranged.asset)
            composed = present(arranged.composed, on: item)
            item.audioMix = arranged.audioMix
            sound = arranged.sound
            built = true
        } else {
            VideoPlaybackTrace.emit("load build FAILED \(plan.sourceURL.lastPathComponent)")
            item = AVPlayerItem(asset: asset)
            built = false
            if asShotOrientation?.url == resolved {
                composed = present(asShotOrientation?.composed, on: item)
            }
        }
        guard generation[key] == token else { return }
        // ⚠️ SPECTRAL, AS THE EXPORT IS: a sped-up piece keeps its voice's pitch,
        // and a scaled edit is governed by the item's algorithm even at 1x.
        item.audioTimePitchAlgorithm = .spectral
        guard let landed = landing(), generation[key] == token else { return }
        let range = built ? landed.loop.flatMap(Self.loopable) : nil
        let loops: Looping? = built ? range.map(Looping.range) ?? .wholeItem : nil
        var seconds = landed.seconds.isFinite ? max(landed.seconds, 0) : 0
        if let range, !range.contains(seconds) { seconds = range.lowerBound }
        let at = CMTime(seconds: seconds, preferredTimescale: 600)
        if let player = activePlayers[key] {
            swap(item, into: player, at: at, looping: loops, composing: composed)
        } else {
            bindFresh(
                item, in: view, key: key, url: nil, scope: nil, startingAt: at, looping: loops,
                composing: composed
            )
            player(in: view)?.defaultRate = 1
        }
        // ⚠️ AFTER THE ITEM IS IN: the binding names the item it describes.
        if let player = player(in: view) { adoptSound(sound, on: player) }
        VideoPlaybackTrace.emit(
            "loaded \(plan.sourceURL.lastPathComponent) pieces=\(plan.segments.count) at=\(seconds)"
                + (range.map { " loop=\($0.lowerBound)...\($0.upperBound)" } ?? "")
        )
    }

    private func player(in view: VideoRenderView) -> AVPlayer? {
        activePlayers[ObjectIdentifier(view)]
    }

    /// Replaces the item a bound player is running, keeping everything else.
    func swap(
        _ item: AVPlayerItem, into player: AVPlayer, at start: CMTime, looping loop: Looping? = nil,
        composing composed: ComposedVideo? = nil
    ) {
        let key = ObjectIdentifier(player)
        let wasPaused = player.timeControlStatus == .paused
        // ⚠️ A SEEK CHASED ON THE OLD ITEM BELONGS TO THE OLD CLOCK — dropped, as
        // `retire` drops it, or its completion would chase the new item to a
        // position measured on the old one.
        chased.removeValue(forKey: key)
        seeking.remove(key)
        item.preferredPeakBitRate = player.currentItem?.preferredPeakBitRate ?? 0
        itemCreations += 1
        installLoop(for: player, item: item)
        settle(loop, on: item, of: player)
        player.replaceCurrentItem(with: item)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        // ⚠️ AND A PAUSE ANCHOR MOVES TO THE NEW START, or the next resume would
        // pin the new item back to where the old one was stopped.
        if pausedAnchors[key] != nil { pausedAnchors[key] = start }
        // ⚠️ THE VIDEO OUTPUT IS PER ITEM: without this the renderer keeps
        // reading the item that has just gone, and the picture freezes.
        renderer(for: player)?.setItem(item, composing: composed)
        // ⚠️ THE RATE IS IN THE ITEM NOW. A player reused from a clip that was
        // told to run at 2x would otherwise play every arrangement twice over.
        player.defaultRate = 1
        if wasPaused {
            player.pause()
        } else {
            player.rate = 1
        }
    }

    /// What a player running an ARRANGEMENT loops.
    enum Looping: Equatable {
        /// The whole item, from its start.
        case wholeItem
        /// A stretch of the arrangement's played seconds.
        case range(ClosedRange<Double>)
    }

    /// ⚠️ **AN ENTRY ONLY WHILE THE PLAYER RUNS AN ARRANGEMENT.** Every change
    /// of item goes through `bindFresh`, `swap` or `retire`, and each of them
    /// writes this: no entry means a file, whose seconds are not an
    /// arrangement's, and a range written on it would loop some other film.
    var looping: [ObjectIdentifier: Looping] = [:]

    /// Records what `player` loops, and ends `item` where its range ends.
    func settle(_ loop: Looping?, on item: AVPlayerItem, of player: AVPlayer) {
        looping[ObjectIdentifier(player)] = loop
        if case .range(let range) = loop {
            item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        }
    }

    /// Where the player goes back to when its item ends.
    private func loopStart(of player: AVPlayer) -> CMTime {
        guard case .range(let range) = looping[ObjectIdentifier(player)] else { return .zero }
        return CMTime(seconds: range.lowerBound, preferredTimescale: 600)
    }

    /// The shortest stretch worth looping: a tenth of a second is three frames,
    /// and anything shorter would spend its time seeking.
    static let shortestLoop: Double = 0.1

    /// `range`, if a player can loop it.
    static func loopable(_ range: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
        let lower = max(range.lowerBound, 0)
        guard range.upperBound - lower >= shortestLoop else { return nil }
        return lower...range.upperBound
    }

    /// Loops `range` of the arrangement playing in `view` — the few seconds
    /// around a cut while its transition is being chosen — or, with `nil`, the
    /// whole item again.
    ///
    /// ⚠️ **`forwardPlaybackEndTime`, SO THE PLAYER ITSELF STOPS AT THE END.** A
    /// time observer that seeked back would see the playhead only after it had
    /// passed the end, and show film from past the range for a frame or more.
    /// The item posts its did-play-to-end at the forward end time, and the loop
    /// observer takes it back to the range's start.
    ///
    /// ⚠️ **A NEW RANGE GOES TO ITS START, EXACTLY, AND NEVER STARTS THE CLIP.**
    /// Whether it runs is the caller's to say; a paused clip is shown at the
    /// start of what it will loop.
    ///
    /// Returns whether the range was taken: false when nothing is bound, when
    /// the item is a file rather than an arrangement, or when the range is too
    /// short to loop.
    @discardableResult
    public func setLoopRange(_ range: ClosedRange<Double>?, in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return false }
        let key = ObjectIdentifier(player)
        guard looping[key] != nil else { return false }
        guard let range else {
            looping[key] = .wholeItem
            item.forwardPlaybackEndTime = .invalid
            return true
        }
        guard let loop = Self.loopable(range) else { return false }
        looping[key] = .range(loop)
        item.forwardPlaybackEndTime = CMTime(seconds: loop.upperBound, preferredTimescale: 600)
        seek(toSeconds: loop.lowerBound, in: view, toleranceSeconds: 0)
        return true
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

    // MARK: - Return playback — state here, behaviour in `VideoPlaybackController+ReturnPlayback.swift`
    /// The frame each park showed, oldest first, outliving its player.
    ///
    /// ⚠️ KEPT THROUGH EVICTION AND MEMORY PRESSURE, which are the very cases
    /// it exists for: a close whose player went (a stack deeper than
    /// `returnPlaybackCapacity`, a memory warning) shows this frame at once
    /// instead of the tile's thumbnail (`GridVideoPlaybackCoordinator`). A few
    /// tile-sized pictures, capped by `returnStillCapacity`. Dropped when a
    /// landing claims the player (the clip itself is drawing) or the same
    /// clip is parked again.
    var returnStills: [(key: ReturnKey, still: ReturnStill)] = []
    /// The park each frame capture belongs to: a capture that finishes after
    /// a claim or a newer park of the clip is dropped.
    var returnStillTokens: [ReturnKey: Int] = [:]
    /// Players parked for a CLOSE to come back to: the tile a post was opened
    /// from, paused on its own clip while the viewer is somewhere else (#923).
    ///
    /// ⚠️ NOT IN `activePlayers`, and that is the whole bound. Nothing that
    /// sizes itself against this pool (the grids' budgets, `capacity`, the
    /// sound sheet's count of other players) sees them, `play` never joins or
    /// adopts them, and no URL lookup can return one. They leave this ledger
    /// three ways: claimed by `transferOwnership` at a landing, released by
    /// their owner, or evicted (oldest first, beyond
    /// `returnPlaybackCapacity`, or all at once on a memory warning).
    var returnPlaybacks: [ReturnPlayback] = []
    /// One token per park still resolving, so a release (or a newer park of
    /// the same clip) that arrives first wins.
    var returnParkTokens: [ReturnKey: Int] = [:]

    // MARK: - Lookahead playback — state here, behaviour in `VideoPlaybackController+Lookahead.swift`
    /// Players kept ready for the vertical feed (#895): the next page's clip,
    /// warmed to its first frame with a few seconds read ahead, and the page
    /// just left, paused where the viewer left it.
    ///
    /// ⚠️ NOT IN `activePlayers`, like the return ledger and for its reasons:
    /// nothing that sizes itself against the pool sees them, `play` never
    /// JOINS one, and no URL lookup returns one. `play` ADOPTS one whole when
    /// it is asked for that clip under that post — the swipe the player was
    /// kept for. They leave this ledger by adoption, by `setLookahead` no
    /// longer wanting them, or all at once on a memory warning.
    var lookaheadPlaybacks: [LookaheadPlayback] = []
    /// The clips the lookahead wants now, next first.
    var lookaheadWanted: [ReturnKey] = []
    /// One token per warm-up still resolving.
    var lookaheadTokens: [ReturnKey: Int] = [:]
    /// The lookahead that set the ledger's wanted clips last.
    var lookaheadClient: ObjectIdentifier?
    /// The +1 a memory warning released; not warmed again while it is +1.
    var releasedNext: ReturnKey?
    /// How many `AVPlayerItem`s this pool has created.
    ///
    /// The only honest way to see a restart from outside: a resumed clip keeps
    /// its item, a restarted one gets a new one, and nothing else about them
    /// differs from the caller's side.
    public var itemCreations = 0
    /// The board of the load on its way to each view, while it is on its way.
    var loadingBoards: [ObjectIdentifier: VideoLiveLook] = [:]
    var frameGenerators: [ObjectIdentifier: AVAssetImageGenerator] = [:]
    var asShot: AVURLAsset?
    /// The video composition that turns the file as shot upright — `nil` when
    /// it is stored upright already — for the last file a load resolved.
    var asShotOrientation: (url: URL, composed: ComposedVideo?)?
    var chased: [ObjectIdentifier: Chase] = [:]
    var seeking: Set<ObjectIdentifier> = []
    var lastSeekTolerance: Double?
    var seeksLanded = 0
    var seeksCancelled = 0
    var settleWaiters: [ObjectIdentifier: [@MainActor () -> Void]] = [:]

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
    /// `attachSurface(_:to:)` for THIS post's player first (`scope`): a page
    /// joining the player of the post it shows, not whichever player happens
    /// to run the same file. Falls back to the asset alone.
    @discardableResult
    public func attachSurface(_ view: VideoRenderView, to mediaURL: URL, scope: String?) -> Bool {
        forgetDeadSurfaces()
        guard let player = sharedActivePlayer(playing: mediaURL, scope: scope)
                ?? activePlayer(playing: mediaURL) else {
            VideoPlaybackTrace.emit("attachSurface REFUSED \(mediaURL.lastPathComponent)")
            return false
        }
        VideoPlaybackTrace.emit("attachSurface \(mediaURL.lastPathComponent)")
        bind(player, to: view)
        return true
    }

    @discardableResult
    public func attachSurface(_ view: VideoRenderView, alongsideSurface sibling: VideoRenderView) -> Bool {
        if let player = activePlayers[ObjectIdentifier(sibling)] {
            bind(player, to: view)
            return true
        }
        // The sibling may itself be a JOINED surface with no loan — reach its
        // binding directly.
        guard view.attachAlongside(sibling) else { return false }
        pausedSurfaces.remove(ObjectIdentifier(view))
        boundSurfaces.add(view)
        return true
    }

    /// Releases a surface attached with `attachSurface`, leaving the playback
    /// and every other surface untouched.
    ///
    /// Not `stop(_:)`: that returns a pool loan and tears the player down.
    /// This surface never held one.
    /// Files `view`'s playback under `scope` — a player handed from one
    /// owner to another (a side-list tile's clip taken over by its post's
    /// page, #1581) belongs to the new owner's scope, or its own next `play`
    /// would not recognise it and mint a fresh one at the filed second.
    public func rescope(_ view: VideoRenderView, to scope: String) {
        let key = ObjectIdentifier(view)
        guard activePlayers[key] != nil else { return }
        playingScope[key] = scope
    }

    /// Whether two surfaces draw the same player — one playback, two
    /// pictures (a passive surface bound `alongsideSurface`).
    public func sharesPlayback(_ view: VideoRenderView, with other: VideoRenderView) -> Bool {
        guard let player = view.boundPlayer else { return false }
        return player === other.boundPlayer
    }

    public func detachSurface(_ view: VideoRenderView, reason: String = "detachSurface") {
        guard activePlayers[ObjectIdentifier(view)] == nil else { return }
        view.detach(reason: reason)
    }

    /// Makes `view` the OWNER of the playback it is drawing, as the surface
    /// that replaces `previous` in its host.
    ///
    /// For a host that swaps its surface for one it was handed — a hero
    /// landing adopting the flight card's live view. The adopted view arrives
    /// JOINED: it draws, and holds no loan. The loan is still filed under the
    /// view it replaces, which the host is about to throw away.
    ///
    /// ⚠️ **THAT WAS THE EARLY-GRAB STALL, and nothing about it was early.** A
    /// discarded owner is not stopped, it is merely released; the loan stays
    /// filed under a dead key until the next `play`/`stop`/`attachSurface`
    /// runs `forgetDeadSurfaces`, which finds the owner gone and RETIRES the
    /// player — under the page drawing it and any card that joined it. The
    /// renderer is invalidated, both go dark, and the player goes back to the
    /// pool to be loaned to a different clip in the same breath. On the map's
    /// cluster feed the first sweep came from the place page the vertical grab
    /// stages, so every grab ever made from an adopted page landed on it:
    /// `INVALIDATE dropping [card:1, page:38]` one tick after the donation,
    /// then a card at `frames=0` and a black page after the cancel.
    ///
    /// Resolved by IDENTITY: the loan taken is the one on the player `view`
    /// actually draws — the replaced surface's first, then whoever else holds
    /// it, then the park. A loan `previous` still holds on some OTHER player is
    /// returned (`stop`), since nothing will ever draw it again. Nothing is
    /// re-bound and the player's state is left alone: this moves bookkeeping,
    /// not pixels. Returns whether `view` owns its playback afterwards.
    ///
    /// ⚠️ A REFUSAL TOUCHES NOTHING. The replaced surface's leftover loan is
    /// returned only once `view` owns its playback: on a refusal the host keeps
    /// (or must put back) `previous`, and stopping it there destroyed the one
    /// player still drawing. That is what a post opened from a live map pin
    /// met: the card arrived carrying ANOTHER pool's player, the adoption was
    /// refused, and the page's own fresh player was retired with it.
    @discardableResult
    public func adoptSurface(_ view: VideoRenderView, replacing previous: VideoRenderView?) -> Bool {
        let key = ObjectIdentifier(view)
        let previousKey = previous.flatMap { $0 === view ? nil : ObjectIdentifier($0) }
        // Whatever the replaced surface still holds once `view` owns its
        // playback is a loan nobody will ever stop — the exact orphan this
        // method exists to prevent. Success paths only.
        func returnPreviousLeftover() {
            if let previous, let previousKey, activePlayers[previousKey] != nil {
                stop(previous)
            }
        }
        guard let player = view.boundPlayer else { return false }
        if activePlayers[key] === player {
            returnPreviousLeftover()
            return true
        }
        let ownerKey = previousKey.flatMap { activePlayers[$0] === player ? $0 : nil }
            ?? activePlayers.first(where: { $0.value === player })?.key
        let url: URL?
        let scope: String?
        if let ownerKey {
            url = playingURL[ownerKey]
            scope = playingScope[ownerKey]
            activePlayers[ownerKey] = nil
            playingURL[ownerKey] = nil
            playingScope[ownerKey] = nil
            surfaces[ownerKey] = nil
            // The replaced surface's pending resolution, if any, must not land
            // a fresh item on a view that is being thrown away. Another
            // owner's is its own business.
            if ownerKey == previousKey { generation[ownerKey] = nil }
        } else if let parked, parked.player === player {
            url = parked.url
            scope = nil
            self.parked = nil
        } else {
            return false
        }
        #if DEBUG
        VideoProducerLog.emit("ADOPT \(VideoProducerLog.name(player)) \(url?.lastPathComponent ?? "-") -> "
            + "\(view.debugProducerName) from=\(ownerKey == nil ? "parked" : (ownerKey == previousKey ? "replaced" : "other"))")
        #endif
        generation[key] = nextGenerationToken()
        activePlayers[key] = player
        surfaces[key] = WeakSurface(view: view)
        playingURL[key] = url
        playingScope[key] = playingScope[key] ?? scope
        // The page is heard through its surface; the one it swapped in is the
        // one to hear now.
        if let previous, audibleSurface === previous {
            audibleSurface = view
            refreshAudibleSurface()
            #if DEBUG
            traceSound("audible MOVED \(previous.debugProducerName) -> \(view.debugProducerName)")
            #endif
        }
        returnPreviousLeftover()
        return true
    }

    /// Whether `adoptSurface(view, replacing:)` would succeed: `view` draws a
    /// player this pool loans out or holds parked.
    ///
    /// For a host that must decide BEFORE it swaps surfaces. A view can arrive
    /// drawing a player this pool has never seen (a card that mirrored another
    /// pool's player), or one already retired; swapping it in first and asking
    /// after left the page showing a dead surface with its own one discarded.
    public func canAdoptSurface(_ view: VideoRenderView) -> Bool {
        guard let player = view.boundPlayer else { return false }
        return activePlayers.values.contains { $0 === player } || parked?.player === player
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
        transferOwnership(of: mediaURL, drawnBy: nil, to: view)
    }

    /// `transferOwnership(of:to:)`, resolving the player by the surface the
    /// viewer is WATCHING rather than by its URL.
    ///
    /// ⚠️ A URL NAMES AN ASSET, NOT A PLAYER. Two players can run one asset —
    /// a repost in another scope, a page that minted its own beside a tile —
    /// and the URL lookup took whichever the dictionary listed first, so a
    /// landing could adopt the OTHER clock. The flight card's surface is bound
    /// to exactly the player the viewer saw land; `surface` names it. Falls
    /// back to the URL when the surface is nil or draws nothing this pool owns.
    @discardableResult
    public func transferOwnership(
        of mediaURL: URL, drawnBy surface: VideoRenderView?, to view: VideoRenderView
    ) -> Bool {
        // ⚠️ A RETURN PLAYER COUNTS, BY IDENTITY ONLY (#923). A close landing
        // on its own tile from another post flies the tile's parked clip, and
        // the tile takes THAT player here. The URL fallback below never finds
        // one: a return player is in no table it reads.
        let watched = surface?.boundPlayer.flatMap { candidate in
            (activePlayers.values.contains { $0 === candidate } || parked?.player === candidate
                || returnPlaybacks.contains { $0.player === candidate })
                ? candidate : nil
        }
        guard let player = watched ?? activePlayer(playing: mediaURL) else {
            VideoPlaybackTrace.emit("transferOwnership REFUSED \(mediaURL.lastPathComponent)")
            return false
        }
        let returned = claimReturnPlayback(player)
        VideoPlaybackTrace.emit("transferOwnership \(mediaURL.lastPathComponent)")
        VideoProducerLog.emit("TRANSFER \(VideoProducerLog.name(player)) \(mediaURL.lastPathComponent) -> \(view.debugProducerName) from="
            + (playingURL.first(where: { $0.value == mediaURL }).flatMap { surfaces[$0.key]?.view?.debugProducerName }
               ?? (parked?.url == mediaURL ? "parked" : "-")))
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
        // EVERY key that owns THIS player, by identity. Several can: a page
        // that joined and then took a loan files a second key on the same
        // player. Clearing only the first one left the other a co-owner, so
        // when the tile later stopped, the player was "still in use" and kept
        // decoding behind a hidden page.
        let key = ObjectIdentifier(view)
        let previousOwners = activePlayers.filter { $0.value === player && $0.key != key }.map(\.key)
        let previousScope = previousOwners.lazy.compactMap { self.playingScope[$0] }.first
        for previous in previousOwners {
            // Cleared WITHOUT `detach` — detaching pauses the player and hands
            // it back to the pool, which is exactly the teardown this exists to
            // get ahead of. The previous surfaces stay bound, as joined ones.
            activePlayers[previous] = nil
            playingURL[previous] = nil
            playingScope[previous] = nil
        }
        // Claimed from the park — but only when the park holds THIS asset.
        // Clearing unconditionally orphaned a parked player of a DIFFERENT
        // URL: never paused, never re-pooled, decoding forever with nothing on
        // screen. A mismatched park stays put for its own claimant, or for the
        // next discard sweep.
        if parked?.player === player { parked = nil }
        // ⚠️ A RETURN PLAYER CAN LAND ON A SURFACE THAT STILL OWNS ANOTHER ONE
        // (#923): a tile whose own loan outlived the page. Overwriting the
        // entry would leave that player decoding with nobody to stop it, so it
        // is let go the way `detach` lets one go.
        if let previous = activePlayers[key], previous !== player {
            let leavingScope = playingScope[key]
            let leavingURL = playingURL[key]
            activePlayers[key] = nil
            let stillInUse = activePlayers.values.contains { $0 === previous }
                || parked.map { $0.player === previous } ?? false
            if !stillInUse {
                rememberResume(scope: leavingScope, url: leavingURL, player: previous)
                retire(previous)
            }
        }
        // Supersede any in-flight resolution for this view, so a late `play`
        // cannot attach a second item over the one just adopted.
        generation[key] = nextGenerationToken()
        activePlayers[key] = player
        surfaces[key] = WeakSurface(view: view)
        playingURL[key] = mediaURL
        // Kept if the new owner already had one — a caller that joined before
        // taking ownership knows its own post — and inherited otherwise.
        playingScope[key] = playingScope[key] ?? previousScope ?? returned?.scope
        bind(player, to: view)
        // ⚠️ THROUGH THE PAUSE'S OWN DOOR, not a bare `play()`.
        //
        // The player handed back here is very often one the destination PAUSED
        // on its way out — a feed page that resigns without releasing playback
        // pauses the shared player, which is the ROW's player. A bare `play()`
        // resumes it and leaves everything `setPaused(false:)` does undone: the
        // anchor filed at the pause is stranded in `pausedAnchors` for a pooled
        // player that will be loaned to a different clip, the frames decoded
        // before the pause are shown instead of dropped, and the drift re-pin
        // never runs. All three exist because each was a visible defect once.
        if !setPaused(false, in: view) { player.play() }
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

    /// `setPeakBitRate(_:for:)` for THIS post's player first (`scope`), so a
    /// repost running the same file in another scope is not re-capped by it;
    /// the asset alone when no scoped player exists.
    public func setPeakBitRate(_ peakBitRate: Double, for mediaURL: URL, scope: String?) {
        (sharedActivePlayer(playing: mediaURL, scope: scope) ?? activePlayer(playing: mediaURL))?
            .currentItem?.preferredPeakBitRate = peakBitRate
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
    func sharedActivePlayer(playing mediaURL: URL, scope: String?) -> AVPlayer? {
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
    /// Puts the clip's CURRENT frame on a surface that is already attached.
    ///
    /// For the landing of a dismissal, where the row's surface has held the same
    /// renderer throughout and therefore cannot be primed by attaching again —
    /// see `VideoFrameRenderer.prime`. Without it the row draws whatever was
    /// last enqueued, which on this path is the POSTER `beginVideoPreview` just
    /// set: the card is taken away and the viewer sees a thumbnail of the clip
    /// they are already watching, until the next decode is dispatched. Filmed.
    @discardableResult
    public func primeSurface(_ view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view),
              let renderer = renderers[ObjectIdentifier(player)] else { return false }
        renderer.prime(view)
        VideoPlaybackTrace.emit("prime surface \(playingURL[ObjectIdentifier(view)]?.lastPathComponent ?? "-")")
        return true
    }

    /// ⚠️ **INTERNAL, NOT PRIVATE**, so the extensions in this module's other
    /// files — the sound controls — ask the same player every control here asks.
    func watchedPlayer(in view: VideoRenderView) -> AVPlayer? {
        activePlayers[ObjectIdentifier(view)] ?? view.boundPlayer
            ?? stilledPlayers[ObjectIdentifier(view)]?.player
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
    /// instant. No player is loaned and no byte is fetched: with a byte cache,
    /// the vertical feed's real preload is `VideoLookahead` (#895); this is
    /// what a pool without one (and UIKit's prefetch guess) still uses.
    public func preroll(_ mediaURL: URL) {
        let source = source
        Task { _ = try? await source.playableURL(for: mediaURL) }
    }

    // MARK: - Internals

    /// The renderer for `player`, minted on first use. `nil` when
    /// `-avsbdl-render` is off, which is what keeps every call site below a
    /// single line that does the right thing in both modes.
    func renderer(for player: AVPlayer) -> VideoFrameRenderer? {
        guard VideoRenderFlags.usesSampleBufferLayer else { return nil }
        let key = ObjectIdentifier(player)
        if let existing = renderers[key] { return existing }
        let renderer = VideoFrameRenderer(player: player)
        renderers[key] = renderer
        return renderer
    }

    /// Makes `view` display `player`: a layer binding in player-layer mode, a
    /// surface-set insertion in sample-buffer mode.
    func bind(_ player: AVPlayer, to view: VideoRenderView) {
        // Bound again, it shows the player: no pause of its own to remember.
        pausedSurfaces.remove(ObjectIdentifier(view))
        boundSurfaces.add(view)
        view.attach(player, renderer: renderer(for: player))
        // Every route that puts a player behind a surface ends here, so this is
        // where the audible surface learns that its player changed.
        if view === audibleSurface { refreshAudibleSurface() }
    }

    func detach(key: ObjectIdentifier, view: VideoRenderView) {
        pausedSurfaces.remove(key)
        stilledSurfaces.remove(key)
        stilledPlayers[key] = nil
        if let player = activePlayers[key] { pauseIfOnlyStillsRemain(on: player, besides: key) }
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
        VideoProducerLog.emit("STOP owner=\(view.debugProducerName) \(VideoProducerLog.name(player)) "
            + (stillInUse ? "(still owned elsewhere)"
               : "-> RETIRE with \(renderers[ObjectIdentifier(player)]?.surfaceCount ?? 0) joined surface(s)"))
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
    func retire(_ player: AVPlayer) {
        player.pause()
        removeLoop(for: player)
        // The anchor dies with the loan. It is keyed by the PLAYER, and the
        // pool reuses players — one left behind here belongs to a clip that no
        // longer exists, and the reused player's first resume would compare a
        // fresh playhead against it and seek the NEW clip to wherever the OLD
        // one was paused.
        pausedAnchors.removeValue(forKey: ObjectIdentifier(player))
        // ⚠️ A CHASE OUTLIVING ITS LOAN WOULD SEEK A POOLED PLAYER SOMEBODY ELSE
        // IS NOW USING — the same reason the anchor above is dropped here.
        chased.removeValue(forKey: ObjectIdentifier(player))
        seeking.remove(ObjectIdentifier(player))
        // And a pooled player runs no arrangement, and loops no range.
        looping.removeValue(forKey: ObjectIdentifier(player))
        // Nor carries a song, nor is heard.
        forgetSound(of: player)
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

    func installLoop(for player: AVPlayer, item: AVPlayerItem) {
        removeLoop(for: player)
        observeStalls(for: item, player: player)
        loopObservers[ObjectIdentifier(player)] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let player else { return }
                // ⚠️ EXACT, OR THE LOOP SKIPS THE OPENING OF AN ARRANGEMENT. A
                // bare `seek(to:)` is tolerant, and on a composition whose first
                // piece starts between two keyframes it lands on the first
                // keyframe INSIDE that piece — measured at 0.6s late for a piece
                // cut from 1.4s of a clip keyed every two seconds. A plain file
                // starts on a keyframe, so for it this changes nothing.
                // ⚠️ AND TO THE START OF THE RANGE, WHEN ONE IS LOOPING: the item
                // ended at the range's end, not at its own.
                let start = self?.loopStart(of: player) ?? .zero
                player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
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
    func nextGenerationToken() -> Int {
        generationCounter += 1
        return generationCounter
    }

}

/// The asset a parked frame is read from, handed off the main actor.
/// `@unchecked`: an asset's loading API is thread-safe, and the read only
/// loads from it.
struct ReturnStillSource: @unchecked Sendable {
    let asset: AVAsset
}
