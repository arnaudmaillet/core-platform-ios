import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// One format page of the gallery pager, in the fixed shape its format owns:
/// an asymmetric media mosaic (Media) or a 1-column timeline of full-width
/// rows (Activity, Short). Layouts are format-bound, so the page's shape is
/// set at init and never morphs — moving between shapes IS the pager's
/// horizontal swipe.
///
/// The pattern, the cells and the skeletons come from `PostGrid`, shared with
/// every other post-grid surface. What is NOT shared is this host: it is
/// deliberately NOT a scrolling collection view, because the profile's outer
/// scroll view owns all vertical motion (nested vertical scrolling would fight
/// the stretchy banner and the pull-to-refresh). This view self-sizes to its
/// full content and lets the outer surface scroll it. The cost is no cell
/// reuse; acceptable at today's one-page fetch, revisit alongside pagination.
/// A surface that scrolls in its own right builds a plain scrolling collection
/// view over the same `PostGrid` layouts instead of reusing this.
final class ProfileGalleryGridView: UIView {
    /// The page's fixed shape.
    enum Style {
        /// The asymmetric media mosaic, full bleed.
        case grid
        /// 1-column full-width self-sizing rows with reading margins.
        case list
    }

    /// The tapped post, plus the ordered run of posts FROM it — what the
    /// full-screen feed is seeded with, so the viewer can keep swiping through
    /// the gallery they were looking at instead of landing on one post alone.
    ///
    /// The POSTS, not their ids. Ids are all the destination strictly needs to
    /// fetch, but they are not enough to draw: handing over the models this
    /// page is already showing is what lets the opened post render in the tap's
    /// own frame instead of after its own round trip (`GalleryPostProjection`).
    /// The ids are one `map` away wherever they are actually wanted.
    var onItemTapped: ((GalleryPost, _ stream: [GalleryPost]) -> Void)?
    /// How many posts to hand the feed. Enough to swipe through without
    /// serialising an entire gallery into a route.
    private static let streamWindow = 30
    /// This page's vertical offset, every tick — the header rides the active
    /// page's.
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onPullToRefresh: (() -> Void)?
    /// The post to bring clear of the chrome once this page is out of sight.
    /// An ID, not an index: the corpus can change while the post is open.
    private var pendingRevealPostID: PostID?
    /// Fired when a drag ends, with how far the page was pulled past its top.
    var onPullReleased: ((CGFloat) -> Void)?

    /// Clearance the owner asked for — the tab bar, the tray.
    private var baseBottomInset: CGFloat = 0
    /// The header's travel, which this page must always be able to absorb.
    private var minimumTravel: CGFloat = 0
    /// Positions the empty state as though it were the first row.
    private var statusTopConstraint: NSLayoutConstraint?

    private let imagePipeline: ImagePipeline
    private let style: Style
    private var posts: [GalleryPost] = []
    /// Autoplay for this page's video media. Absent only where the host
    /// supplied no player pool.
    private let playback: GridVideoPlaybackCoordinator?
    /// The post whose twin is in the air: it must not claim a player while the
    /// flight is carrying that same media.
    private var heroFlyingPostID: PostID?
    /// The chrome that remains over this page's content once the header has
    /// travelled — told by the owner, which is the only thing that knows.
    private var stickyTopOcclusion: CGFloat = 0

    /// The page's live vertical offset, for harness polling.
    var currentVerticalOffset: CGFloat { collectionView.contentOffset.y }

    #if DEBUG
    /// The post the last reveal aligned, for the settled-state check.
    private(set) var debugLastRevealedPostID: PostID?

    /// Where that post's cell actually is on screen, once everything has settled.
    ///
    /// The reveal's own log runs from `viewDidDisappear`, where this view has no
    /// window and no conversion is possible — it reported `nan` and confirmed
    /// nothing. Asked again after the profile is back, this is the number the
    /// user is looking at.
    func debugRevealedTileInWindow() -> CGRect? {
        guard let id = debugLastRevealedPostID,
              let index = posts.firstIndex(where: { $0.id == id }),
              let window,
              let attributes = collectionView.layoutAttributesForItem(
                  at: IndexPath(item: index, section: 0)
              )
        else { return nil }
        return collectionView.convert(attributes.frame, to: window)
    }

