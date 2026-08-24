import CoreModels
import MediaPlayback
import UIKit

/// Decides which visible grid tiles autoplay, and at what quality.
///
/// The grid analog of `MapVideoPlaybackCoordinator`, and it exists for the same
/// reason: a mosaic can show a dozen video bricks at once, and one `AVPlayer`
/// per brick is not affordable. At most `maxConcurrent` play, chosen by
/// proximity to the viewport centre, through a shared pool.
///
/// Square tiles never appear among the candidates — the caller filters on
/// `GalleryPost.autoplaysInGrid` — so only portrait and landscape bricks
/// compete for the pool.
///
/// **Where it differs from the map, and why.** A map pin plays a dedicated
/// lightweight clip. A grid tile plays the *full stream* — the very asset the
/// full-screen viewer will open — so that tapping a playing tile can hand the
/// live `AVPlayerItem` to the destination and keep the playhead. Quality is
/// therefore managed with `preferredPeakBitRate` on that one item instead of by
/// choosing a smaller file: tiles are pinned to `tileBitRateCap` (a rung sized
/// for a thumbnail), and the cap is lifted when a tile goes full screen.
/// Swapping to a lighter asset would mean a new item, which resets `currentTime`
/// to zero — the restart the hero transition exists to avoid.
///
/// See `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §0.3.
@MainActor
public final class GridVideoPlaybackCoordinator {
    /// One playable tile: its post, the stream, and the cell rendering it.
    public struct Candidate {
        public let id: PostID
        public let url: URL
        public let cell: any GridPlaybackCell
        /// Distance from the viewport's vertical centre, in points. Lower wins;
        /// the caller measures it because only it knows the scroll geometry.
        public let distanceFromCentre: CGFloat
        /// Held, but not advancing.
        ///
        /// ⚠️ A THIRD STATE, and the reason it exists: a clip on page two of a
        /// carousel is still on screen when the viewer moves to page three —
        /// peeking beside it — and stopping it there put the page's THUMBNAIL
        /// back, which reads as the video being replaced by a photograph. Paused
        /// it keeps its last frame, and coming back costs nothing.
        ///
        /// A paused candidate still holds its pool slot, so it competes for one
        /// exactly as a playing one does: it is released when the ranking gives
        /// its slot to a row nearer the centre, not when it stops advancing.
        public let isPaused: Bool

        public init(
            id: PostID, url: URL, cell: any GridPlaybackCell,
            distanceFromCentre: CGFloat, isPaused: Bool = false
        ) {
            self.id = id
            self.url = url
            self.cell = cell
            self.distanceFromCentre = distanceFromCentre
            self.isPaused = isPaused
        }
    }

    /// The rung a resting tile is held to, in bits per second.
    ///
    /// 600 kbps is chosen against a real ladder rather than in the abstract:
    /// Apple's BipBop test stream rungs are 264 / 578 / 916 / 1030 / 1924 kbps,
    /// so this admits the 640x360 rung and excludes 960x540 and everything
    /// above. A tile is at most a third of the screen's width, so 360p is
    /// already generous for it, and three concurrent tiles then cost roughly
    /// one 720p stream rather than three.
    ///
    /// A ladder whose floor sits above this cap simply gets its lowest rung —
    /// `preferredPeakBitRate` is a ceiling, not a filter, and AVFoundation
    /// still plays the cheapest available variant if none fits.
    public static let tileBitRateCap: Double = {
        #if DEBUG
        // `-grid-bitrate-cap <bps>` overrides the rung a resting tile is held
        // to; `0` lifts it entirely. Exists so the cap's effect can be measured
        // against a real ladder without a rebuild — capped and uncapped runs of
        // the same build, same fixtures, same scroll position.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-grid-bitrate-cap"),
           position + 1 < arguments.count,
           let override = Double(arguments[position + 1]) {
            return override
        }
        #endif
        return 600_000
    }()

    /// Lifted: the item may climb the whole ladder. What a full-screen page gets.
    public static let uncapped: Double = 0

    private let pool: VideoPlaybackController
    private let maxConcurrent: Int
    /// Posts this coordinator has taken a loan for → the cell it gave it to.
    ///
    /// ⚠️ A REGISTRY OF LOANS, not the truth about playback. The distinction is
    /// the whole of this file's hardest bug: a handoff moves a player to the
    /// page's surface — `transferOwnership` clears the previous owner's
    /// registration on purpose — and this map knows nothing about it. Read as
    /// "is this playing", it then answered yes for a row whose picture had
    /// stopped, and the reconcile skipped it as already running.
    ///
    /// So the map answers only what it can know: which cells this coordinator
    /// has started and must therefore clean up. Whether anything is PLAYING is
    /// the pool's to answer — see `isPlaying`.
    private var loans: [PostID: any GridPlaybackCell] = [:]
    /// Playing posts → the stream each one is actually playing.
    ///
    /// ⚠️ A post is no longer one stream. A mixed carousel has a clip on one
    /// page and a photograph on the next, so the same id can be asked to play a
    /// DIFFERENT url as the viewer scrolls — and the reconcile below starts a
    /// candidate only when nothing is playing for its id, which would have left
    /// page two's clip running under page three's.
    private var playingURLs: [PostID: URL] = [:]
    /// Posts whose cap is currently lifted (a tile that went full screen), so a
    /// reconcile doesn't quietly re-cap the item mid-flight.
    private var uncappedIDs: Set<PostID> = []
    private var isSurfaceVisible = true
    /// The post whose player is currently being handed to (or from) a
    /// full-screen page. Inside a handoff this coordinator treats that post as
    /// none of its business: `reconcile` neither starts nor stops it.
    private var handoffID: PostID?
    /// In-flight `play` calls, keyed by post. Held so a stop arriving while the
    /// URL is still resolving cancels it, rather than letting a late attach
    /// bind a player to a tile that has already scrolled away.
    private var startTasks: [PostID: Task<Void, Never>] = [:]

