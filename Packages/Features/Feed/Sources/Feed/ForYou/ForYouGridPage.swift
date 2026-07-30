import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// One format page of the For You pager: a **real scrolling** collection view
/// over the shared `PostGrid` layouts.
///
/// This is where a discovery root parts company with the profile gallery.
/// `ProfileGalleryGridView` is deliberately non-scrolling and self-sizing,
/// because the profile's outer scroll view owns all vertical motion and one
/// fetch fills it. A root tab has no outer scroll view, pages indefinitely, and
/// must recycle cells — so it hosts the same pattern in an ordinary scrolling
/// collection view instead. The pattern and the cells are shared; the host is
/// not.
final class ForYouGridPage: UIView {
    /// The page's fixed shape, chosen by its format at init.
    enum Style {
        case grid
        case list
    }

    /// The tapped item's index into `posts`.
    var onItemTapped: ((Int) -> Void)?
    /// The page scrolled near its end and wants another page.
    var onNearEnd: (() -> Void)?
    var onRefresh: (() -> Void)?

    /// Display order — the mosaic's arrangement of `rawPosts`. What the cells,
    /// the hero, and a tile tap all read.
    private(set) var posts: [GalleryPost] = []
    /// The order the view model handed over, kept so an append can be
    /// recognised as one before arrangement permutes it.
    private var rawPosts: [GalleryPost] = []

    /// Mosaic pages steer autoplaying posts into the non-square bricks; list
    /// pages are a timeline, where order carries meaning and must not be
    /// rearranged for looks.
    private func arrange(_ posts: [GalleryPost], startingAt index: Int) -> [GalleryPost] {
        guard style == .grid else { return posts }
        return PostGridMosaic.arrangedForMotion(posts, startingAt: index)
    }

    private let imagePipeline: ImagePipeline
    /// Autoplay for the mosaic's video bricks. Absent on list pages — a
    /// timeline row is a reading surface, not a viewing one — and absent
    /// wherever the host didn't supply a player pool.
    private let playback: GridVideoPlaybackCoordinator?
    private let style: Style
    private let collectionView: UICollectionView
    private let statusLabel = UILabel()
    private let refreshControl = UIRefreshControl()
    private var showsSkeleton = false
    /// The post whose cell is standing in for a flight card and must stay
    /// invisible until the card lands. See `setHeroHidden`.
    private var heroHiddenPostID: PostID?
    /// The inset to hand back when a flight ends; non-nil means frozen.
    private var frozenContentInset: UIEdgeInsets?
    /// Suppresses prefetch while the page repositions itself.
    ///
    /// Pagination is a response to the VIEWER reaching the end, not to the code
    /// moving the content. Without this, the hero's staging scroll
    /// (`scrollPostIntoView`) reports as an ordinary scroll, asks for the next
    /// page, and the corpus re-sorts under the active ordering — so every tile
    /// reshuffles at the exact moment the flight is landing on one of them.
    /// Caught in-sim as the grid visibly rearranging just after the card set
    /// down on the right tile.
    private var isRepositioning = false
    /// Throttle state for the during-scroll autoplay reconcile.
    private var lastReconcileTime: CFTimeInterval = 0
    private var lastReconcileOffset: CGFloat = 0
    #if DEBUG
    private var hasScheduledDiagnostics = false
    #endif

    /// List pages show a column of placeholder cards; the mosaic shows two
    /// full 8-brick patterns — a scrolling page has a whole viewport to fill,
    /// where the profile's one pattern only had to reach the fold.
    private var skeletonCount: Int { style == .grid ? PostGridMosaic.patternLength * 2 : 6 }

    /// How close to the end a scroll gets before the next page is requested.
    private static let prefetchDistance: CGFloat = 800