    #endif
    /// While a fetch is in flight the page renders shimmering placeholder
    /// cells through its own (real) layout, so the loading state already has
    /// the shape the content will hydrate into. Read by the pager to keep its
    /// height re-pin out of the hydration cross-fade.
    private(set) var showsSkeleton = false

    /// List pages show a column of placeholder cards; the mosaic shows one
    /// full 8-brick pattern.
    /// Derived exactly as For You derives it: two slices' worth, so the loading
    /// state already has the shape content will hydrate into.
    private var skeletonCount: Int {
        style == .grid
            ? (sliceLayout?.cellsPerSlice ?? ChaoticSliceEngine.defaultCellsPerSlice) * 2
            : 5
    }

    private var sliceLayout: ChaoticSliceLayout? {
        collectionView.collectionViewLayout as? ChaoticSliceLayout
    }

    /// The page's own scroll view.
    ///
    /// ⚠️ **This used to be non-scrolling and self-sizing**, reporting its whole
    /// content as intrinsic size so the profile's outer scroll view could lay it
    /// out like any other view. That made every cell permanently "visible", so
    /// none were ever recycled — measured at 26 built up front and 26 after
    /// scrolling to the end, against 34 → 54 for the equivalent For You surface.
    /// It also made the page's HEIGHT the thing that changed when tabs changed,
    /// which is where every clipping, jumping and straddling bug on this screen
    /// came from.
    ///
    /// It is an ordinary scrolling collection view now, exactly one viewport
    /// tall. The owner insets it below the header rather than sizing it around
    /// the content.
    let collectionView: UICollectionView
    /// The shared empty state, the same object Messages shows when a tab has
    /// nothing in it. It used to be a bare centred label here — a sentence with
    /// no glyph and no headline, which reads as a screen that failed rather than
    /// as an answer, and which said nothing about WHICH tab was empty.
    private let emptyStateView = EmptyStateView()
    private let tab: ProfileTab

