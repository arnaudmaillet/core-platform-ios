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
/// arrangement (`SoundSheetAutoplay`). Low Power Mode and Reduce Motion stop
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

    /// ⚠️ THE POST ON SHOW'S TILE IS A CLONE OF THE CARD (#1581, the owner
    /// 2026-10-22): no player of its own — a second, passive surface on the
    /// card's player (`attachSurface(_:alongsideSurface:)`, resolved by the
    /// card's own surface, never by URL). One player, two pictures: the same
    /// frame, a pause, a scrub, the loop, everything at once. It holds no
    /// pool loan and sets no bit-rate cap — joining through `play()` did,
    /// and re-capped the card (#1547).
    func mirror(_ id: PostID?) {
        guard mirroredPost != id else { return }
        unmirror()
        mirroredPost = id
    }

    /// The card's surface for `id`, asked of the screen (nil: not a single
    /// clip, or no page yet).
    var cardSurface: ((PostID) -> VideoRenderView?)?

    /// The post whose tile mirrors the card, while the list is open.
    private(set) var mirroredPost: PostID?
    /// The tile's surface bound to the card's player now.
    private weak var mirrorSurface: VideoRenderView?
    private var mirrorRetry: DispatchWorkItem?

    /// The tile's surface comes off the card's player.
    private func unmirror() {
        mirrorRetry?.cancel()
        mirrorRetry = nil
        if let surface = mirrorSurface { pool.detachSurface(surface, reason: "side-list mirror") }
        mirrorSurface = nil
    }

    /// Binds the mirrored tile's surface to the card's player — again a
    /// moment later while the card has none yet (its page is activating).
    private func attachMirror(_ items: [Item]) {
        guard isActive, let id = mirroredPost, let item = items.first(where: { $0.post.id == id }),
              item.post.kind == .video else { return }
        let surface = item.cell.makeVideoRenderViewIfNeeded()
        guard mirrorSurface !== surface || !pool.hasPlayer(in: surface) else { return }
        // Already drawing the card's player — the tile's own one, handed to
        // the card (`handOver`): nothing to bind, nothing to flash.
        if let card = cardSurface?(id), !pool.hasPlayer(in: surface), pool.sharesPlayback(surface, with: card) {
            mirrorSurface = surface
            mirrorRetry?.cancel()
            mirrorRetry = nil
            return
        }
        if let old = mirrorSurface, old !== surface { pool.detachSurface(old, reason: "side-list mirror") }
        if let card = cardSurface?(id), pool.attachSurface(surface, alongsideSurface: card) {
            mirrorSurface = surface
            // Shown once it draws, the cover until then (the grids' reveal).
            surface.revealOnFirstFrame()
            mirrorRetry?.cancel()
            mirrorRetry = nil
            return
        }
        guard mirrorRetry == nil else { return }
        let retry = DispatchWorkItem { [weak self] in
            self?.mirrorRetry = nil
            self?.attachMirror(self?.lastItems ?? [])
        }
        mirrorRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: retry)
    }

    #if DEBUG
    /// Whether the mirrored tile draws the card's playback now. Tests.
    var mirrorsCard: Bool {
        guard let mirrorSurface, let id = mirroredPost, let card = cardSurface?(id) else { return false }
        return !pool.hasPlayer(in: mirrorSurface) && pool.sharesPlayback(mirrorSurface, with: card)
    }

    /// Whether the mirror stands at the card's playhead. Tests.
    func mirrorPlayheadMatchesCard(_ card: VideoRenderView) -> Bool {
        guard let mirrorSurface else { return false }
        return pool.sharesPlayback(mirrorSurface, with: card)
    }
    #endif

    /// The tiles last reconciled, for a retry.
    private var lastItems: [Item] = []

    /// Open (the tiles may play) or closed (every tile gives its player back
    /// now, and the mirror comes off the card).
    func setActive(_ active: Bool) {
        isActive = active
        if !active { unmirror() }
        playback.setSurfaceVisible(active)
    }

    /// Reconciles the tiles' players against `items`, measured in
    /// `collectionView`. Cheap and idempotent: called as the list scrolls,
    /// shows, opens and as a cover lands.
    func reconcile(_ items: [Item], in collectionView: UICollectionView) {
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var seen = Set<PostID>()
        lastItems = items
        let tiles = items.compactMap { item -> GridAutoplayRanking.Tile? in
            // The mirrored tile plays nothing of its own (#1581).
            guard item.post.id != mirroredPost || !isActive,
                  item.post.kind == .video, let url = item.post.videoURL,
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
        attachMirror(items)
    }

    /// The players bound to anything but this list's tiles — the card first.
    private func reserve(besides collectionView: UICollectionView) -> Int {
        let own = collectionView.visibleCells.filter { cell in
            guard let surface = (cell as? any GridPlaybackCell)?.loadedVideoRenderView else { return false }
            return pool.hasPlayer(in: surface)
        }.count
        return max(0, pool.activePlayerCount - own)
    }

    /// Hands `id`'s tile's own player over to whoever adopts its surface
    /// next (#1581: the page picked from the list), and returns that surface.
    func handOver(_ id: PostID) -> VideoRenderView? {
        playback.relinquish(id)
    }

    /// Where a tile's own clip is, in seconds.
    func playheadSeconds(in surface: VideoRenderView) -> Double? {
        pool.hasPlayer(in: surface) ? pool.playheadSeconds(in: surface) : nil
    }

    /// A tile left the screen: its player goes back now.
    func stop(_ cell: UICollectionViewCell) {
        guard let tile = cell as? any GridPlaybackCell else { return }
        // The mirror's surface is the card's playback: detached, never
        // stopped (#1581).
        if let surface = tile.loadedVideoRenderView, surface === mirrorSurface {
            unmirror()
            return
        }
        playback.stop(cell: tile)
    }

    /// A tile plays once its poster is up (the galleries' rule).
    private func hasCover(_ item: Item) -> Bool {
        guard let thumbnail = item.post.thumbnailURL else { return true }
        if item.cell.renderedCover != nil { return true }
        guard let cached = imagePipeline.cachedCover(for: thumbnail) else { return false }
        item.cell.applyCover(cached)
        return true
    }
}
