import CoreModels
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The sound sheet's video tiles playing on their own, muted, as every other
/// grid's do (#884) — the sheet's screen and a pushed section's each own one.
///
/// Nothing of its own about WHAT plays: admission (half the media inside the
/// viewport), the distance from the viewport's vertical centre and the budget
/// are the shared ranking's (`GridAutoplayRanking`, #861), and the players are
/// `GridVideoPlaybackCoordinator`'s, on the app's one pool. What the sheet
/// adds is which tiles may be asked (`Item`: on screen, and not faint — see
/// `SoundSheetViewController.isRevealed`) and when the screen is the viewer's
/// (`setActive`).
///
/// ⚠️ **THE FEED BEHIND KEEPS ITS PLAYERS.** The sheet rises over a page that
/// goes on playing at every detent, on the same pool. So the tiles take what
/// the pool's capacity leaves after everyone else (`reserve`, measured at each
/// reconcile as the players bound to anything but these tiles), never more
/// than a mosaic's six: a seventh decoder starves one of the six already
/// playing (`VideoPlaybackController.capacity`).
@MainActor
final class SoundSheetAutoplay {
    /// The tiles one screen may hold at most: the sheet's three columns of
    /// equal 3:4 tiles are a mosaic.
    static let concurrentPlayers = GridAutoplayRanking.concurrentPlayers(isMosaic: true)

    /// A tile on screen that its screen may let play.
    struct Item {
        let tile: SoundSheetViewController.Tile
        let cell: SoundSheetTileCell
    }

    let playback: GridVideoPlaybackCoordinator
    private let pool: VideoPlaybackController
    private let imagePipeline: ImagePipeline
    /// The screen is the viewer's: on screen, not covered by a feed opened
    /// from a tile, not left for a pushed section.
    private(set) var isActive = false

    init(pool: VideoPlaybackController, imagePipeline: ImagePipeline) {
        self.pool = pool
        self.imagePipeline = imagePipeline
        playback = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: Self.concurrentPlayers)
    }

    /// The screen is (or is no longer) the viewer's. Inactive, every tile
    /// gives its player back now — the sheet going, a feed covering it, a
    /// section pushed over it.
    func setActive(_ active: Bool) {
        isActive = active
        playback.setSurfaceVisible(active)
    }

    /// A post opens from tile `id`: its clip is parked, paused at its
    /// playhead, for a close that pages on and comes home to it (#951).
    ///
    /// ⚠️ THE TAPPED TILE KEEPS PLAYING (#1280, epic #1269): the flight
    /// carries its player now — the card takes off on the tile's own surface
    /// (`tileFlightSurface`) and a same-post close hands it back
    /// (`adoptTileLanding`) — so it is no longer stopped here; the handoff
    /// scope lets the other tiles go, one hop at a time, and keeps this one
    /// out of the reconcile for the trip.
    func beginOpen(of id: PostID) {
        playback.focus(id)
        playback.beginHandoff(id, parkingReturn: true)
    }

    /// The feed opened from a tile is gone, whichever way: the scope ends, and
    /// with it a return player the close did not land. After the landing,
    /// which claimed the one it used; after `setActive`, whose answer it keeps
    /// — a screen that is not the viewer's goes back to playing nothing.
    func endOpen() {
        guard playback.isHandingOff else { return }
        playback.endHandoff()
        // The claim ends with the round trip — see `beginOpen`.
        playback.focus(nil)
        if !isActive { playback.setSurfaceVisible(false) }
    }

    /// Reconciles the tiles' players against `items`, measured in
    /// `collectionView` — the visible tiles that may play. Cheap and
    /// idempotent: called as the posts scroll, as a row scrolls sideways, as
    /// the reveal moves, as a cover lands.
    func reconcile(_ items: [Item], in collectionView: UICollectionView, allowingStarts: Bool = true) {
        // What the sheet shows: under the bars' insets is behind their glass.
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var seen = Set<PostID>()
        let tiles = items.compactMap { item -> GridAutoplayRanking.Tile? in
            guard item.tile.isLoaded, let url = item.tile.videoURL,
                  hasCover(item), seen.insert(item.tile.postID).inserted
            else { return nil }
            return .init(
                id: item.tile.postID, url: url, cell: item.cell,
                // A row's cell lives in the row's own scroll view: converted,
                // never its `frame`.
                mediaFrame: item.cell.convert(item.cell.videoMediaRect, to: collectionView),
                isPaused: false
            )
        }
        playback.maxConcurrent = GridAutoplayRanking.playerBudget(
            concurrentPlayers: Self.concurrentPlayers,
            poolCapacity: pool.capacity,
            reserve: reserve(besides: collectionView)
        )
        let candidates = GridAutoplayRanking.candidates(from: tiles, in: viewport, reference: .verticalCentre)
        playback.update(candidates: candidates, allowingStarts: allowingStarts)    }

    /// The players bound to anything but this screen's tiles — the page
    /// behind the sheet, first of all. Every tile on screen counts as its
    /// own, a faint one included (it is about to give its player back); one
    /// that left gave it back as it went (`stop`).
    private func reserve(besides collectionView: UICollectionView) -> Int {
        let own = collectionView.visibleCells.filter { cell in
            guard let surface = (cell as? SoundSheetTileCell)?.loadedVideoRenderView else { return false }
            return pool.hasPlayer(in: surface)
        }.count
        return max(0, pool.activePlayerCount - own)
    }

    /// A tile left the screen: its player goes back now, whatever the scroll
    /// is doing, or the pool starves.
    func stop(_ cell: UICollectionViewCell) {
        guard let tile = cell as? SoundSheetTileCell else { return }
        playback.stop(cell: tile)
    }

    /// A surface with no cover behind it draws black until its first frame:
    /// a tile plays once its poster is up (the galleries' rule).
    private func hasCover(_ item: Item) -> Bool {
        guard let thumbnail = item.tile.thumbnailURL else { return true }
        if item.cell.renderedCover != nil { return true }
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        item.cell.applyCover(cached)
        return true
    }
}