    init(
        imagePipeline: ImagePipeline,
        style: Style,
        tab: ProfileTab,
        videoPlayback: VideoPlaybackController? = nil
    ) {
        self.imagePipeline = imagePipeline
        self.style = style
        self.tab = tab
        // The SAME coordinator the For You surfaces use, on the same terms:
        // candidates ranked by distance from the viewport centre, the nearest
        // N kept. Six for a mosaic, five for a timeline — a column fits fewer
        // previews on screen, so the sixth slot would go to a row outside it.
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: style == .grid ? 6 : 5)
        }
        collectionView = UICollectionView(
            frame: .zero,
            // ⚠️ **The SAME layout For You builds**, not a second grid that
            // resembles it. This was `PostGridMosaic.layout()` — a 1.5pt hairline
            // gutter and square corners in a fixed eight-brick pattern — beside a
            // For You grid running `ChaoticSliceLayout` at an 8pt gutter and a
            // 16pt radius. They were not two configurations of one grid; they were
            // two grids, and only one of them was the design system's.
            collectionViewLayout: style == .grid
                ? ChaoticSliceLayout()
                : PostGridListLayout.layout()
        )
        super.init(frame: .zero)

        collectionView.isScrollEnabled = true
        // No indicators on any page of this screen. The header floats OVER the
        // pages, so a vertical bar runs the full height of the viewport and
        // crosses the chrome rather than stopping under it — and with three to
        // five tabs each holding their own position, an indicator that appears
        // on every switch reads as motion the viewer did not cause.
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        // The owner supplies the top inset (the header's height) and drives the
        // header from this view's offset, so UIKit must not also be adjusting
        // for safe areas underneath it.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
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
        collectionView.pin(to: self)

        // The pull-down region is the banner's, so the spinner renders above the
        // media in a colour that survives it.
        // ⚠️ **No `UIRefreshControl` here, deliberately.** It positions itself
        // against its scroll view's content top, and this page is inset below
        // the profile header — so the spinner appeared mid-screen, under the
        // identity block, rather than at the top of the page it was refreshing.
        // The indicator is hosted by `ProfileViewController` above the header
        // instead, and driven by the pull this page reports.


        // ⚠️ The empty state is NOT in the collection view, so it does not
        // scroll on its own — and this page is inset below a header now, so a
        // constant from the page's top puts it behind the chrome. Its position
        // is driven from the same two numbers the content uses, which makes it
        // behave as though it were content: below the header at rest, scrolling
        // away with everything else.
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        addSubview(emptyStateView)
        // ⚠️ Positioned by its CENTRE, and the centre is computed rather than
        // pinned. `EmptyStateView` centres itself in its parent, and this
        // parent is the whole page — under the floating header, so a plain
        // centre lands the block behind the identity block. The constant puts
        // it in the middle of what is actually visible, and rides the offset so
        // it scrolls away like content rather than hanging in the chrome.
        let statusTop = emptyStateView.centerYAnchor.constraint(equalTo: topAnchor)
        statusTopConstraint = statusTop
        NSLayoutConstraint.activate([
            statusTop,
            emptyStateView.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Statuses (empty / failed) need visible height even though the
        // collection view is empty then; the grid provides a floor and
        // grows past it with content (skeletons included).
        let floor = heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        floor.priority = .defaultHigh
        floor.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The room a page needs below its last row depends on how much content
        // it has and how tall it is, and both settle after layout — a page
        // measured before its rows exist would reserve the wrong amount and
        // stop being able to hold the header.
        applyBottomInset()
        // ⚠️ The empty state is centred between the header and the chrome, and
        // BOTH of those are measured from this view's height — which is zero
        // until a layout pass gives it one. Positioned only from the inset, the
        // block centred on the header's own bottom edge and its glyph came out
        // clipped behind the selector. Re-running it here is what lets it
        // settle once the page knows how tall it is.
        positionStatusLabel()
    }

    func render(_ state: ProfileViewModel.GalleryPageState) {
        switch state {
        case .loading:
            emptyStateView.isHidden = true
            apply([], skeleton: true)
        case .content(let posts):
            emptyStateView.isHidden = true
            apply(posts, skeleton: false)
        case .empty(let message):
            let copy = tab.emptyState
            // The model's message wins when it has something the tab cannot
            // know — "no media in reposts" says why this page is narrower than
            // the profile, which is the thing worth reading. A tab that is
            // simply empty has nothing to add, and falls back to its own line.
            emptyStateView.configure(
                symbolName: copy.symbol,
                title: copy.title,
                subtitle: message.isEmpty ? copy.subtitle : message
            )
            emptyStateView.isHidden = false
            apply([], skeleton: false)
        case .failed(let message):
            // A failure is NOT an empty state, and saying so is the point of
            // having both: the glyph and the headline have to read as "this did
            // not work" rather than as "there is nothing here", or a viewer
            // retries nothing and concludes the profile is bare.
            emptyStateView.configure(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't Load",
                subtitle: message
            )
            emptyStateView.isHidden = false
            apply([], skeleton: false)
        }
    }

    private func apply(_ posts: [GalleryPost], skeleton: Bool) {
        guard self.posts != posts || showsSkeleton != skeleton else { return }
        // Hydration retires the skeleton with a cross-dissolve: the shimmer
        // hands off to content inside the same silhouette instead of popping.
        let dissolving = showsSkeleton && !skeleton && !posts.isEmpty && window != nil
        self.posts = posts
        showsSkeleton = skeleton
        let reload = {
            self.collectionView.reloadData()
            self.collectionView.invalidateIntrinsicContentSize()
            // Content landing is a reconcile trigger, and on a page nobody
            // scrolls it is very nearly the only one.
            //
            // The layout pass is the load-bearing half. `reloadData` only
            // marks the items dirty — the cells are built on the next layout —
            // and the reconcile asks `cellForItem(at:)`, which answers nil
            // until then. So a plain hop found no candidates, and nothing came
            // back to ask again: the surface had already gone active before
            // the posts arrived, a page nobody scrolls emits no scroll, and
            // `onCoverLoaded` never fires on a warm cache because `configure`
            // takes the cached image and returns. Zero starts, no error.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                collectionView.layoutIfNeeded()
                reconcileAutoplay()
            }
        }
        if dissolving {
            // The block runs with implicit animations disabled (stock
            // `UIView.transition` behavior, `.allowAnimatedContent` NOT set),
            // so the relayout inside commits instantly and only the
            // cross-fade itself is visible: a pure in-place dissolve.
            UIView.transition(
                with: collectionView, duration: 0.35,
                options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseInOut],
                animations: reload
            )
        } else {
            reload()
        }
    }
}