    init(imagePipeline: ImagePipeline, style: Style, videoPlayback: VideoPlaybackController? = nil) {
        self.imagePipeline = imagePipeline
        playback = style == .grid ? videoPlayback.map { GridVideoPlaybackCoordinator(pool: $0) } : nil
        self.style = style
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: style == .grid ? PostGridMosaic.layout() : PostGridListLayout.layout()
        )
        super.init(frame: .zero)

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.register(PostGridTileCell.self, forCellWithReuseIdentifier: PostGridTileCell.reuseID)
        collectionView.register(PostGridListRowCell.self, forCellWithReuseIdentifier: PostGridListRowCell.reuseID)
        collectionView.register(
            PostGridSkeletonTileCell.self, forCellWithReuseIdentifier: PostGridSkeletonTileCell.reuseID
        )
        collectionView.register(
            PostGridSkeletonListCell.self, forCellWithReuseIdentifier: PostGridSkeletonListCell.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        refreshControl.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        collectionView.pin(to: self)

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.constrain(in: self) { parent in
            statusLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 120)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The content inset the pager's owner needs to clear with its tray — the
    /// page scrolls under it, so the last row must be reachable above it.
    var additionalBottomInset: CGFloat {
        get { collectionView.contentInset.bottom }
        set {
            collectionView.contentInset.bottom = newValue
            collectionView.verticalScrollIndicatorInsets.bottom = newValue
        }
    }

    func endRefreshing() {
        refreshControl.endRefreshing()
    }

    // MARK: - Autoplay

    /// Minimum fraction of a tile that must be inside the inset viewport before
    /// it may autoplay. A brick creeping in at the edge is not something the
    /// viewer is looking at, and starting it there spends a pool slot the
    /// centre of the screen wants.
    private static let minimumVisibleFraction: CGFloat = 0.5

    /// Reconciles autoplay against what is on screen now. Cheap and idempotent;
    /// call it whenever the visible set or the surface's visibility can have
    /// changed.
    ///
    /// `allowingStarts: false` still stops tiles that left, but starts nothing
    /// new — the mid-fling case, where anything started is gone before its first
    /// frame.
    func updateAutoplay(allowingStarts: Bool = true) {
        guard let playback else { return }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let centreY = viewport.midY
        let candidates = collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> GridVideoPlaybackCoordinator.Candidate? in
            guard !showsSkeleton, posts.indices.contains(indexPath.item) else { return nil }
            let post = posts[indexPath.item]
            // `autoplaysInGrid` is the shape rule: video, with a stream, and
            // not square. Square bricks stay still.
            guard post.autoplaysInGrid, let url = post.videoURL,
                  post.id != heroHiddenPostID, // its twin is in the air
                  let cell = collectionView.cellForItem(at: indexPath) as? PostGridTileCell
            else { return nil }

            let frame = cell.convert(cell.bounds, to: collectionView)
            let visible = frame.intersection(viewport)
            guard !visible.isNull, frame.height > 0,
                  (visible.height * visible.width) / (frame.height * frame.width)
                      >= Self.minimumVisibleFraction
            else { return nil }

            return .init(
                id: post.id, url: url, cell: cell,
                distanceFromCentre: abs(frame.midY - centreY)
            )
        }
        playback.update(candidates: candidates, allowingStarts: allowingStarts)
    }

    /// Tab left, feed presented over the grid, app backgrounded. `keeping`
    /// exempts the post whose player a hero flight is still carrying.
    func setAutoplayActive(_ active: Bool, keeping kept: PostID? = nil) {
        playback?.setSurfaceVisible(active, keeping: kept)
        if active {
            updateAutoplay()
            #if DEBUG
            schedulePlaybackDiagnosticsIfNeeded()
            #endif
        }
    }

