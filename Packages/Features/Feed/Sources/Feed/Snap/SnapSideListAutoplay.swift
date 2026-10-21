import CoreModels
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The side list's video tiles playing on their own, muted, as every grid's
/// do (#1509, the owner's choice) — while the list is open, and only then.
///
/// Nothing of its own about WHAT plays: admission, distance and budget are
/// the shared ranking's (`GridAutoplayRanking`), the players
/// `GridVideoPlaybackCoordinator`'s on the app's one pool — the sound sheet's
/// arrangement (`SoundSheetAutoplay`). Power Saving and Reduce Motion stop
/// them as everywhere (`GridVideoPlaybackCoordinator.allowsAutoplay`).
///
/// ⚠️ **THE CARD KEEPS ITS PLAYER AND ITS SOUND.** The page on the left goes
/// on playing on the same pool, so the tiles take what the pool's capacity
/// leaves after everyone else (`reserve`), never more than a column's budget.
@MainActor
final class SnapSideListAutoplay {
    /// One column of tiles: a timeline's budget, not a mosaic's.
    static let concurrentPlayers = GridAutoplayRanking.concurrentPlayers(isMosaic: false)

    /// A tile on screen and the cell drawing it.
    struct Item {
        let post: GalleryPost
        let cell: PostGridTileCell
    }

    let playback: GridVideoPlaybackCoordinator
    private let pool: VideoPlaybackController
    private let imagePipeline: ImagePipeline
    /// The list is open.
    private(set) var isActive = false

    init(pool: VideoPlaybackController, imagePipeline: ImagePipeline) {
        self.pool = pool
        self.imagePipeline = imagePipeline
        playback = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: Self.concurrentPlayers)
        // ⚠️ THE TILES NEVER SHARE THE CARD'S PLAYER (#1547): the post on
        // show's tile joined it, capped it to a tile's rung — the card's
        // picture jumped as the list opened, and again as it closed — and
        // could resume a clip the viewer paused. A tile has its own.
        playback.playbackScopeTag = "side-list"
    }

    /// The post on show's tile plays first (#1547, the owner: the card,
    /// then its tile, then the rest the pool allows): a claim on the
    /// budget whatever its place in the list.
    func focus(_ id: PostID?) {
        focusedPost = id
        if isActive { playback.focus(id) }
    }

    /// The post on show, claimed while the list is open.
    private var focusedPost: PostID?

    /// Open (the tiles may play) or closed (every tile gives its player back
    /// now).
    func setActive(_ active: Bool) {
        isActive = active
        // ⚠️ THE CLAIM ONLY WHILE OPEN: a focused post is never stopped, so a
        // claim kept past the close would leave its tile playing unseen.
        playback.focus(active ? focusedPost : nil)
        playback.setSurfaceVisible(active)
    }

    /// Reconciles the tiles' players against `items`, measured in
    /// `collectionView`. Cheap and idempotent: called as the list scrolls,
    /// shows, opens and as a cover lands.
    func reconcile(_ items: [Item], in collectionView: UICollectionView) {
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var seen = Set<PostID>()
        let tiles = items.compactMap { item -> GridAutoplayRanking.Tile? in
            guard item.post.kind == .video, let url = item.post.videoURL,
                  hasCover(item), seen.insert(item.post.id).inserted
            else { return nil }
            return .init(
                id: item.post.id, url: url, cell: item.cell,
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
        playback.update(candidates: candidates)
    }

    /// The players bound to anything but this list's tiles — the card first.
    private func reserve(besides collectionView: UICollectionView) -> Int {
        let own = collectionView.visibleCells.filter { cell in
            guard let surface = (cell as? any GridPlaybackCell)?.loadedVideoRenderView else { return false }
            return pool.hasPlayer(in: surface)
        }.count
        return max(0, pool.activePlayerCount - own)
    }

    /// A tile left the screen: its player goes back now.
    func stop(_ cell: UICollectionViewCell) {
        guard let tile = cell as? any GridPlaybackCell else { return }
        playback.stop(cell: tile)
    }

    /// A tile plays once its poster is up (the galleries' rule).
    private func hasCover(_ item: Item) -> Bool {
        guard let thumbnail = item.post.thumbnailURL else { return true }
        if item.cell.renderedCover != nil { return true }
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        item.cell.applyCover(cached)
        return true
    }
}