// MARK: - Data source / delegate

extension ProfileGalleryGridView: UICollectionViewDataSource, UICollectionViewDelegate {
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
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonTileCell.reuseID, for: indexPath
                ) as! PostGridSkeletonTileCell
                // The shimmer has to be the shape content will hydrate into, or
                // the cross-dissolve changes silhouette as it lands.
                cell.cornerRadius = ChaoticSliceLayout.harmonisedCornerRadius
                return cell
            }
        }
        let post = posts[indexPath.item]
        switch style {
        case .list:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            // Autoplay is gated on the cover, so a cover arriving is the only
            // event that can re-open the gate for an item that came up
            // faceless while the page sat still.
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
            return cell
        case .grid:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath
            ) as! PostGridTileCell
            cell.cornerRadius = ChaoticSliceLayout.harmonisedCornerRadius
            cell.configure(with: post, imagePipeline: imagePipeline)
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
            return cell
        }
    }

    // MARK: - Autoplay

    /// The part of this page a viewer can actually see.
    ///
    /// NOT `bounds.inset(by: adjustedContentInset)`, which is what the For You
    /// pages use and what this used at first. There both insets are floating
    /// chrome — a nav bar and a tab bar that sit OVER the content — so
    /// removing them leaves what is visible. Here the top inset is the profile
    /// HEADER's reserved space: the header is above the content and scrolls
    /// away with it, so nothing is hidden behind it and subtracting it removes
    /// the page.
    ///
    /// Measured: a 556pt top inset on a 956pt page left a band 108pt tall, and
    /// every item's media fell outside it. Nothing ever played, and the gate
    /// reported no candidates rather than an error.
    ///
    /// The bottom inset IS chrome — the filter tray and the tab bar float over
    /// the last rows — so that half is still removed.
    /// What actually covers this page's content, top and bottom — see
    /// `visibleBand`. Shared with the scroll-into-view reveal so the two agree
    /// about where the viewer can see.
    private var chromeOcclusion: UIEdgeInsets {
        var occlusion = collectionView.verticalScrollIndicatorInsets
        occlusion.left = 0
        occlusion.right = 0
        // ⚠️ The TOP indicator inset is not occlusion on this page either.
        // `setContentTopInset` sets it to the header's full reserved height,
        // and that space is where content BEGINS, not where it hides: the
        // header floats above the content and scrolls away with it, so the only
        // thing content ever passes under is the part that STAYS — the docked
        // selector and the status bar.
        //
        // Using the reserved height judged every item in the first ~557pt as
        // hidden, so revealing one scrolled the page to the very top. Measured:
        // offset -116 → -557 for a tile that was plainly on screen, which is
        // the whole of the "dismissing resets my scroll position" report.
        occlusion.top = stickyTopOcclusion
        return occlusion
    }

    func setStickyTopOcclusion(_ height: CGFloat) {
        stickyTopOcclusion = height
    }

    private var visibleBand: CGRect {
        // The SCROLL INDICATOR insets, which is the one number on this page
        // that means "where the visible area ends". The content insets do not:
        // the top one is the header's reserved space (it scrolls away, it
        // hides nothing) and the bottom one is inflated by `applyBottomInset`
        // so a short page can still travel. Between them they described a band
        // 108pt tall on a 956pt page, and every item's media fell outside it.
        collectionView.bounds.inset(by: chromeOcclusion)
    }

    /// Minimum fraction of an item's MEDIA that must be inside the visible
    /// band before it may play. An item creeping in at the edge is not
    /// something the viewer is looking at.
    private static let minimumVisibleFraction: CGFloat = 0.5

    /// Reconciles playback against what is on screen now. Cheap and
    /// idempotent; call it whenever the visible set can have changed.
    ///
    /// The same rules the For You pages apply, because it is the same
    /// coordinator: measured against the MEDIA rather than the cell (a row is
    /// mostly caption, so a card half on screen can have no preview showing),
    /// gated on the item having a cover to sit behind the surface, and never
    /// starting the post a flight is currently carrying.
    func reconcileAutoplay(allowingStarts: Bool = true) {
        guard let playback else { return }
        let viewport = visibleBand
        let centreY = viewport.midY
        let candidates = collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> GridVideoPlaybackCoordinator.Candidate? in
            guard !showsSkeleton, posts.indices.contains(indexPath.item) else { return nil }
            let post = posts[indexPath.item]
            // Square video stays still in a MOSAIC and plays in a timeline row,
            // for the reason `hasPlayableVideo` records — the same split the
            // For You pages make.
            let playsHere = style == .grid ? post.autoplaysInGrid : post.hasPlayableVideo
            guard playsHere, let url = post.videoURL,
                  post.id != heroFlyingPostID,
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell,
                  hasCover(for: post, in: cell)
            else { return nil }

            let frame = cell.convert(cell.videoMediaRect, to: collectionView)
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
        #if DEBUG
        // `-grid-playback-log`: why the gate answered what it did. An empty
        // candidate list has half a dozen possible causes and they all look
        // identical from outside.
        if ProcessInfo.processInfo.arguments.contains("-grid-playback-log"), candidates.isEmpty {
            let visible = collectionView.indexPathsForVisibleItems
            let videos = posts.filter(\.hasPlayableVideo).count
            let realized = visible.filter { collectionView.cellForItem(at: $0) != nil }.count
            print("[profile-autoplay] none: posts=\(posts.count) videos=\(videos) "
                  + "skeleton=\(showsSkeleton) visible=\(visible.count) realized=\(realized) "
                  + "style=\(style == .grid ? "grid" : "list") "
                  + "viewport=\(Int(viewport.minY))…\(Int(viewport.maxY)) "
                  + "inset=\(Int(collectionView.adjustedContentInset.top))/"
                  + "\(Int(collectionView.adjustedContentInset.bottom))")
            for indexPath in visible where posts.indices.contains(indexPath.item) {
                let post = posts[indexPath.item]
                guard post.hasPlayableVideo else { continue }
                let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell
                let frame = cell.map { $0.convert($0.videoMediaRect, to: collectionView) } ?? .zero
                let overlap = frame.intersection(viewport)
                let fraction = frame.height > 0 && !overlap.isNull
                    ? (overlap.height * overlap.width) / (frame.height * frame.width) : 0
                print("[profile-autoplay]   \(post.id.rawValue) shape=\(post.shape) "
                      + "playsHere=\(style == .grid ? post.autoplaysInGrid : post.hasPlayableVideo) "
                      + "cover=\(cell?.renderedCover == nil ? "NIL" : "set") "
                      + "media=\(Int(frame.minY))…\(Int(frame.maxY)) frac=\(String(format: "%.2f", fraction))")
            }
        }
        #endif
    }

    /// Whether an item has something to show behind its video surface. A
    /// surface with no cover draws black until the first frame decodes.
    private func hasCover(for post: GalleryPost, in cell: any GridPlaybackCell) -> Bool {
        guard let thumbnail = post.thumbnailURL else { return true }
        if cell.renderedCover != nil { return true }
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        cell.applyCover(cached)
        return true
    }

    /// Tab frontmost and this page active, or not. Mirrors the pager's gate on
    /// For You: only the page being read may hold pool slots.
    func setAutoplayActive(_ active: Bool) {
        playback?.setSurfaceVisible(active)
        guard active else { return }
        // Same reason as the reload above: this can arrive with content
        // already applied but not yet laid out — a tab becoming active, or a
        // profile re-appearing — and an unrealised cell is not a candidate.
        collectionView.layoutIfNeeded()
        reconcileAutoplay()
    }

    /// Where a post's media sits on screen, and what it is showing — the two
    /// facts a hero flight needs from this page.
    ///
    /// Returns nil when the post has no realized cell (scrolled away) or no
    /// media to fly, which is the same rule the For You grid applies.
    func heroGeometry(for postID: PostID) -> (rect: CGRect, cover: UIImage?, isTile: Bool)? {
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return nil }
        // The MEDIA's rect, which a text row does not have — and that absence
        // is the whole of its transition policy, exactly as on For You. A row
        // is a card of which the media is one part, so `mediaHeroRect` answers
        // nil when there is no part to fly; a tile IS its media.
        //
        // Deliberately not `videoMediaRect`: that falls back to the cell's
        // bounds so the autoplay gate always has something to measure, which
        // would fly a text row's whole card. Different question, different
        // rect.
        let rect: CGRect? = switch cell {
        case let tile as PostGridTileCell: tile.bounds
        case let row as PostGridListRowCell: row.mediaHeroRect
        default: nil
        }
        guard let rect, rect != .zero else { return nil }
        return (
            rect: cell.convert(rect, to: collectionView),
            cover: (cell as? any GridPlaybackCell)?.renderedCover,
            isTile: cell is PostGridTileCell
        )
    }

    /// Hides just what the flight is carrying: a tile goes whole, a row loses
    /// only its preview. Same invariant the For You grid keeps.
    func setHeroConcealed(_ concealed: Bool, for postID: PostID) {
        heroFlyingPostID = concealed ? postID : nil
        if !concealed { reconcileAutoplay() }
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return }
        if let row = cell as? PostGridListRowCell {
            row.setHeroMediaConcealed(concealed)
        } else {
            cell.isHidden = concealed
        }
    }

    /// The scroll view the hero measures against, so the caller can convert.
    var heroCoordinateSpace: UICoordinateSpace { collectionView }

    #if DEBUG
    /// Drives the page's real selection path, the one a finger reaches.
    ///
    /// Without it nothing scripted can tap a tile — and the profile's open
    /// destination and its background reveal are both things only a tap
    /// exercises. Same reason `ForYouGridPage` grew one.
    func debugSelectItem(at index: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))
        return true
    }
    #endif

    /// Brings the last-tapped tile clear of the chrome, now that the post is
    /// covering this page. Unanimated: nobody is watching, and the dismissal
    /// reads the tile's rect when it starts.
    func applyPendingReveal() {
        guard let id = pendingRevealPostID else { return }
        pendingRevealPostID = nil
        #if DEBUG
        debugLastRevealedPostID = id
        #endif
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        let rect = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        #if DEBUG
        let offsetBefore = collectionView.contentOffset.y
        #endif
        ScrollIntoView.revealImmediately(
            rect,
            in: collectionView,
            // The SAME occlusion the autoplay gate uses, and for the same
            // reason: this page's content insets are layout, not chrome. Handing
            // over `adjustedContentInset` put a tile tucked under the header
            // down at the footer instead of just below the header.
            occlusion: chromeOcclusion
        )
        #if DEBUG
        // `-profile-reveal-log`: which edge the tile was aligned against, and
        // where it ended up. The bug this proves absent aligned a tile tucked
        // under the TOP header against the BOTTOM one, and a screenshot after
        // the fact cannot say which edge the arithmetic chose.
        if ProcessInfo.processInfo.arguments.contains("-profile-reveal-log"), let rect {
            let after = collectionView.contentOffset.y
            let cover = chromeOcclusion
            let topGap = rect.minY - after - cover.top
            let bottomGap = (after + collectionView.bounds.height - cover.bottom) - rect.maxY
            print(String(format:
                "[profile-reveal] tile=%.0f…%.0f offset %.0f→%.0f cover=%.0f/%.0f "
                + "gapBelowSelector=%.0f gapAboveFooter=%.0f",
                rect.minY, rect.maxY, offsetBefore, after,
                cover.top, cover.bottom, topGap, bottomGap))
        }
        #endif
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // A cell that left must hand its player back whatever the scroll is
        // doing, or the pool starves.
        guard let playable = cell as? any GridPlaybackCell else { return }
        playback?.stop(cell: playable)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !showsSkeleton, posts.indices.contains(indexPath.item) else { return }
        // Same contract as the For You grids: the flight leaves from where
        // the tile IS, and the reveal waits until the post has covered this
        // page (`applyPendingReveal`). Moving the grid under the thumb at tap
        // time is a jump the viewer is looking straight at.
        pendingRevealPostID = posts[indexPath.item].id
        onItemTapped?(
            posts[indexPath.item],
            Array(posts[indexPath.item...].prefix(Self.streamWindow))
        )
    }
}