    #if DEBUG
    /// `-grid-playback-log`: report which ladder rung each playing tile settled
    /// on, once the streams have had time to choose one.
    private func schedulePlaybackDiagnosticsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-grid-playback-log"),
              let playback, !hasScheduledDiagnostics
        else { return }
        hasScheduledDiagnostics = true
        // Sampled rather than taken once: a stream needs a few seconds to pick
        // a rung, and the first sample often lands before content has even
        // loaded. Three samples show the settle instead of guessing at it.
        for delay in [8.0, 16.0, 24.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                print("[grid-playback] --- t+\(Int(delay))s ---")
                self?.updateAutoplay()
                playback.logPlaybackDiagnostics()
            }
        }
    }
    #endif

    // MARK: - Hero handoff

    /// Hands a playing tile's player to the full-screen page the viewer just
    /// tapped into, so the video continues from where the tile had it rather
    /// than restarting.
    ///
    /// Called BEFORE the destination is built: the destination adopts by
    /// playing the same URL, and it plays uncapped, which is what lifts the
    /// tile's bit-rate cap. Returns whether anything was handed over.
    @discardableResult
    func parkPlaybackForHandoff(of postID: PostID) -> Bool {
        playback?.parkForHandoff(postID) ?? false
    }

    /// The destination never adopted the parked player — a cancelled flight, or
    /// a plain push. Retires it rather than leaving it decoding unseen.
    func discardPlaybackHandoff() {
        playback?.discardHandoff()
    }

    // MARK: - Hero geometry

    // What the zoom transition needs to fly a post's media: where it is, what
    // it looks like, and the ability to hide it while its twin is in the air.
    // All of it is asked of the *page* rather than of a cell, because cells are
    // recycled — the page resolves an id to whatever cell is showing it now, or
    // reports that none is.

    /// Everything a flight needs from a realized cell, resolved together so the
    /// rect, the cover and the style cannot describe different objects.
    struct Hero {
        let frame: CGRect
        let cover: UIImage?
        let style: PostGridFlightCard.Style
    }

    /// The post's flyable media in `space`, or nil when there is nothing to
    /// fly: no realized cell (scrolled out), or a text-only row, which has no
    /// media surface at all. The caller pushes plainly in that case.
    func hero(for postID: PostID, in space: UICoordinateSpace) -> Hero? {
        guard let cell = cell(for: postID), let appearance = heroAppearance(for: postID) else {
            return nil
        }
        let rect: CGRect = switch cell {
        // A brick IS its media, edge to edge; a row is a card of which the
        // media is one part, so fly that part.
        case let tile as PostGridTileCell: tile.bounds
        case let row as PostGridListRowCell: row.mediaHeroRect ?? .zero
        default: .zero
        }
        guard rect != .zero else { return nil }
        return Hero(frame: cell.convert(rect, to: space), cover: appearance.cover, style: appearance.style)
    }

    /// What the flight card should *look* like, without needing a coordinate
    /// space — the card is built before anyone knows the container, and asking
    /// for a frame there would mean inventing one.
    func heroAppearance(for postID: PostID) -> (cover: UIImage?, style: PostGridFlightCard.Style)? {
        switch cell(for: postID) {
        case let tile as PostGridTileCell:
            (cover: tile.renderedCover, style: .tile)
        case let row as PostGridListRowCell:
            row.mediaHeroRect == nil ? nil : (cover: row.renderedCover, style: .listMedia)
        default:
            nil
        }
    }

    /// Whether a realized cell for the post is currently within the viewport —
    /// the hero falls back to a centered collapse when it isn't.
    func isPostVisible(_ postID: PostID) -> Bool {
        guard let cell = cell(for: postID) else { return false }
        return collectionView.bounds.intersects(cell.frame)
    }

    /// Pins the content inset the grid is currently laid out with, so nothing
    /// can move the cells for the duration of a flight.
    ///
    /// **This is what makes a single landing measurement valid.** A pop animates
    /// the safe area — the navigation bar's height interpolates as the pop
    /// scrubs — and this collection view adds that safe area to its own inset,
    /// which drags `contentOffset` along with it. Measured: `adjustedContentInset
    /// .top` crept 102 → 106 across one drag and settled at 116, while the cell's
    /// frame *within the content* never moved at all. The card was therefore
    /// aimed at a tile that was still travelling, and landed ~21pt high.
    ///
    /// Freezing converts the inset from "safe area plus mine" to a constant
    /// equal to whatever it resolved to at freeze time, so the cells hold still
    /// through the whole transition and one rect is the truth. The caller freezes
    /// only after forcing a layout with the tab bar restored, so the value
    /// captured is the RESTING one — the same inset the grid will still have
    /// when the pop finishes, which is why thawing cannot move anything either.
    func beginHeroFreeze() {
        guard frozenContentInset == nil else { return }
        frozenContentInset = collectionView.contentInset
        let resolved = collectionView.adjustedContentInset
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = resolved
    }

    func endHeroFreeze() {
        guard let frozenContentInset else { return }
        self.frozenContentInset = nil
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.contentInset = frozenContentInset
    }

    /// Brings the post fully into view without animation, so a dismissal can
    /// land on a cell the viewer had scrolled past — or only half scrolled to.
    ///
    /// "Fully" is measured against the *inset* viewport, not the raw bounds: a
    /// cell tucked under the filter tray or the tab bar passes an intersection
    /// test while being somewhere no card should land. A cell already clear of
    /// the insets is left exactly where it is, so a dismissal to something the
    /// viewer can already see never jerks the grid under them.
    func scrollPostIntoView(_ postID: PostID) {
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let attributes = collectionView.layoutAttributesForItem(
                  at: IndexPath(item: index, section: 0)
              )
        else { return }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard !viewport.contains(attributes.frame) else { return }
        isRepositioning = true
        defer { isRepositioning = false }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false
        )
        // The rect the caller is about to read must reflect the new offset.
        collectionView.layoutIfNeeded()
    }

    /// Hides the real cell while its twin is flying.
    /// Hides the real cell while its twin is flying, and keeps it hidden.
    ///
    /// The flag lives on the PAGE, keyed by post, and is re-applied at every
    /// dequeue — it is not enough to set `isHidden` on the cell that happens to
    /// be realized now. Two things break that: a `reloadData` (a page landing
    /// mid-flight) hands back a fresh, VISIBLE cell, so the tile reappears
    /// under the card and the viewer sees it twice; and a recycled cell carries
    /// the stale `isHidden` to whatever index it is next used for, leaving an
    /// invisible tile somewhere else in the grid.
    func setHeroHidden(_ hidden: Bool, for postID: PostID) {
        heroHiddenPostID = hidden ? postID : nil
        // Apply to whatever is on screen right now; `cellForItemAt` covers
        // everything realized from here on.
        if let cell = cell(for: postID) {
            cell.isHidden = hidden
        }
    }

    /// The post behind an id, for a flight card that must configure itself
    /// from the model rather than from a cell that may not be realized.
    func post(for postID: PostID) -> GalleryPost? {
        posts.first { $0.id == postID }
    }

    /// The indices `new` adds when it is exactly `old` plus a suffix, else nil.
    ///
    /// Strict: every existing element must be unchanged and in place. A reorder
    /// (the discovery source switching between Trending and Recent) or an
    /// in-place edit is NOT an append and has to go through a full reload, or
    /// the cells would keep rendering stale posts.
    static func appendedRange(from old: [GalleryPost], to new: [GalleryPost]) -> Range<Int>? {
        guard !old.isEmpty, new.count > old.count else { return nil }
        guard Array(new.prefix(old.count)) == old else { return nil }
        return old.count..<new.count
    }

    private func cell(for postID: PostID) -> UICollectionViewCell? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0))
    }

    func render(_ state: ForYouViewModel.PageState) {
        switch state {
        case .loading:
            statusLabel.isHidden = true
            // A refresh keeps the existing rows under the spinner rather than
            // blanking to skeletons — the content is still valid until the
            // new page lands.
            apply(posts, skeleton: !refreshControl.isRefreshing && posts.isEmpty)
        case .content(let posts):
            statusLabel.isHidden = true
            apply(posts, skeleton: false)
        case .empty(let message), .failed(let message):
            statusLabel.text = message
            statusLabel.isHidden = false
            apply([], skeleton: false)
        }
    }

    private func apply(_ incoming: [GalleryPost], skeleton: Bool) {
        guard rawPosts != incoming || showsSkeleton != skeleton else { return }
        // Hydration retires the skeleton with a cross-dissolve, the same
        // in-place hand-off the profile gallery uses.
        let dissolving = showsSkeleton && !skeleton && !incoming.isEmpty && window != nil
        // A page landing is a pure APPEND, and `reloadData` would recycle every
        // realized cell to express it. That is what made a drag stop and restart
        // all four playing tiles inside 60ms — the players were fine, the cells
        // under them were destroyed and rebuilt. Inserting only the new items
        // leaves existing cells (and their playback) untouched.
        //
        // Measured against the RAW list, not the arranged one: arrangement is a
        // permutation, so an append upstream is still an append downstream, and
        // comparing raw keeps that fact simple to establish.
        let appended = Self.appendedRange(from: rawPosts, to: incoming)
        rawPosts = incoming
        showsSkeleton = skeleton
        if let appended, !showsSkeleton, !skeleton, !dissolving {
            // Arrange only the new tail, against the absolute slots it will
            // occupy. Placement depends solely on the absolute index, so the
            // items already on screen cannot move — which is what keeps this an
            // insert rather than a reload.
            posts += arrange(Array(incoming[appended]), startingAt: posts.count)
            collectionView.performBatchUpdates {
                collectionView.insertItems(
                    at: appended.map { IndexPath(item: $0, section: 0) }
                )
            }
            DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
            return
        }
        posts = arrange(incoming, startingAt: 0)
        if dissolving {
            UIView.transition(
                with: collectionView, duration: 0.35,
                options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseInOut],
                animations: { self.collectionView.reloadData() }
            )
        } else {
            collectionView.reloadData()
        }
        // New content means a new visible set. Reconcile after the reload has
        // realized its cells, or every candidate lookup returns nil.
        DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
    }
}

