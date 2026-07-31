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
        public let cell: PostGridTileCell
        /// Distance from the viewport's vertical centre, in points. Lower wins;
        /// the caller measures it because only it knows the scroll geometry.
        public let distanceFromCentre: CGFloat

        public init(id: PostID, url: URL, cell: PostGridTileCell, distanceFromCentre: CGFloat) {
            self.id = id
            self.url = url
            self.cell = cell
            self.distanceFromCentre = distanceFromCentre
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
    /// Playing posts → the cell their player is bound to.
    private var playing: [PostID: PostGridTileCell] = [:]
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

        for (id, cell) in playing where !chosenIDs.contains(id) && id != handoffID {
            stop(id: id, cell: cell)
        }
        guard allowingStarts else { return }
        for candidate in chosen where playing[candidate.id] == nil {
            start(candidate)
        }
        #if DEBUG
        Self.logPool(playing.count, handoff: handoffID)
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
    public func beginHandoff(_ id: PostID) {
        handoffID = id
        isSurfaceVisible = false
        for (playingID, cell) in playing where playingID != id {
            stop(id: playingID, cell: cell)
        }
        #if DEBUG
        Self.logPool(playing.count, handoff: handoffID)
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
            if let surface = playing[id]?.loadedVideoRenderView {
                surface.debugLabel = "tile"
                surface.debugTracksFlight = true
                print(String(format: "[zoom-live] %.3f probe armed on tile ready=%@",
                             CACurrentMediaTime(), surface.isReadyForDisplay ? "true" : "false"))
            } else {
                print(String(format: "[zoom-live] %.3f probe NOT armed — no live surface for %@ (playing: %@)",
                             CACurrentMediaTime(), String(describing: id),
                             playing.keys.map { String(describing: $0) }.sorted().joined(separator: ",")))
            }
        }
        #endif
    }

    /// Closes the handoff and retires anything left parked. The caller
    /// reconciles immediately after, and that single reconcile is what restores
    /// the full slate of slots — deterministically, from the visible set, with
    /// no residue from the flight.
    public func endHandoff() {
        handoffID = nil
        isSurfaceVisible = true
        pool.discardParkedPlayback()
        releaseFinishedFlightSurfaces()
        #if DEBUG
        Self.logPool(playing.count, handoff: nil)
        #endif
    }

    /// Whether a handoff is open — the transition's own guard against
    /// re-entrancy.
    public var isHandingOff: Bool { handoffID != nil }

    /// Stops whatever is playing in `cell` — the collection view recycled it.
    public func stop(cell: PostGridTileCell) {
        guard let id = playing.first(where: { $0.value === cell })?.key else { return }
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
        for (id, cell) in playing where id != kept {
            stop(id: id, cell: cell)
        }
    }

    // MARK: - Hero handoff

    /// Whether `id` is playing right now — the source asks before deciding
    /// whether a flight can carry live video at all.
    public func isPlaying(_ id: PostID) -> Bool { playing[id] != nil }


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
        guard let cell = playing[id], let renderView = cell.loadedVideoRenderView,
              pool.parkPlayback(from: renderView, keepingSurfaceAttached: true)
        else { return nil }
        let donated = cell.donateVideoRenderView()
        cell.onReuse = nil
        playing[id] = nil
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
        // Sweep before minting, not only at `endHandoff`. A flight can end
        // without the scope closing cleanly, and this way each new flight
        // cannot inherit more than the previous one's leftovers — the count is
        // self-limiting rather than dependent on a teardown path being hit.
        releaseFinishedFlightSurfaces()
        guard playing[id] != nil else { return nil }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "card"
        view.debugTracksFlight = true
        #endif
        guard pool.attachSurface(view, to: url) else { return nil }
        flightSurfaces.add(view)
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
    public func adoptAttachedSurface(for id: PostID, url: URL, cell: PostGridTileCell) -> Bool {
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
        view.isHidden = false
        pool.setPeakBitRate(Self.tileBitRateCap, for: url)
        playing[id] = cell
        uncappedIDs.remove(id)
        cell.onReuse = { [weak self] in
            guard let self, let cell = playing[id] else { return }
            stop(id: id, cell: cell)
        }
        #if DEBUG
        Self.logPool(playing.count, handoff: handoffID)
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
            pool.detachSurface(view)
            flightSurfaces.remove(view)
        }
    }

    @discardableResult
    public func parkForHandoff(_ id: PostID) -> Bool {
        guard let cell = playing[id], let renderView = cell.loadedVideoRenderView else { return false }
        let parked = pool.parkPlayback(from: renderView)
        // The tile no longer owns a player; drop the bookkeeping so a reconcile
        // can hand it a fresh one when the viewer comes back.
        if parked {
            cell.endVideoPreview()
            cell.onReuse = nil
            playing[id] = nil
            uncappedIDs.remove(id)
        }
        return parked
    }

    /// Installs the flight card's live surface on the landing tile and claims
    /// the player parked behind it, so the tile keeps rendering the frame the
    /// card was showing.
    public func adoptLiveSurface(_ view: VideoRenderView, for id: PostID, url: URL, cell: PostGridTileCell) {
        cell.adoptVideoRenderView(view)
        cell.beginVideoPreview()
        guard pool.unparkPlayback(to: view, mediaURL: url) else { return }
        pool.setPeakBitRate(Self.tileBitRateCap, in: view)
        playing[id] = cell
        cell.onReuse = { [weak self] in
            guard let self, let cell = playing[id] else { return }
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
        _ view: VideoRenderView, for id: PostID, url: URL, cell: PostGridTileCell
    ) -> Bool {
        guard pool.unparkPlayback(to: view, mediaURL: url) else { return false }
        pool.setPeakBitRate(Self.tileBitRateCap, in: view)
        hostedSurfaces[id] = view
        playing[id] = cell
        cell.onReuse = { [weak self] in
            guard let self, let cell = playing[id] else { return }
            stop(id: id, cell: cell)
        }
        #if DEBUG
        Self.logPool(playing.count, handoff: handoffID)
        #endif
        return true
    }

    /// The hosted surface for `id`, if its video is rendering outside the cell.
    public func hostedSurface(for id: PostID) -> VideoRenderView? { hostedSurfaces[id] }

    /// Whether the tile for `id` has a surface with a decoded frame on screen.
    /// False while its layer is still acquiring — the window a landing card is
    /// held across.
    public func isSurfaceRendering(for id: PostID) -> Bool {
        if let hosted = hostedSurfaces[id] { return hosted.isReadyForDisplay && !hosted.isHidden }
        guard let cell = playing[id], let view = cell.loadedVideoRenderView else { return false }
        return view.isReadyForDisplay && !view.isHidden
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
        for (id, cell) in playing { stop(id: id, cell: cell) }
    }

    // MARK: - Internals

    private func start(_ candidate: Candidate) {
        #if DEBUG
        Self.logTransition("start", candidate.id, count: playing.count + 1)
        #endif
        playing[candidate.id] = candidate.cell
        candidate.cell.beginVideoPreview()
        let renderView = candidate.cell.makeVideoRenderViewIfNeeded()
        let id = candidate.id
        candidate.cell.onReuse = { [weak self] in
            guard let self, let cell = playing[id] else { return }
            stop(id: id, cell: cell)
        }
        let url = candidate.url
        // A tile that is already flying full screen keeps its lifted cap.
        let cap = uncappedIDs.contains(id) ? Self.uncapped : Self.tileBitRateCap
        startTasks[id] = Task { [pool] in
            await pool.play(url, in: renderView, peakBitRate: cap)
        }
    }

    private func stop(id: PostID, cell: PostGridTileCell) {
        // A hosted surface is released here rather than kept alive: playback is
        // ending anyway, so the layer teardown is invisible.
        if let hosted = hostedSurfaces.removeValue(forKey: id) {
            pool.stop(hosted)
            hosted.removeFromSuperview()
            onHostedSurfaceReleased?(id)
        }
        #if DEBUG
        Self.logTransition("stop ", id, count: playing.count - 1)
        #endif
        startTasks.removeValue(forKey: id)?.cancel()
        if let renderView = cell.loadedVideoRenderView {
            pool.stop(renderView)
        }
        cell.endVideoPreview()
        cell.onReuse = nil
        playing[id] = nil
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
        guard !playing.isEmpty else {
            print("[grid-playback] nothing playing")
            return
        }
        for (id, cell) in playing.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
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

    var playingIDs: Set<PostID> { Set(playing.keys) }

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