// MARK: - The vertical axis this page now owns

extension ProfileGalleryGridView {
    /// Where this page is scrolled to, measured from the top of its content
    /// rather than from its own origin.
    ///
    /// The pages sit under a header, so their resting offset is `-inset` rather
    /// than zero. Reporting the distance travelled instead keeps every caller
    /// out of that arithmetic: zero is the top for all three pages, whatever
    /// their insets happen to be mid-transition.
    var verticalOffset: CGFloat {
        collectionView.contentOffset.y + collectionView.contentInset.top
    }

    func setVerticalOffset(_ offset: CGFloat) {
        setVerticalOffset(offset, animated: false)
    }

    /// The same, with the option of travelling there in view of the viewer.
    ///
    /// Animated is for the ONE case a viewer asked for the journey: re-tapping
    /// the tab already showing, which is a request to be taken back rather than
    /// to be put back. Every other caller writes the offset directly, because
    /// they are keeping a page in step with something else and an animation
    /// there is a page arriving late.
    func setVerticalOffset(_ offset: CGFloat, animated: Bool) {
        #if DEBUG
        // `-profile-offset-trace`: names whoever moves a page. The reveal writes
        // an offset while this screen is covered and something puts it back
        // before the viewer sees it; the reveal's own log reports what it SET,
        // never what survived, so only the caller list can say who.
        if ProcessInfo.processInfo.arguments.contains("-profile-offset-trace") {
            let callers = Thread.callStackSymbols.dropFirst().prefix(7)
                .filter { $0.contains("Profile") }
                .map { $0.split(separator: " ").dropFirst(3).prefix(6).joined(separator: " ") }
            print("[offset-trace] → \(Int(offset)) via \(callers.joined(separator: " ← "))")
        }
        #endif
        // ⚠️ **Make room BEFORE asking the page to travel.** The room a page
        // needs is computed from its content size, and on a tab switch the page
        // being handed the offset may not have laid out since its content
        // arrived — so it clamps against a range that has not been extended yet,
        // and the header follows the clamp. Laying out first is what makes the
        // floor arrive before the question rather than after the answer.
        collectionView.layoutIfNeeded()
        applyBottomInset()
        let inset = collectionView.contentInset.top
        // ⚠️ **The bottom inset is part of how far a page can travel**, and
        // leaving it out is why the header still moved on a tab switch. The room
        // reserved by `setMinimumScrollTravel` IS bottom inset — so a clamp that
        // ignored it measured the page as unable to hold the offset, took the
        // shorter number, and the header followed it back up. The floor was
        // being reserved and then not counted.
        let travel = collectionView.contentSize.height
            + inset
            + collectionView.contentInset.bottom
            - collectionView.bounds.height
        // Negative is the pulled-down region, which only the QA hook asks for;
        // a real drag never routes through here.
        let target = offset < 0 ? offset : min(offset, max(0, travel))
        guard abs(verticalOffset - target) > 0.5 else { return }
        let point = CGPoint(x: 0, y: target - inset)
        if animated {
            collectionView.setContentOffset(point, animated: true)
        } else {
            collectionView.contentOffset = point
        }
    }