    /// Fires when a hosted surface is torn down, so the host can forget it.
    public var onHostedSurfaceReleased: ((PostID) -> Void)?

    public init(pool: VideoPlaybackController, maxConcurrent: Int = 6) {
        self.pool = pool
        self.maxConcurrent = maxConcurrent
    }

    /// Reconciles playback against the currently visible video tiles. Stops
    /// tiles that scrolled away or lost their slot, starts newly chosen ones.
    /// Idempotent — safe to call continuously during a scroll.
    ///
    /// `allowingStarts: false` performs the stop half only. Stopping always
    /// runs: a tile that has left the viewport must give its player back
    /// immediately whatever the scroll is doing, or the pool starves.
    public func update(candidates: [Candidate], allowingStarts: Bool = true) {
        // The post in flight is excluded from BOTH halves. Stopping it would
        // kill the player the card is rendering; starting it would attach a
        // competing layer. Its lifecycle belongs to the handoff scope until
        // `endHandoff`.
        let ranked = candidates
            .filter { $0.id != handoffID }
            .sorted { $0.distanceFromCentre < $1.distanceFromCentre }
        let chosen = isSurfaceVisible ? Array(ranked.prefix(maxConcurrent)) : []
        let chosenIDs = Set(chosen.map(\.id))
        #if DEBUG
        logRankingIfChanged(ranked, chosen: chosenIDs)
        #endif

        for (id, cell) in loans where !chosenIDs.contains(id) && id != handoffID {
            stop(id: id, cell: cell)
        }
        // A post that is still chosen but on a DIFFERENT stream — the viewer
        // paged a mixed carousel from one clip to another — is stopped here so
        // the start below can pick it up. Restarting rather than retargeting
        // the existing player: the pool binds an item to a render surface, and
        // the surface has moved to another page too.
        // ⚠️ THE BUDGET IS IN PLAYERS, NOT ROWS — and the difference is the only
        // honest way to let a row keep a clip warm.
        //
        // Every chosen row is about to hold one player, so what a carousel may
        // additionally keep is whatever the pool can carry beyond that. It goes
        // to the most central row, because a viewer swiping a card's pages is
        // looking at it. When the screen is full of playing rows the spare is
        // zero and every row behaves exactly as it did before — the feature
        // yields to its neighbours rather than competing with them.
        let spare = max(0, pool.capacity - chosen.count)
        for (rank, candidate) in chosen.enumerated() where candidate.id != handoffID {
            for surface in candidate.cell.retainClips(budget: rank == 0 ? spare : 0) {
                pool.stop(surface)
            }
            // ⚠️ ONE CLIP ADVANCES IN A CAROUSEL, AND IT IS THE WATCHED ONE.
            //
            // Two halves, and the second was wrong. A kept clip must be paused,
            // or in a card the page just left goes on playing while still
            // peeking on screen — "keeps its last frame" turning into "keeps
            // running". And the one spared must be the page the viewer is ON.
            //
            // Read from `loadedVideoRenderView`, it was not: that field is
            // re-pointed only when someone asks the cell for a surface, which
            // happens in the START pass below. So this pass spared the page
            // being LEFT and paused the one arriving — reported as several
            // clips playing at once in a card's carousel, and reproduced as the
            // wrong surface being the one that advanced.
            let watched = candidate.cell.watchedClipSurface
            for surface in candidate.cell.retainedPlaybackSurfaces
            where surface !== watched {
                // ⚠️ Adaptive streams are released rather than held — see the
                // note on `isAdaptiveStream`. Held paused they come back running
                // several times too fast; released, returning to one costs a
                // fresh start, which is what it always cost.
                if pool.isAdaptiveStream(in: surface) {
                    pool.stop(surface)
                } else {
                    pool.setPaused(true, in: surface)
                }
            }
            prewarm(candidate)
        }
        for candidate in chosen
        where candidate.id != handoffID
            && loans[candidate.id] != nil
            && playingURLs[candidate.id] != candidate.url {
            // ⚠️ RELEASED, not stopped, when the row is keeping the old clip.
            //
            // Paging a mixed carousel from one clip to another used to stop the
            // loan so the start below could pick up the new stream — which threw
            // away the player for the page just left, so coming back re-decoded
            // and the page showed its thumbnail meanwhile. Exactly the cut fixed
            // on the post page.
            //
            // A row holding more than one surface has somewhere to put the old
            // clip, so only the BOOKKEEPING is undone: the start loop then binds
            // the new page's own surface and the old one stays paused on its
            // page. A row holding one surface has nowhere, and still stops.
            #if DEBUG
            if CarouselPlaybackAudit.isEnabled {
                CarouselPlaybackAudit.trace(
                    "grid url-changed \(candidate.id.rawValue) "
                    + "was=\(playingURLs[candidate.id]?.lastPathComponent ?? "nil") "
                    + "now=\(candidate.url.lastPathComponent) "
                    + "surfaces=\(candidate.cell.retainedPlaybackSurfaces.count)"
                )
            }
            #endif
            if candidate.cell.retainedPlaybackSurfaces.count > 1 {
                releaseStaleLoan(id: candidate.id)
            } else {
                stop(id: candidate.id, cell: candidate.cell)
            }
        }
        // Paused or resumed to match, every time, for everything still chosen.
        // Reconciliation and not an edge: a row can arrive already paused (its
        // carousel was left on another page), and a start below is followed by
        // the same call for the same reason.
        // Paused or resumed to match, every time, for everything still chosen.
        // Reconciliation and not an edge: a row can arrive already paused (its
        // carousel was left on another page), and a start below is followed by
        // the same call for the same reason.
        // ⚠️ A LOAN WITH NO PLAYER BEHIND IT IS RELEASED, not resumed.
        //
        // This is what the derived `isPlaying` buys. A row whose player went to
        // the page at a handoff still holds a loan here; asking its surface to
        // resume does nothing — measured, `setPaused` returning false — and the
        // start loop below used to skip it as already running. The picture then
        // stayed on its last frame for good.
        //
        // Released rather than stopped: there is nothing to tear down, and
        // `stop` would fade the cover back in for the one frame before the
        // restart.
        // ⚠️ A START STILL IN FLIGHT IS NOT A STALE LOAN.
        //
        // `isPlaying` asks the pool whether a player is bound, and between
        // `start` and its `await` landing the honest answer is "not yet". Read
        // as staleness, the loan was released and the whole start thrown away
        // and reissued — cancelling the resolution that was about to succeed and
        // beginning the clip again from zero. Seen in the audit as a released
        // loan followed immediately by a second `start` for the same post.
        for candidate in chosen
        where loans[candidate.id] != nil
            && startTasks[candidate.id] == nil
            && !isPlaying(candidate.id) {
            releaseStaleLoan(id: candidate.id)
        }
        for candidate in chosen where isPlaying(candidate.id) {
            candidate.cell.loadedVideoRenderView.map {
                pool.setPaused(candidate.isPaused, in: $0)
            }
        }
        guard allowingStarts else { return }
        for candidate in chosen where loans[candidate.id] == nil {
            start(candidate)
        }
        // ⚠️ THE ONE PLACE THE RULE IS APPLIED: in a carousel, the watched clip
        // advances and nothing else does.
        //
        // Three passes above can each leave it stopped, and between them they
        // did. A warmed clip is paused by construction — that is what warming
        // IS — so arriving at one found a player already bound and nothing that
        // would resume it: the pause pass had just paused everything, the loan
        // had been released as stale, and the start pass skips a row whose
        // player exists. The result was a carousel where nothing played at all,
        // which is the mirror image of the reported fault and was produced by
        // fixing it.
        //
        // Stated once, at the end, against the surface the CAROUSEL says is
        // being watched — rather than left as an emergent property of three
        // passes that each know a piece of it.
        for candidate in chosen
        where candidate.id != handoffID && !candidate.isPaused {
            guard let watched = candidate.cell.watchedClipSurface,
                  pool.hasPlayer(in: watched) else { continue }
            pool.setPaused(false, in: watched)
        }
        #if DEBUG
        Self.logPool(loans.count, handoff: handoffID)
        #endif
    }

