import CoreModels
import Foundation
import MediaPlayback

/// ⚠️ ONE CONTRACT FOR EVERY MEDIA TILE (epic #1269): a tile's part in a
/// zoom flight, said once for every grid that drives its tiles with this
/// coordinator — For You's page and the sound sheet's rows alike. A host
/// supplies what only it knows (the tile's cell and the clip it plays); the
/// rules are here.
public extension GridVideoPlaybackCoordinator {
    /// The tile's live surface for a take-off: the card joins the tile's own
    /// playback, so frame 0 of the flight is the frame the tile was showing.
    ///
    /// ⚠️ NIL ASKS FOR A PLAYER rather than accepting the still: the flight
    /// asks again every frame, so a start kicked here is picked up by the
    /// next ask (`demandFlightPlayback`) — the difference between a hero that
    /// shows video 100ms in and one that shows a poster all the way.
    func tileFlightSurface(for id: PostID, url: URL, cell: (any GridPlaybackCell)?) -> VideoRenderView? {
        let made = makeAttachedSurface(for: id, url: url)
        if made == nil, let cell { demandFlightPlayback(of: id, url: url, in: cell) }
        return made
    }

    /// A close onto the same post: the tile takes the surface the card flew,
    /// so it CONTINUES the playhead rather than starting its clip again.
    /// Answers whether the tile took a playback. The host reveals the cell
    /// first — the surface must land in a drawing hierarchy.
    @discardableResult
    func adoptTileLanding(
        _ view: VideoRenderView, for id: PostID, url: URL, cell: any GridPlaybackCell
    ) -> Bool {
        if VideoRenderFlags.usesSampleBufferLayer {
            // The card's surface is one of several showing this playback: the
            // tile gets its OWN surface, primed with the current frame, and
            // takes the pool loan. Nothing is re-parented.
            return adoptAttachedSurface(for: id, url: url, cell: cell, drawnBy: view)
        }
        adoptLiveSurface(view, for: id, url: url, cell: cell)
        return true
    }

    /// Whether the tile a close lands on is drawing what it should yet — its
    /// clip when it plays one, its still otherwise — so the card is never
    /// taken away from over an empty tile.
    func isTileLandingReady(
        for id: PostID, expectsVideo: Bool, cell: (any GridPlaybackCell)?, hasThumbnail: Bool
    ) -> Bool {
        if expectsVideo { return isSurfaceRendering(for: id) }
        guard let cell, hasThumbnail else { return true }
        return cell.renderedCover != nil
    }
}