    /// The height of the header floating above this page.
    func setContentTopInset(_ inset: CGFloat) {
        guard collectionView.contentInset.top != inset else { return }
        let travelled = verticalOffset
        collectionView.contentInset.top = inset
        collectionView.verticalScrollIndicatorInsets.top = inset
        // Changing the inset moves the content under a stationary offset, so the
        // offset is restated to keep the page where it was.
        collectionView.contentOffset = CGPoint(x: 0, y: travelled - inset)
        positionStatusLabel()
    }

    /// Puts the empty state where the first row would be.
    private func positionStatusLabel() {
        // Centre of the region between the header's bottom and the chrome at
        // the foot of the screen — not of the page, which is taller than either.
        let visibleTop = collectionView.contentInset.top
        let visibleBottom = max(visibleTop, bounds.height - baseBottomInset)
        statusTopConstraint?.constant = (visibleTop + visibleBottom) / 2 - verticalOffset
    }

    func setContentBottomInset(_ inset: CGFloat) {
        guard baseBottomInset != inset else { return }
        baseBottomInset = inset
        applyBottomInset()
    }

    /// How far this page must be ABLE to scroll, whatever it holds.
    ///
    /// ⚠️ **This is what freezes the header across a tab switch.** The header
    /// rides the active page's offset, and a page with three rows cannot reach
    /// the offset a page with thirty was sitting at — so switching to it
    /// clamped, and the header followed the clamp back up. Nothing was
    /// auto-scrolling; the short tab simply had nowhere to put the viewer.
    ///
    /// Given room to travel the header's full distance, every tab can hold any
    /// position the header can be in, and a switch moves it by nothing at all.
    /// The room is empty space below the last row — which is exactly what the
    /// other apps show under a sparse tab, and only ever as much as the header
    /// actually needs.
    func setMinimumScrollTravel(_ travel: CGFloat) {
        guard minimumTravel != travel else { return }
        minimumTravel = travel
        applyBottomInset()
    }

