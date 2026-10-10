import CoreModels
import PostGrid
import QuartzCore
import UIKit

/// The For You grid's autoplay decisions, apart from the view that measures
/// them (#858).
///
/// `ForYouGridPage` measures — which cells are realized, what each one holds,
/// whether its cover has arrived, which post is in the air — and hands the
/// answers here as plain values: media frames, a viewport, offsets and a clock.
/// What comes back is plain too: the candidates to rank, the number of players
/// the page may hold, and whether a reconcile may start anything.
///
/// It owns no player and calls nothing. Every call to
/// `GridVideoPlaybackCoordinator` stays on the page, in the order it always
/// had, and so does the hero handoff seam; the Power Saving and idle-calm gates
/// and the chosen set already live in the coordinator.
@MainActor
struct ForYouGridAutoplayDriver {
    // MARK: - Budget

    /// How many videos may play at once, per shape.
    ///
    /// Both surfaces rank candidates by distance from the viewport centre and
    /// keep the nearest N; N is the only thing that differs. Five for a
    /// timeline rather than the mosaic's six because a column fits fewer
    /// previews on screen at once, so the sixth slot would go to a row well
    /// outside the viewport — and the idle-player cache is six, which the two
    /// pages share. Discover counts as a timeline: a chunk on screen is a few
    /// tiles among cards, and its tiles compete on the same distance.
    static func concurrentPlayers(for style: ForYouGridPage.Style) -> Int {
        style == .grid ? 6 : 5
    }

    /// What the page may hold when a lead draws on the same pool: what the
    /// pool's budget leaves after the lead's own players, never more than the
    /// shape's number, never below zero. See `ForYouGridPage.playerReserve`.
    static func playerBudget(
        for style: ForYouGridPage.Style, poolCapacity: Int, reserve: Int
    ) -> Int {
        max(0, min(concurrentPlayers(for: style), poolCapacity - reserve))
    }

    // MARK: - Candidates

    /// One visible item that holds a clip and has a face — everything the page
    /// measured about it, before the viewport has had its say.
    struct Tile {
        let id: PostID
        let url: URL
        let cell: any GridPlaybackCell
        /// The cell's MEDIA in the collection view's coordinates — each shape
        /// locates it for itself (`videoMediaRect`).
        let mediaFrame: CGRect
        let isAdvancing: Bool
    }

    /// Held versus ADVANCING. A row keeps its player while the viewer is
    /// on another page of the same collection — the clip is still on
    /// screen there, peeking, and stopping it would put that page's
    /// thumbnail back.
    /// ⚠️ A SINGLE ATTACHMENT IS ALWAYS ON ITS OWN PAGE.
    ///
    /// `currentPageVideoURL` answers for a CAROUSEL and is nil for a row
    /// showing one video — so comparing it to the held URL said "not
    /// advancing" for every single-video row in the feed, and the
    /// coordinator dutifully started each one and paused it on its first
    /// frame. Reported as "the first frame is there but the media does
    /// not advance", with a recording that shows exactly that.
    ///
    /// The question only means anything for a collection: is the viewer
    /// on the clip's page, or on a photograph beside it.
    static func isAdvancing(showsCarousel: Bool, currentPageVideoURL: URL?, held: URL) -> Bool {
        !showsCarousel || currentPageVideoURL == held
    }

    /// The tiles the viewport admits, as coordinator candidates, in the order
    /// they came. Measured against the cell's MEDIA, which each shape locates
    /// for itself (`videoMediaRect`) — a tile's is its bounds, a row's is the
    /// preview box inside its card. At least half of it must be inside the
    /// viewport (`GridPlaybackVisibility.minimumVisibleFraction`), and the
    /// ranking distance is from the viewport's vertical centre.
    static func candidates(
        from tiles: [Tile], in viewport: CGRect
    ) -> [GridVideoPlaybackCoordinator.Candidate] {
        let centreY = viewport.midY
        return tiles.compactMap { tile in
            guard GridPlaybackVisibility.autoplays(tile.mediaFrame, in: viewport) else { return nil }
            return .init(
                id: tile.id, url: tile.url, cell: tile.cell,
                distanceFromCentre: abs(tile.mediaFrame.midY - centreY),
                isPaused: !tile.isAdvancing
            )
        }
    }

    // MARK: - During-scroll reconcile

    /// Reconcile cadence during a scroll, in seconds. ~30 Hz: fast enough that
    /// a tile is playing by the time the eye has settled on it, slow enough
    /// that the diff cost stays invisible next to the scroll itself.
    static let scrollReconcileInterval: CFTimeInterval = 1.0 / 30

    /// Points-per-second past which a *new* player is not started.
    ///
    /// The reconcile still runs at speed — tiles that leave stop immediately —
    /// but nothing starts during a hard fling. At 4000 pt/s a brick crosses the
    /// viewport in about a fifth of a second, so starting it means an item
    /// allocation and a segment fetch for something already gone. Dragging by
    /// hand rarely exceeds ~1500 pt/s, so the behaviour the request is about —
    /// tiles playing while the finger is still moving — sits well inside this.
    static let maximumStartVelocity: CGFloat = 2200

    /// Throttle state for the during-scroll autoplay reconcile.
    private var lastReconcileTime: CFTimeInterval = 0
    private var lastReconcileOffset: CGFloat = 0

    /// One scroll tick at `offset`, read at `now` (`CACurrentMediaTime` on the
    /// page). Nil while the tick is inside the throttle window; otherwise
    /// whether the reconcile it asks for may start players — `false` above
    /// `maximumStartVelocity`.
    mutating func scrollTick(offset: CGFloat, at now: CFTimeInterval) -> Bool? {
        let elapsed = now - lastReconcileTime
        guard elapsed >= Self.scrollReconcileInterval else { return nil }

        // Velocity from the sampling interval itself; `panGestureRecognizer
        // .velocity` reports zero once the finger lifts, which is exactly the
        // decelerating stretch this needs to measure.
        let velocity = elapsed > 0 ? abs(offset - lastReconcileOffset) / CGFloat(elapsed) : 0
        lastReconcileTime = now
        lastReconcileOffset = offset

        return velocity <= Self.maximumStartVelocity
    }
}