    // MARK: - Handoff scope

    /// Opens a handoff for `id`: the grid is about to be covered by a
    /// full-screen page that will take over this post's player.
    ///
    /// Every other tile stops here — their slots are what the page needs — and
    /// `id` becomes invisible to `reconcile` for the duration. This replaces
    /// the several ad-hoc entry points that each mutated per-tile state
    /// directly; they could disagree, and the grid came back with one or two
    /// slots alive instead of six.
    /// Moves the handoff exemption to another post without re-running the
    /// scope's teardown.
    ///
    /// The scope is opened for the post that was TAPPED, but a dismissal can
    /// land on a different one — the grid moves whatever the feed settled on
    /// into the departure slot. Landing exempted the wrong post: the tile
    /// adopted the flight's surface and then `updateAutoplay`, which runs the
    /// instant the tile is unhidden, swept it away again because it was neither
    /// `handoffID` nor a viable candidate (a tile with no cover yet cannot be
    /// one). The surface was torn down in the same turn it was handed over,
    /// which is the flash, and the playhead went with it.
    public func retargetHandoff(_ id: PostID) {
        handoffID = id
    }

    public func beginHandoff(_ id: PostID) {
        handoffID = id
        isSurfaceVisible = false
        // The other tiles release their players OFF the tap turn, one per
        // main-queue hop, instead of synchronously here. Each stop is real
        // AVFoundation teardown — pause, `replaceCurrentItem(nil)`, renderer
        // invalidation — and up to five of them ran inside the very turn that
        // also seeds the feed, lays the container out twice and commits the
        // flight's first frame. At 120Hz that turn has an 8ms budget, and
        // blowing it is a dropped frame at frame 0 of the present — sporadic
        // because the cost scales with how many tiles happened to be playing.
        //
        // Nothing needs the stops synchronously: `isSurfaceVisible` above
        // already keeps `update` from starting anything new, the tapped post
        // is exempt on every path, and the tiles simply keep drawing behind
        // the dim for the few frames the stagger takes — which is invisible,
        // and arguably truer than freezing them all at the instant of the tap.
        stopStaggered(loans.keys.filter { $0 != id }, forHandoff: id)
        #if DEBUG
        Self.logPool(loans.count, handoff: handoffID)
        // Arm the flight probe HERE — the one moment guaranteed to precede any
        // window under test, since the scope opens before a transition is even
        // built. Every path that flies this tile's media goes through it.
        //
        // The `NOT armed` branch is the important half. A probe attached after
        // the window reports silence, and silence is indistinguishable from
        // success — twice in this issue's history a conclusion was drawn from a
        // trace that was never live. This says so instead, and names what WAS
        // playing, which is usually the reason (a tile that does not autoplay).
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            if let surface = loans[id]?.loadedVideoRenderView {
                surface.debugLabel = "tile"
                surface.debugTracksFlight = true
                // Name the post being flown. Without it there is no way to tell
                // which fixture a flight actually carried, and a capture of a
                // legitimately-black asset is indistinguishable from a broken
                // renderer — which is exactly how three rounds of this were
                // spent judging the wrong thing.
                print(String(format: "[zoom-live] %.3f probe armed on tile post=%@ ready=%@",
                             CACurrentMediaTime(), String(describing: id),
                             surface.isReadyForDisplay ? "true" : "false"))
            } else {
                print(String(format: "[zoom-live] %.3f probe NOT armed — no live surface for %@ (playing: %@)",
                             CACurrentMediaTime(), String(describing: id),
                             loans.keys.map { String(describing: $0) }.sorted().joined(separator: ",")))
            }
        }
        #endif
    }

    /// Stops one tile per main-queue hop, so the teardown cost lands as a few
    /// milliseconds per frame instead of one multi-frame stall.
    ///
    /// Every step re-checks the world before acting: the scope may have closed
    /// or moved to another post — its own reconcile is then the authority and
    /// these stops are stale — and a tile may already have been stopped by a
    /// reconcile or a cell reuse in the meantime, in which case `playing` no
    /// longer names it and the step is a no-op.
    private func stopStaggered(_ ids: [PostID], forHandoff handoff: PostID) {
        var remaining = ids
        guard let next = remaining.popLast() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, handoffID == handoff else { return }
            if let cell = loans[next] {
                stop(id: next, cell: cell)
            }
            stopStaggered(remaining, forHandoff: handoff)
        }
    }

    /// Closes the handoff and retires anything left parked. The caller
    /// reconciles immediately after, and that single reconcile is what restores
    /// the full slate of slots — deterministically, from the visible set, with
    /// no residue from the flight.
    public func endHandoff() {
        handoffID = nil
        isSurfaceVisible = true
        pool.discardParkedPlayback()
        // NOT swept here. `endHandoff` fires while the flight card can still be
        // in the air — measured on the tap-back path as
        // `card DETACHED by flightSurfaceSweep (frames=11)`, once per cycle,
        // taking the live surface out from under a card that was mid-flight and
        // leaving it on its cover. That is the tap-back thumbnail pop.
        //
        // The sweep keeps its self-limiting property from the OTHER call site:
        // `makeAttachedSurface` sweeps before minting, so each flight clears
        // the previous one's leftovers and the count still cannot grow. What is
        // removed here is only the mid-flight sweep, which was never the part
        // that bounded anything.
        #if DEBUG
        Self.logPool(loans.count, handoff: nil)
        #endif
    }

    /// Whether a handoff is open — the transition's own guard against
    /// re-entrancy.
    public var isHandingOff: Bool { handoffID != nil }

    /// Stops whatever is playing in `cell` — the collection view recycled it.
    public func stop(cell: any GridPlaybackCell) {
        guard let id = loans.first(where: { $0.value === cell })?.key else { return }
        stop(id: id, cell: cell)
    }

    /// Tab hidden, feed presented over the grid, or app backgrounded.
    ///
    /// `keeping` exempts one post from the sweep: the tapped tile, whose live
    /// player the hero transition is still flying. Stopping it mid-flight is
    /// exactly the restart the handoff exists to prevent.
    public func setSurfaceVisible(_ visible: Bool, keeping kept: PostID? = nil) {
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        guard !visible else { return }
        for (id, cell) in loans where id != kept {
            stop(id: id, cell: cell)
        }
    }

    // MARK: - Hero handoff

    /// Whether `id` is playing right now — the source asks before deciding
    /// whether a flight can carry live video at all.
    ///
    /// ⚠️ DERIVED FROM THE POOL, never from this coordinator's own memory.
    ///
    /// Five places used to hold a piece of this one fact — the pool's player
    /// map, this loan registry, a carousel page's weak reference to its
    /// surface, the cell's render view, and a flight card's donated view — and
    /// every defect in this feature was two of them disagreeing. A player that
    /// moved on is invisible to everyone except the pool, which is the only one
    /// that has to be told.
    ///
    /// So the answer is asked, not remembered. A disagreement is now impossible
    /// rather than merely detectable.
    /// The cell this coordinator handed `id`'s loan to — which is NOT
    /// necessarily the cell showing `id` now. Exposed so the audit can compare
    /// the two.
    public func loanedCell(_ id: PostID) -> (any GridPlaybackCell)? { loans[id] }

    public func isPlaying(_ id: PostID) -> Bool {
        guard let surface = loans[id]?.loadedVideoRenderView else { return false }
        return pool.hasPlayer(in: surface)
    }


    /// Hands the tile's running player off to whatever plays the same URL next
    /// — the full-screen page the viewer just tapped into.
    ///
    /// The player keeps running while parked, so the destination adopts a live
    /// item rather than opening a second one at zero. The cap is not lifted
    /// here: the adopting caller states its own rung when it plays, and the
    /// full-screen page asks for uncapped, so the ladder opens up as part of the
    /// same handoff instead of as a separate step that could disagree with it.
    ///
    /// Returns whether a live player was actually handed over.
    /// Hands the tile's already-rendering surface to a flight card and parks
    /// the player behind it.
    ///
    /// The surface stays attached to the player, so the card displays a live
    /// frame from the instant it is posed — no mirror, no new layer, no
    /// readiness gap. Returns the donated view, or nil when the tile is not
    /// playing.
    public func donateLiveSurface(of id: PostID) -> VideoRenderView? {
        // ⚠️ Only when the surface is showing what the viewer is looking at.
        //
        // "Playing" no longer means "this cell's picture is moving": a row keeps
        // its player while the viewer pages onto a still of the same collection.
        // Donating it there flew a clip the viewer had already paged past —
        // reported as the hero animation taking the video as its window after a
        // swipe. Declining falls through to the card's own cover, which is the
        // current page's.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            let cell = loans[id]
            print(String(format: "[zoom-live] %.3f grid donate ask %@ playing=%@ current=%@",
                         CACurrentMediaTime(), id.rawValue,
                         cell == nil ? "N" : "Y",
                         (cell?.isRenderingCurrentMedia ?? false) ? "Y" : "N"))
        }
        #endif
        guard let cell = loans[id], cell.isRenderingCurrentMedia,
              let renderView = cell.loadedVideoRenderView,
              pool.parkPlayback(from: renderView, keepingSurfaceAttached: true)
        else { return nil }
        let donated = cell.donateVideoRenderView()
        cell.onReuse = nil
        loans[id] = nil
        playingURLs[id] = nil
        uncappedIDs.remove(id)
        startTasks.removeValue(forKey: id)?.cancel()
        return donated
    }

    /// Builds an ADDITIONAL surface showing `id`'s live playback, leaving the
    /// tile's own surface exactly where it is.
    ///
    /// The N-surface replacement for `donateLiveSurface`, and the difference is
    /// the whole of #83: nothing is transferred, nothing is parked, and the
    /// tile keeps drawing for the entire flight. There is no moment at which
    /// some surface is waiting on a decode round-trip, because no binding
    /// changed. Returns nil when the tile is not playing.
    public func makeAttachedSurface(for id: PostID, url: URL) -> VideoRenderView? {
        // Same rule as `donateLiveSurface`, for the same reason: a surface that
        // is not showing the viewer's media must not be flown.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f grid attach ask %@ playing=%@ current=%@",
                         CACurrentMediaTime(), id.rawValue,
                         loans[id] == nil ? "N" : "Y",
                         (loans[id]?.isRenderingCurrentMedia ?? false) ? "Y" : "N"))
        }
        #endif
        guard loans[id]?.isRenderingCurrentMedia ?? false else { return nil }
        // Sweep before minting, not only at `endHandoff`. A flight can end
        // without the scope closing cleanly, and this way each new flight
        // cannot inherit more than the previous one's leftovers — the count is
        // self-limiting rather than dependent on a teardown path being hit.
        releaseFinishedFlightSurfaces()
        guard loans[id] != nil else { return nil }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "card"
        view.debugTracksFlight = true
        #endif
        guard pool.attachSurface(view, to: url) else { return nil }
        // Refuse a surface that could not be primed.
        //
        // `attachSurface` succeeds whenever something is playing the URL, but
        // priming only works if that renderer has already decoded a frame. On a
        // DISMISS the grid tile is often not decoding — the feed page is — so
        // this produced a surface with no frame, `revealOnFirstFrame` hid it,
        // and the card flew a hidden empty layer over its own cover. That is
        // the thumbnail, traced end to end.
        //
        // Returning nil instead lets `ZoomFlight.build` fall through to the
        // destination's `zoomDonateLiveMediaView`, whose surface joins a
        // renderer that IS decoding. Whichever side can actually draw wins,
        // rather than whichever side is asked first.
        guard view.hasFrame else {
            pool.detachSurface(view, reason: "unprimedRefusal")
            return nil
        }
        flightSurfaces.add(view)
        // Second open of a post that a PREVIOUS dismissal landed by hosting.
        //
        // That surface is parented in the tab bar controller's view, above the
        // navigation controller, so unlike a tile's own surface it is not
        // covered when the feed goes full screen — it keeps drawing on top, at
        // the grid cell's rect. Two layers of the same media, which is the
        // duplicate. Nothing released it either: `stop` is the only path that
        // does, and `beginHandoff` exempts the very post being opened.
        //
        // Released HERE, and not at `beginHandoff`, because of ownership. After
        // a hosted landing this surface holds the pool loan, and the loan
        // cannot simply be dropped: `detachSurface` refuses an owner outright,
        // and clearing the registration would orphan the player, since
        // `activePlayer(playing:)` is how every later attach finds it again. A
        // successor has to exist first — and `view`, attached and primed just
        // above, is it. `transferOwnership` moves the loan without touching a
        // layer, which leaves the old surface an ordinary joined one that can
        // then be detached and dropped.
        if let stale = hostedSurfaces.removeValue(forKey: id), stale !== view {
            pool.transferOwnership(of: url, to: view)
            pool.detachSurface(stale, reason: "hostedSurfaceSuperseded")
            stale.removeFromSuperview()
            onHostedSurfaceReleased?(id)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] released stale hosted surface for \(id), " +
                      "surfaces now \(pool.surfaceCount(for: url).map(String.init) ?? "nil")")
            }
            #endif
        }
        return view
    }

    /// Lands a dismissal on `cell` by giving the tile its OWN surface on the
    /// still-running playback and moving the pool loan to it.
    ///
    /// The N-surface replacement for `adoptLiveSurface`, and the difference is
    /// the last handoff in this issue. That path installed the flight card's
    /// view into the cell — a re-parent, measured at ~65ms of readiness drop,
    /// and the reason `ZoomAnimator.holdCard` exists. Here the tile's surface
    /// is primed with the current frame the moment it attaches, so it is
    /// already showing the right pixels before the card is taken away; nothing
    /// moves and there is nothing to hold across.
    @discardableResult
    public func adoptAttachedSurface(for id: PostID, url: URL, cell: any GridPlaybackCell) -> Bool {
        let view = cell.makeVideoRenderViewIfNeeded()
        #if DEBUG
        view.debugLabel = "tile"
        view.debugTracksFlight = true
        #endif
        cell.beginVideoPreview()
        // Ownership FIRST, unhide second. `transferOwnership` attaches the
        // surface, which primes it with the current frame — so by the time it
        // becomes visible it already has the right pixels. Unhiding first
        // exposed one frame of an empty surface at the exact moment the flight
        // card is taken away, which is a flash at landing.
        guard pool.transferOwnership(of: url, to: view) else { return false }
        view.revealOnFirstFrame()
        pool.setPeakBitRate(Self.tileBitRateCap, for: url)
        loans[id] = cell
        uncappedIDs.remove(id)
        cell.onReuse = { [weak self] in
            guard let self, let cell = loans[id] else { return }
            stop(id: id, cell: cell)
        }
        #if DEBUG
        Self.logPool(loans.count, handoff: handoffID)
        #endif
        return true
    }

    /// Surfaces minted by `makeAttachedSurface`, held weakly — the renderer
    /// holds them weakly too, so this is bookkeeping for *when* to detach, not
    /// ownership.
    private let flightSurfaces = NSHashTable<VideoRenderView>.weakObjects()

    /// Detaches minted surfaces that have left the window.
    ///
    /// Windowless is the predicate because a surface still in a window is by
    /// definition still being used — releasing on any looser test (a timer, or
    /// "the flight said it was done") risks blanking a card that is still on
    /// screen, which is the exact defect this whole issue is about.
    ///
    /// Without this, discarded flight cards sat in the renderer's set until ARC
    /// collected them: measured `attached=6` against `drawn=3` over three
    /// cycles. The renderer already skips windowless surfaces so the cost was
    /// nil, but the count was real and would have grown with a retain bug
    /// anywhere upstream.
    private func releaseFinishedFlightSurfaces() {
        for view in flightSurfaces.allObjects where view.window == nil {
            pool.detachSurface(view, reason: "flightSurfaceSweep")
            flightSurfaces.remove(view)
        }
    }

    @discardableResult
    public func parkForHandoff(_ id: PostID) -> Bool {
        guard let cell = loans[id], let renderView = cell.loadedVideoRenderView else { return false }
        let parked = pool.parkPlayback(from: renderView)
        // The tile no longer owns a player; drop the bookkeeping so a reconcile
        // can hand it a fresh one when the viewer comes back.
        if parked {
            cell.endVideoPreview()
            cell.onReuse = nil
            loans[id] = nil
        playingURLs[id] = nil
            uncappedIDs.remove(id)
        }
        return parked
    }

    /// Installs the flight card's live surface on the landing tile and claims
    /// the player parked behind it, so the tile keeps rendering the frame the
    /// card was showing.
    public func adoptLiveSurface(_ view: VideoRenderView, for id: PostID, url: URL, cell: any GridPlaybackCell) {
        cell.adoptVideoRenderView(view)
        cell.beginVideoPreview()
        guard pool.unparkPlayback(to: view, mediaURL: url) else { return }
        pool.setPeakBitRate(Self.tileBitRateCap, in: view)
        loans[id] = cell
        cell.onReuse = { [weak self] in
            guard let self, let cell = loans[id] else { return }
            stop(id: id, cell: cell)
        }
    }



    /// Surfaces rendering a tile's video from OUTSIDE its cell — hoisted to a
    /// parent-level host so the hero flight never re-parents them. The cell has
    /// no surface of its own while one of these is live.
    private var hostedSurfaces: [PostID: VideoRenderView] = [:]

    /// Registers a hosted surface as the player for `id` WITHOUT moving it into
    /// the cell.
    ///
    /// This is the landing that removes the last readiness drop: every other
    /// route re-parents the surface into the tile, and a re-parent costs a
    /// decode round-trip (~65ms, measured). Here the layer simply never moves —
    /// the cell publishes geometry instead of owning the view.
    @discardableResult
    public func adoptHostedSurface(
        _ view: VideoRenderView, for id: PostID, url: URL, cell: any GridPlaybackCell
    ) -> Bool {
        // Two handoff models, and this has to use the one the producing side
        // actually used. Under N-surface rendering the feed page does NOT park:
        // `SnapFeedCell.parkPlayback` returns early by design, because nothing
        // needs to stop rendering — the loan moves by ownership transfer and
        // the player keeps drawing right through the landing.
        //
        // This side kept asking for an unpark regardless, so it was claiming a
        // park that the AVSBDL path never creates. Measured: `parkedURL=nil` at
        // every landing, `unparkPlayback` refusing every time, and the tile
        // falling back to starting a fresh player — paying exactly the
        // readiness drop the permanent hoist exists to remove.
        let claimed = VideoRenderFlags.usesSampleBufferLayer
            ? pool.transferOwnership(of: url, to: view)
            : pool.unparkPlayback(to: view, mediaURL: url)
        guard claimed else { return false }
        pool.setPeakBitRate(Self.tileBitRateCap, in: view)
        hostedSurfaces[id] = view
        loans[id] = cell
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            // Steady state: the flight is over, so this is the count that
            // reveals a leak. Transient counts taken mid-flight cannot.
            print("[zoom-live] settled surfaces for \(url.lastPathComponent) = " +
                  "\(pool.surfaceCount(for: url).map(String.init) ?? "nil")")
        }
        #endif
        cell.onReuse = { [weak self] in
            guard let self, let cell = loans[id] else { return }
            stop(id: id, cell: cell)
        }
        #if DEBUG
        Self.logPool(loans.count, handoff: handoffID)
        #endif
        return true
    }

    /// The URL parked for the current handoff — diagnostics only.
    public var debugParkedURL: URL? { pool.parkedURL }

    /// The hosted surface for `id`, if its video is rendering outside the cell.
    public func hostedSurface(for id: PostID) -> VideoRenderView? { hostedSurfaces[id] }

    /// Whether the tile for `id` has a surface with a decoded frame on screen.
    /// False while its layer is still acquiring — the window a landing card is
    /// held across.
    public func isSurfaceRendering(for id: PostID) -> Bool {
        // `isRenderingVisibly`, not `isReadyForDisplay && !isHidden`: the reveal
        // cross-fades, so those two go true while the surface is still
        // transparent and a landing gated on them drops the flight card two
        // frames early, showing the tile's cover through it.
        if let hosted = hostedSurfaces[id] { return hosted.isRenderingVisibly }
        guard let cell = loans[id], let view = cell.loadedVideoRenderView else { return false }
        return view.isRenderingVisibly
    }

    /// Retires a parked player nobody adopted — a cancelled flight, or a
    /// destination that never played it.
    ///
    /// Held off while a start is in flight, because that start is very likely
    /// the claimant. `play` resolves asynchronously, so on a dismissal the
    /// landing tile's start is still queued when the transition's clean-up
    /// runs; sweeping there destroyed the very player the tile was about to
    /// adopt, and the video restarted from zero on every return.
    public func discardHandoff() {
        guard startTasks.isEmpty else { return }
        pool.discardParkedPlayback()
    }

    public func stopAll() {
        for (id, cell) in loans { stop(id: id, cell: cell) }
    }

    // MARK: - Internals

    private func start(_ candidate: Candidate) {
        #if DEBUG
        Self.logTransition("start", candidate.id, count: loans.count + 1)
        if CarouselPlaybackAudit.isEnabled {
            let surface = candidate.cell.watchedClipSurface
            CarouselPlaybackAudit.trace(
                "grid start \(candidate.id.rawValue) url=\(candidate.url.lastPathComponent) "
                + "warm=\(surface.map { pool.hasPlayer(in: $0) } ?? false)"
            )
        }
        #endif
        loans[candidate.id] = candidate.cell
        playingURLs[candidate.id] = candidate.url
        candidate.cell.beginVideoPreview()
        let renderView = candidate.cell.makeVideoRenderViewIfNeeded()
        let id = candidate.id
        candidate.cell.onReuse = { [weak self] in
            guard let self, let cell = loans[id] else { return }
            stop(id: id, cell: cell)
        }
        let url = candidate.url
        // A tile that is already flying full screen keeps its lifted cap.
        let cap = uncappedIDs.contains(id) ? Self.uncapped : Self.tileBitRateCap
        let paused = candidate.isPaused
        // ⚠️ A CLIP THAT IS ALREADY WARM IS RESUMED, NOT RE-PLAYED.
        //
        // `play` on a surface already bound to this asset replaces the item and
        // begins again at zero — so arriving at a clip prepared for exactly this
        // moment threw the preparation away and restarted it. Reported as "the
        // last video's player jumps, it always resumes from the beginning", and
        // read off the audit as `grid start … warm=true`: the coordinator was
        // told the surface was ready and started it anyway.
        //
        // Worst on the last page of that gallery only because its stream is
        // HLS, so re-filling the pipeline takes long enough to see as black.
        // The fault had nothing to do with being last.
        if pool.isBound(url, in: renderView) {
            #if DEBUG
            if CarouselPlaybackAudit.isEnabled {
                CarouselPlaybackAudit.trace("grid resumed warm \(candidate.id.rawValue)")
            }
            #endif
            pool.setPaused(paused, in: renderView)
            return
        }
        startTasks[id] = Task { [weak self, pool] in
            await pool.play(url, in: renderView, peakBitRate: cap)
            // A candidate that arrives already paused — its carousel is resting
            // on another page — is started and held on its first frame, which is
            // what makes the frame there to show at all.
            if paused { pool.setPaused(true, in: renderView) }
            // A settled start removes its own entry. Left in place, the map
            // only ever shrank on stop/donate, so `startTasks.isEmpty` — the
            // gate `discardHandoff` uses to tell "a claimant is still coming"
            // from "nobody is coming" — was false for the rest of the session
            // after the first tile ever played, and a stranded parked player
            // was never retired: it sat decoding, looping, invisible.
            //
            // The cancellation check is what protects a SUCCESSOR's entry: a
            // stop cancels this task but its continuation still resumes, and
            // by then the same id may hold a fresh start's task.
            guard let self, !Task.isCancelled else { return }
            startTasks.removeValue(forKey: id)
        }
    }

    /// Brings a row's next clip to its first frame, so swiping the card's pages
    /// shows a picture rather than a thumbnail and a wait.
    ///
    /// ⚠️ A WARM-UP THAT LANDS AFTER THE ROW LOST ITS LOAN IS UNDONE.
    ///
    /// `prewarm` binds its player on the far side of an await, and a feed is
    /// scrolling the whole time — so a row that left the viewport in between
    /// would end up holding a decoder acquired after it gave everything back,
    /// with no loan left to reclaim it by. The same leak the post page's
    /// accumulation battery caught, arriving here by a different door.
    private func prewarm(_ candidate: Candidate) {
        for clip in candidate.cell.clipsToPrewarm() {
            guard !pool.hasPlayer(in: clip.surface) else { continue }
            let id = candidate.id
            Task { [weak self] in
                await self?.pool.prewarm(clip.url, in: clip.surface)
                guard let self, self.loans[id] != nil else {
                    self?.pool.stop(clip.surface)
                    return
                }
            }
        }
    }

    /// Forgets a loan whose player is gone, without touching the cell or the
    /// pool: there is no playback to end, only bookkeeping to correct.
    private func releaseStaleLoan(id: PostID) {
        #if DEBUG
        if CarouselPlaybackAudit.isEnabled {
            CarouselPlaybackAudit.trace("grid released stale loan \(id.rawValue)")
        }
        #endif
        startTasks.removeValue(forKey: id)?.cancel()
        loans[id]?.onReuse = nil
        loans[id] = nil
        playingURLs[id] = nil
        uncappedIDs.remove(id)
    }

    private func stop(id: PostID, cell: any GridPlaybackCell) {
        // A hosted surface is released here rather than kept alive: playback is
        // ending anyway, so the layer teardown is invisible.
        if let hosted = hostedSurfaces.removeValue(forKey: id) {
            pool.stop(hosted)
            hosted.removeFromSuperview()
            onHostedSurfaceReleased?(id)
        }
        #if DEBUG
        Self.logTransition("stop ", id, count: loans.count - 1)
        #endif
        startTasks.removeValue(forKey: id)?.cancel()
        // ⚠️ EVERY surface the row holds, not just the watched one.
        //
        // A loan is per POST, and a row with a collection can be holding a
        // paused clip on a page the viewer left. Stopping `loadedVideoRenderView`
        // alone released the loan while those players stayed bound — untracked,
        // uncounted, and impossible to reclaim, because nothing was left that
        // knew about them.
        for surface in cell.retainedPlaybackSurfaces {
            pool.stop(surface)
        }
        for surface in cell.releaseRetainedClips() {
            pool.stop(surface)
        }
        cell.endVideoPreview()
        cell.onReuse = nil
        loans[id] = nil
        playingURLs[id] = nil
        uncappedIDs.remove(id)
    }

    #if DEBUG
    /// Timestamped start/stop trace under `-grid-playback-log`. Timestamps are
    /// what show that reconciles land DURING a drag rather than only after it,
    /// so the line is deliberately cheap enough to leave on while scrolling.
    static let tracesTransitions = ProcessInfo.processInfo.arguments.contains("-grid-playback-log")

    static func logPool(_ count: Int, handoff: PostID?) {
        guard tracesTransitions else { return }
        print(String(format: "[grid-pool] %.3f slots=%d handoff=%@",
                     CACurrentMediaTime(), count, handoff?.rawValue ?? "-"))
    }

    /// The chosen set at the last reconcile, so the ranking is reported when it
    /// CHANGES rather than on every tick.
    private var lastLoggedChoice: Set<PostID>?

    /// Under `-grid-playback-log`: the full ranking, printed at each moment the
    /// selection changes.
    ///
    /// The reconcile runs ~30 times a second during a scroll and the answer is
    /// the same almost every time, so logging unconditionally buries the events
    /// that matter under its own noise. Printing on change gives one block per
    /// handover — which is exactly the claim worth checking: that the nearest
    /// `maxConcurrent` to the viewport centre are the ones playing, and that
    /// rows falling out of that window stop.
    private func logRankingIfChanged(_ ranked: [Candidate], chosen: Set<PostID>) {
        guard Self.tracesTransitions, chosen != lastLoggedChoice else { return }
        lastLoggedChoice = chosen
        let line = ranked.map { candidate in
            "\(chosen.contains(candidate.id) ? "▶" : "·")\(candidate.id.rawValue)"
                + "@\(Int(candidate.distanceFromCentre))"
        }.joined(separator: " ")
        print(String(format: "[grid-rank] %.3f cap=%d %@",
                     CACurrentMediaTime(), maxConcurrent, line))
    }

    static func logTransition(_ verb: String, _ id: PostID, count: Int) {
        guard tracesTransitions else { return }
        print(String(format: "[grid-playback] %.3f %@ %@ (playing=%d)",
                     CACurrentMediaTime(), verb, id.rawValue, count))
    }

    /// Prints the rung each playing tile settled on. Direct evidence that the
    /// cap bites: `preferred` is the ceiling asked for, `indicated` the variant
    /// AVFoundation actually chose. Progressive assets report nothing — they
    /// have no ladder to select from, so the cap is a no-op for them, which is
    /// itself worth seeing rather than guessing at.
    public func logPlaybackDiagnostics() {
        guard !loans.isEmpty else {
            print("[grid-playback] nothing playing")
            return
        }
        for (id, cell) in loans.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let renderView = cell.loadedVideoRenderView else { continue }
            if let report = pool.debugBitRateReport(in: renderView) {
                print(String(
                    format: "[grid-playback] %@ preferred=%.0f indicated=%.0f observed=%.0f",
                    id.rawValue, report.preferred, report.indicated, report.observed
                ))
            } else {
                print("[grid-playback] \(id.rawValue) no access log (progressive asset)")
            }
        }
    }

    var playingIDs: Set<PostID> { Set(loans.keys) }

    /// Awaits the in-flight `play` tasks, so a test can act on playback that is
    /// actually running rather than merely requested. `start` dispatches into a
    /// `Task`, so without this the pool has no active player yet and anything
    /// keyed on one silently no-ops — passing for the wrong reason.
    func debugAwaitStarts() async {
        for task in startTasks.values { await task.value }
    }
    var uncapped: Set<PostID> { uncappedIDs }

    /// Awaits every in-flight `play`, so a test can assert against attached
    /// players without polling or sleeping.
    func awaitPendingStarts() async {
        let tasks = startTasks.values
        startTasks.removeAll()
        for task in tasks { await task.value }
    }
    #endif
}