    private func applyBottomInset() {
        let needed = minimumTravel
            + collectionView.bounds.height
            - collectionView.contentSize.height
            - collectionView.contentInset.top
        let bottom = max(baseBottomInset, needed)
        guard abs(collectionView.contentInset.bottom - bottom) > 0.5 else { return }
        collectionView.contentInset.bottom = bottom
        collectionView.verticalScrollIndicatorInsets.bottom = baseBottomInset
    }

    /// Kept for the owner's call sites; the visible spinner is the profile's,
    /// so there is nothing to stop here.
    func endRefreshing() {}
}

extension ProfileGalleryGridView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionStatusLabel()
        onVerticalScroll?(verticalOffset)
        // Reconciles DURING the scroll, so an item starts as it slides into
        // view rather than after the scroll has stopped. Stops always run;
        // starts are held off above the fling speed, where anything started is
        // gone before its first frame.
        reconcileAutoplay(allowingStarts: abs(scrollView.panGestureRecognizer
            .velocity(in: scrollView).y) <= Self.maximumStartVelocity)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reconcileAutoplay()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reconcileAutoplay()
    }

    /// The finger left the glass. Reports how far past the top the page was
    /// when it did, which is what decides whether a refresh was asked for —
    /// the threshold belongs to the indicator, not to this page.
    /// Above this, a scroll is a fling and nothing new should start.
    private static let maximumStartVelocity: CGFloat = 2200

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reconcileAutoplay() }
        onPullReleased?(max(0, -verticalOffset))
    }
}
