import CoreModels
import QuartzCore
import UIKit

/// The autoplay ranking every playing grid shares (#861): which measured items
/// the viewport admits, how far each is from where the surface is read, how
/// many players the surface may hold, and whether a scroll is too fast to
/// start any.
///
/// The surfaces feeding `GridVideoPlaybackCoordinator`: the For You grid
/// (`ForYouGridAutoplayDriver` — which the profile's pages are too, #1273)
/// and the For You rails' Following row
/// (`ForYouRailsView`). They used to carry three copies of these rules; what
/// genuinely differs between them is passed in, never decided here:
///
/// - the REFERENCE a distance is measured from — the vertical centre for a
///   grid that scrolls up and down, the left edge for a row ranked left to
///   right;
/// - the budget NUMBERS — the shape's player count, the pool's capacity and
///   what a lead beside the surface already holds;
/// - the VELOCITY SOURCE — sampled from offsets on For You (the pan gesture
///   reports zero once the finger lifts), read off the pan gesture on the
///   profile.
///
/// Pure: it owns no player, measures no view and calls nothing. Each surface
/// still measures its own items (cover gates and all) and makes every
/// coordinator call itself, in its own order; the coordinator still sorts the
/// candidates and keeps the nearest `maxConcurrent`.
public enum GridAutoplayRanking {
    // MARK: - Distance

    /// What a candidate's distance — the coordinator's ranking key, lower
    /// wins — is measured from.
    public enum Reference: Sendable, Equatable {
        /// The viewport's vertical centre to the media's: a vertical grid,
        /// where the item the eye rests on is the one in the middle.
        case verticalCentre
        /// The viewport's left edge (`minX`) to the media's: a horizontal row,
        /// ranked left to right as the rails always were, so the card nearest
        /// that edge keeps its player when the budget is short. The LEFT edge
        /// in every layout direction, right-to-left included.
        case minXEdge
    }

    /// How far `media` is from `reference` in `viewport`, in points, never
    /// negative. Both rects in the same coordinate space.
    public static func distance(
        of media: CGRect, in viewport: CGRect, from reference: Reference
    ) -> CGFloat {
        switch reference {
        case .verticalCentre: abs(media.midY - viewport.midY)
        case .minXEdge: abs(media.minX - viewport.minX)
        }
    }

    // MARK: - Candidates

    /// One visible item that holds a clip and has a face — everything its
    /// surface measured about it, before the viewport has had its say.
    public struct Tile {
        public let id: PostID
        public let url: URL
        public let cell: any GridPlaybackCell
        /// The cell's MEDIA in the viewport's coordinate space — each shape
        /// locates it for itself (`videoMediaRect`).
        public let mediaFrame: CGRect
        /// Held but not advancing (see `GridVideoPlaybackCoordinator
        /// .Candidate.isPaused`). Required, so no surface can forget it.
        public let isPaused: Bool

        public init(
            id: PostID, url: URL, cell: any GridPlaybackCell,
            mediaFrame: CGRect, isPaused: Bool
        ) {
            self.id = id
            self.url = url
            self.cell = cell
            self.mediaFrame = mediaFrame
            self.isPaused = isPaused
        }
    }

    /// The tiles the viewport admits, as coordinator candidates, in the order
    /// they came. At least half of a tile's media must be inside the viewport
    /// (`GridPlaybackVisibility.autoplays`); a null viewport admits nothing.
    /// Each candidate's distance is measured from `reference`.
    public static func candidates(
        from tiles: [Tile], in viewport: CGRect, reference: Reference
    ) -> [GridVideoPlaybackCoordinator.Candidate] {
        tiles.compactMap { tile in
            guard GridPlaybackVisibility.autoplays(tile.mediaFrame, in: viewport) else { return nil }
            return .init(
                id: tile.id, url: tile.url, cell: tile.cell,
                distanceFromCentre: distance(of: tile.mediaFrame, in: viewport, from: reference),
                isPaused: tile.isPaused
            )
        }
    }

    // MARK: - Budget

    /// Players for a mosaic of bricks.
    public static let mosaicPlayers = 6
    /// Players for a timeline of rows: a column fits fewer previews on screen
    /// at once, so a sixth slot would go to a row well outside the viewport —
    /// and the idle-player cache is six, which the pages share.
    public static let timelinePlayers = 5

    /// The shape's player count. Which shapes count as a mosaic is the
    /// surface's call — For You's Discover plays as a timeline, the profile's
    /// as a mosaic.
    public static func concurrentPlayers(isMosaic: Bool) -> Int {
        isMosaic ? mosaicPlayers : timelinePlayers
    }

    /// What a surface may hold when a lead draws on the same pool: what the
    /// pool's capacity leaves after the lead's `reserve`, never more than the
    /// shape's `concurrentPlayers`, never below zero.
    public static func playerBudget(concurrentPlayers: Int, poolCapacity: Int, reserve: Int) -> Int {
        max(0, min(concurrentPlayers, poolCapacity - reserve))
    }

    /// How many players a surface holds once the coordinator has kept the
    /// nearest `budget` of `candidateCount` — what a lead reports as the
    /// reserve the surface beside it subtracts.
    public static func playersHeld(candidateCount: Int, budget: Int) -> Int {
        min(candidateCount, budget)
    }

    // MARK: - Fling gate

    /// Points per second past which a *new* player is not started.
    ///
    /// The reconcile still runs at speed — items that leave stop immediately —
    /// but nothing starts during a hard fling. At 4000 pt/s a brick crosses the
    /// viewport in about a fifth of a second, so starting it means an item
    /// allocation and a segment fetch for something already gone. Dragging by
    /// hand rarely exceeds ~1500 pt/s, so items playing while the finger is
    /// still moving sit well inside this.
    public static let maximumStartVelocity: CGFloat = 2200

    /// The speed between two offset samples `elapsed` seconds apart, in points
    /// per second, never negative; zero when no time has passed.
    public static func sampledSpeed(
        from previousOffset: CGFloat, to offset: CGFloat, over elapsed: CFTimeInterval
    ) -> CGFloat {
        elapsed > 0 ? abs(offset - previousOffset) / CGFloat(elapsed) : 0
    }

    /// Whether a scroll at `velocity` (either sign) may start players: at or
    /// under `maximum`.
    public static func allowsStarts(
        atVelocity velocity: CGFloat, maximum: CGFloat = maximumStartVelocity
    ) -> Bool {
        abs(velocity) <= maximum
    }
}