// MARK: - Data source / delegate

extension ForYouGridPage: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        showsSkeleton ? skeletonCount : posts.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if showsSkeleton {
            switch style {
            case .list:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonListCell.reuseID, for: indexPath
                ) as! PostGridSkeletonListCell
                cell.configure(variant: indexPath.item)
                return cell
            case .grid:
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonTileCell.reuseID, for: indexPath
                )
            }
        }
        let post = posts[indexPath.item]
        // Set on EVERY dequeue, both ways: the flight's stand-in stays hidden
        // across reloads, and a recycled cell can never carry a stale hide to
        // another tile.
        let isFlying = post.id == heroHiddenPostID
        switch style {
        case .list:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            cell.isHidden = isFlying
            return cell
        case .grid:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath
            ) as! PostGridTileCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            cell.isHidden = isFlying
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !showsSkeleton, posts.indices.contains(indexPath.item) else { return }
        collectionView.deselectItem(at: indexPath, animated: false)
        onItemTapped?(indexPath.item)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Autoplay reconciles DURING the scroll, so a brick starts playing as
        // it slides into view rather than after the scroll has stopped.
        // Throttled rather than run per callback: `scrollViewDidScroll` fires
        // at the display refresh rate, and reconciling at 120 Hz spends more
        // time diffing than the work is worth.
        throttledAutoplayReconcile(scrollView)

        guard !showsSkeleton, !posts.isEmpty, !isRepositioning else { return }
        let remaining = scrollView.contentSize.height
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        guard remaining < Self.prefetchDistance else { return }
        onNearEnd?()
    }

    /// Reconcile cadence during a scroll, in seconds. ~30 Hz: fast enough that
    /// a tile is playing by the time the eye has settled on it, slow enough
    /// that the diff cost stays invisible next to the scroll itself.
    private static let scrollReconcileInterval: CFTimeInterval = 1.0 / 30

    /// Points-per-second past which a *new* player is not started.
    ///
    /// The reconcile still runs at speed — tiles that leave stop immediately —
    /// but nothing starts during a hard fling. At 4000 pt/s a brick crosses the
    /// viewport in about a fifth of a second, so starting it means an item
    /// allocation and a segment fetch for something already gone. Dragging by
    /// hand rarely exceeds ~1500 pt/s, so the behaviour the request is about —
    /// tiles playing while the finger is still moving — sits well inside this.
    private static let maximumStartVelocity: CGFloat = 2200

    private func throttledAutoplayReconcile(_ scrollView: UIScrollView) {
        guard playback != nil, !showsSkeleton, !isRepositioning else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastReconcileTime
        guard elapsed >= Self.scrollReconcileInterval else { return }

        let offset = scrollView.contentOffset.y
        // Velocity from the sampling interval itself; `panGestureRecognizer
        // .velocity` reports zero once the finger lifts, which is exactly the
        // decelerating stretch this needs to measure.
        let velocity = elapsed > 0 ? abs(offset - lastReconcileOffset) / CGFloat(elapsed) : 0
        lastReconcileTime = now
        lastReconcileOffset = offset

        updateAutoplay(allowingStarts: velocity <= Self.maximumStartVelocity)
    }

    /// A fling that ends without deceleration still needs a final reconcile:
    /// the throttled pass may have been velocity-gated right up to the stop.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateAutoplay() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateAutoplay()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateAutoplay()
    }

    /// A recycled cell hands its player back immediately rather than waiting
    /// for the next reconcile, so it can never render the previous post.
    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let tile = cell as? PostGridTileCell else { return }
        playback?.stop(cell: tile)
    }
}
