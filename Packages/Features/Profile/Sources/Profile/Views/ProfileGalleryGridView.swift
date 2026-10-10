import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit
import CoreNavigation

/// One page of the profile's posts, in a shape fixed at init: For You's
/// Discover list for the profile's Posts (#631), a 1-column timeline of
/// full-width rows for Saved and Liked, or the asymmetric media mosaic for the
/// media gallery "View all" pushes.
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
        /// For You's Discover list (#631): full-width cards with chunks of
        /// the media mosaic between them, vertical media in half-width pairs,
        /// and "View all" under each chunk — `MosaicChunkPlanner` decides the
        /// stretches, `DiscoverListLayout` draws them, one SECTION each.
        case discover
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
    /// The same open, arriving with the thread up — a card's comment chip.
    /// Nil falls back to `onItemTapped`, so the chip is never a dead control.
    var onItemCommentsTapped: ((GalleryPost, _ stream: [GalleryPost]) -> Void)?
    /// What the cards' like chips stake with — see `PostCardStaking`.
    var staking: PostCardStaking?
    /// How many posts to hand the feed. Enough to swipe through without
    /// serialising an entire gallery into a route.
    private static let streamWindow = 30
    /// This page's vertical offset, every tick — the header rides the active
    /// page's.
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onPullToRefresh: (() -> Void)?
    /// One of the grid's last tiles came on screen: time for the next page
    /// (#634).
    var onNearEnd: (() -> Void)?
    /// "View all" under one of the Discover list's chunks: the profile's
    /// media gallery (#631).
    var onViewAllTapped: (() -> Void)?
    /// How close to the end a tile has to be for its coming on screen to ask
    /// for the next page — three rows of tiles.
    static let nearEndTileCount = 9
    /// The post to bring clear of the chrome once this page is out of sight.
    /// An ID, not an index: the corpus can change while the post is open.
    private var pendingRevealPostID: PostID?
    /// Fired when a drag ends, with how far the page was pulled past its top.
    var onPullReleased: ((CGFloat) -> Void)?
    /// Where a release comes to rest while the header is on screen, in the
    /// travelled space — see `ProfileScrollDetents`. Empty means free.
    var snapDetents: [CGFloat] = []
    /// A snap decided at the release with no momentum behind it, which the
    /// scroll view will not carry out on its own — see
    /// `scrollViewDidEndDragging`.
    private var pendingSnap: CGFloat?
    /// A row's author was tapped — its disc, its name or its handle.
    var onAuthorTapped: ((GalleryPost) -> Void)?
    /// What a row's "..." offers. Asked at press time, per row; the screen
    /// decides, because this view knows nothing about what can be serviced.
    var authorMenuActions: ((AuthorMenuContext) -> [PostCardMenuAction])?
    /// Fired when the viewer asks to repost a row's post. Nothing sets it yet
    /// — the same open seam For You has (`ForYouGridPage.onRepostRequested`) —
    /// so, as there, no card draws the control until something does (#801).
    var onRepostRequested: ((GalleryPost) -> Void)?

    /// What a card's repost control does for `post`: nil, which hides it,
    /// while nothing handles a repost (#801).
    func repostHandler(for post: GalleryPost) -> (() -> Void)? {
        guard onRepostRequested != nil else { return nil }
        return { [weak self] in self?.onRepostRequested?(post) }
    }
    /// The viewer's saved pile, the SAME store the Saved tab reads, so a card
    /// here and the tab below cannot disagree about whether a post is saved.
    /// Nil where no pile exists (anyone else's profile in some setups); the
    /// save control is then not drawn.
    private let bookmarks: PostBookmarkStore?

    /// Everything a host needs to build one row's menu.
    struct AuthorMenuContext {
        let post: GalleryPost
        let authorID: ProfileID
        /// The control that was pressed, for a popover-shaped follow-up sheet.
        let anchor: UIView
    }

    /// Clearance the owner asked for — the tab bar, the tray.
    private var baseBottomInset: CGFloat = 0
    /// The header's travel, which this page must always be able to absorb.
    private var minimumTravel: CGFloat = 0
    /// Positions the empty state as though it were the first row.
    private var statusTopConstraint: NSLayoutConstraint?

    private let imagePipeline: ImagePipeline
    /// Which captions the viewer has opened out — owned here because the rows
    /// that show them are recycled (see `CaptionExpansion`).
    private let captionExpansion = CaptionExpansion()
    private let style: Style
    /// The posts in the order they are DRAWN. On Discover that is the
    /// stretches' order, not the corpus's: a chunk pulls media forward.
    private var posts: [GalleryPost] = []

    // MARK: Discover's stretches

    /// Discover only: the list's stretches, one collection-view SECTION each.
    /// Empty on the other styles, and while a skeleton shows.
    private var segments: [DiscoverSegment] = []
    /// Where each stretch begins in `posts`.
    private var segmentStarts: [Int] = []
    /// The posts a chunk draws as mosaic tiles.
    private var tilePostIDs: Set<PostID> = []
    /// The posts drawn as half-width cards in pairs — a tile wearing the
    /// Following card's foot and corner (For You draws them with its
    /// Following card, whose face this is).
    private var pairedPostIDs: Set<PostID> = []
    /// Keeps the chunk tilings it has generated, for the page's life.
    private var chunkPlanner = MosaicChunkPlanner()
    /// Whether the corpus behind the page is all of it — what lets the tail
    /// chunk be decided rather than held back (`MosaicChunkPlanner`). Told by
    /// the owner before each render.
    private var isCorpusComplete = false
    /// The completeness the stretches on screen were planned under.
    private var plannedCorpusComplete = false
    /// Autoplay for this page's video media. Absent only where the host
    /// supplied no player pool.
    private let playback: GridVideoPlaybackCoordinator?
    /// The post whose twin is in the air: it must not claim a player while the
    /// flight is carrying that same media.
    private var heroFlyingPostID: PostID?
    /// What the flight carries, so a cell configured mid-flight hides as much
    /// as `setHeroConcealed` did.
    private var heroFlyingCarry: PostGridListRowCell.HeroCarry = .media
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
                  at: indexPath(for: index)
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

    #if DEBUG
    /// Full reloads, and items re-dressed in place — what a refresh that
    /// brought nothing new must leave at zero.
    private(set) var debugReloadCount = 0
    private(set) var debugReconfiguredItems = 0
    /// Items whose news was only their counters, written in place.
    private(set) var debugRecountedItems = 0
    /// The empty state's fitting passes — which a scroll must not add to.
    private(set) var debugEmptyStateMeasureCount = 0
    /// Discover's stretches as planned.
    var debugSegments: [DiscoverSegment] { segments }
    /// Where a post is drawn, for a test that scrolls to it.
    func debugIndexPath(for postID: PostID) -> IndexPath? {
        posts.firstIndex { $0.id == postID }.map { indexPath(for: $0) }
    }
    #endif

    /// What `emptyStateHeight` was last measured for.
    private struct EmptyStateKey: Equatable {
        var width: CGFloat
        var revision: Int
        var contentSize: UIContentSizeCategory
    }
    private var emptyStateHeightCache: (key: EmptyStateKey, height: CGFloat)?
    /// Bumped whenever the empty state is configured — its height is what it
    /// says.
    private var emptyStateRevision = 0

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
    let tab: ProfileTab

    init(
        imagePipeline: ImagePipeline,
        style: Style,
        tab: ProfileTab,
        videoPlayback: VideoPlaybackController? = nil,
        bookmarks: PostBookmarkStore? = nil
    ) {
        self.imagePipeline = imagePipeline
        self.style = style
        self.tab = tab
        self.bookmarks = bookmarks
        // The SAME coordinator the For You surfaces use, on the same terms:
        // candidates ranked by distance from the viewport centre, the nearest
        // N kept. Six for a mosaic, five for a timeline — a column fits fewer
        // previews on screen, so the sixth slot would go to a row outside it.
        // Discover holds tiles and cards both, so it takes the mosaic's six.
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: style == .list ? 5 : 6)
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
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        collectionView.prefersClearTopEdge()
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
        collectionView.register(
            DiscoverViewAllFooterView.self,
            forSupplementaryViewOfKind: DiscoverListLayout.viewAllElementKind,
            withReuseIdentifier: DiscoverViewAllFooterView.reuseID
        )
        if style == .discover {
            // Set here rather than in the initialiser: its sections are asked
            // of this page, which does not exist until `super.init`.
            collectionView.setCollectionViewLayout(
                DiscoverListLayout.layout(
                    chunk: { [weak self] section in self?.chunk(inSection: section) },
                    isPairs: { [weak self] section in self?.isPairs(inSection: section) ?? false }
                ),
                animated: false
            )
        }
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
            emptyStateRevision += 1
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
            emptyStateRevision += 1
            emptyStateView.configure(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't Load",
                subtitle: message
            )
            emptyStateView.isHidden = false
            apply([], skeleton: false)
        }
    }

    /// Whether `new` is `old` with other counters — the one change a cell can
    /// take without being re-dressed or re-measured.
    static func differOnlyInCounts(_ old: GalleryPost, _ new: GalleryPost) -> Bool {
        var recounted = new
        recounted.reactionCount = old.reactionCount
        recounted.commentCount = old.commentCount
        return recounted == old
    }

    /// No further page is coming, or one is. Read by the next `render` —
    /// Discover only; the other styles show what they have.
    func setCorpusComplete(_ complete: Bool) {
        isCorpusComplete = complete
    }

    private func apply(_ posts: [GalleryPost], skeleton: Bool) {
        if style == .discover {
            applyDiscover(posts, skeleton: skeleton)
            return
        }
        guard self.posts != posts || showsSkeleton != skeleton else { return }
        // ⚠️ The same posts in the same places — a refresh bringing new
        // counts — re-dress only the cells whose post changed. A reload
        // rebuilt every visible cell and its media for a number.
        if !showsSkeleton, !skeleton, self.posts.count == posts.count,
           zip(self.posts, posts).allSatisfy({ $0.id == $1.id }) {
            let changed = posts.indices.filter { self.posts[$0] != posts[$0] }
            // A count is a capsule's text: written straight onto the cells on
            // screen. Measured on a refresh landing new like counts, a
            // reconfigure of two cards was 15 ms of the collection view
            // re-dressing and re-measuring them. Everything else — another
            // change, or a cell off screen (a prefetched one is not asked
            // for again) — is reconfigured.
            let visible = Set(collectionView.indexPathsForVisibleItems.map(\.item))
            let countsOnly = changed.filter {
                visible.contains($0) && Self.differOnlyInCounts(self.posts[$0], posts[$0])
            }
            let reconfigured = changed.filter { !countsOnly.contains($0) }
            self.posts = posts
            HeroScreenCost.measure("gallery.counts") {
                for index in countsOnly {
                    switch collectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
                    case let row as PostGridListRowCell: row.updateCounts(from: posts[index])
                    case let tile as PostGridTileCell: tile.updateCounts(from: posts[index])
                    default: break
                    }
                }
            }
            if !reconfigured.isEmpty {
                HeroScreenCost.measure("gallery.reconfigure") {
                    collectionView.reconfigureItems(at: reconfigured.map { IndexPath(item: $0, section: 0) })
                }
            }
            #if DEBUG
            debugRecountedItems += countsOnly.count
            debugReconfiguredItems += reconfigured.count
            #endif
            return
        }
        // ⚠️ A PAGE APPENDED BELOW INSERTS, IT DOES NOT RELOAD (#634). A reload
        // rebuilt every tile on screen — media re-dressed, playing tiles
        // handed back and restarted — for posts that had not moved.
        if !showsSkeleton, !skeleton, posts.count > self.posts.count, !self.posts.isEmpty,
           zip(self.posts, posts).allSatisfy({ $0.id == $1.id }) {
            let changed = self.posts.indices.filter { self.posts[$0] != posts[$0] }
            let added = (self.posts.count..<posts.count).map { IndexPath(item: $0, section: 0) }
            self.posts = posts
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates {
                    collectionView.insertItems(at: added)
                    if !changed.isEmpty {
                        collectionView.reconfigureItems(at: changed.map { IndexPath(item: $0, section: 0) })
                    }
                }
            }
            collectionView.invalidateIntrinsicContentSize()
            return
        }
        // Hydration retires the skeleton with a cross-dissolve: the shimmer
        // hands off to content inside the same silhouette instead of popping.
        let dissolving = showsSkeleton && !skeleton && !posts.isEmpty && window != nil
        self.posts = posts
        showsSkeleton = skeleton
        reloadAll(dissolving: dissolving)
    }

    /// Discover's delivery, For You's rule (`ForYouGridPage.applyDiscover`):
    /// the stretches are re-planned over the whole corpus, and the difference
    /// is an INSERT whenever it is one — a page landing grows the last run of
    /// cards and appends stretches after it, leaving every realized cell and
    /// its playback alone. The same structure with new counters re-dresses
    /// only what changed.
    private func applyDiscover(_ corpus: [GalleryPost], skeleton: Bool) {
        let before = segments
        let postsBefore = posts
        let wasSkeleton = showsSkeleton
        let completenessChanged = plannedCorpusComplete != isCorpusComplete
        plannedCorpusComplete = isCorpusComplete
        let planned = skeleton ? [] : chunkPlanner.segments(for: corpus, isComplete: isCorpusComplete)
        let change = MosaicChunkPlanner.change(from: before, to: planned)
        let dissolving = wasSkeleton && !skeleton && !planned.isEmpty && window != nil
        adoptSegments(planned)
        showsSkeleton = skeleton
        if !wasSkeleton, !skeleton, !before.isEmpty, case .extended(let grown, let appended) = change {
            let last = before.count - 1
            let changed = postsBefore.indices.filter { postsBefore[$0] != posts[$0] }
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates {
                    if !grown.isEmpty {
                        collectionView.insertItems(at: grown.map { IndexPath(item: $0, section: last) })
                    }
                    if !appended.isEmpty {
                        collectionView.insertSections(IndexSet(integersIn: appended))
                    }
                    if !changed.isEmpty {
                        collectionView.reconfigureItems(at: changed.map { indexPath(for: $0) })
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.reconcileAutoplay() }
            return
        }
        if change == .identical, wasSkeleton == skeleton {
            // Same stretches, same posts in them: only what a post SAYS moved.
            // A count alone is written onto the cell on screen, as on the
            // other styles; anything else is reconfigured.
            let changed = postsBefore.indices.filter { postsBefore[$0] != posts[$0] }
            guard !changed.isEmpty || completenessChanged else { return }
            let visible = Set(collectionView.indexPathsForVisibleItems)
            let countsOnly = changed.filter {
                visible.contains(indexPath(for: $0)) && Self.differOnlyInCounts(postsBefore[$0], posts[$0])
            }
            let reconfigured = changed.filter { !countsOnly.contains($0) }
            for index in countsOnly {
                switch collectionView.cellForItem(at: indexPath(for: index)) {
                case let row as PostGridListRowCell: row.updateCounts(from: posts[index])
                case let tile as PostGridTileCell: tile.updateCounts(from: posts[index])
                default: break
                }
            }
            if !reconfigured.isEmpty {
                collectionView.reconfigureItems(at: reconfigured.map { indexPath(for: $0) })
            }
            #if DEBUG
            debugRecountedItems += countsOnly.count
            debugReconfiguredItems += reconfigured.count
            #endif
            return
        }
        reloadAll(dissolving: dissolving)
    }

    /// Adopts a planned list: stretches, starts, the drawn order and which
    /// posts are tiles — derived from one value so they cannot disagree.
    private func adoptSegments(_ planned: [DiscoverSegment]) {
        segments = planned
        var starts: [Int] = []
        var flat: [GalleryPost] = []
        var tiles: Set<PostID> = []
        var paired: Set<PostID> = []
        for segment in planned {
            starts.append(flat.count)
            flat += segment.posts
            if segment.chunk != nil { tiles.formUnion(segment.posts.map(\.id)) }
            if segment.isPairs { paired.formUnion(segment.posts.map(\.id)) }
        }
        segmentStarts = starts
        posts = flat
        tilePostIDs = tiles
        pairedPostIDs = paired
        #if DEBUG
        // `-profile-segments-log`: the stretches as planned — `rows(3)@0
        // chunk(5)@3 pairs(2)@8 …`, with each one's first index.
        if ProcessInfo.processInfo.arguments.contains("-profile-segments-log") {
            let parts = zip(planned, starts).map { segment, start -> String in
                let kind = switch segment {
                case .rows: "rows"
                case .chunk: "chunk"
                case .pairs: "pairs"
                }
                return "\(kind)(\(segment.posts.count))@\(start)"
            }
            print("[profile-segments] complete=\(isCorpusComplete) \(parts.joined(separator: " "))")
        }
        #endif
    }

    /// The chunk `section` holds, or nil for cards. Asked by the layout.
    private func chunk(inSection section: Int) -> MosaicChunk? {
        guard style == .discover, !showsSkeleton, segments.indices.contains(section) else { return nil }
        return segments[section].chunk
    }

    /// Whether `section` is a block of paired half-width cards. Asked by the
    /// layout.
    private func isPairs(inSection section: Int) -> Bool {
        guard style == .discover, !showsSkeleton, segments.indices.contains(section) else { return false }
        return segments[section].isPairs
    }

    /// Where a post at `index` in `posts` lives — one section on the grid and
    /// the list, the stretch holding it on Discover.
    private func indexPath(for index: Int) -> IndexPath {
        guard style == .discover, !segmentStarts.isEmpty else { return IndexPath(item: index, section: 0) }
        // The last stretch starting at or before `index`.
        var low = 0
        var high = segmentStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segmentStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return IndexPath(item: index - segmentStarts[low], section: low)
    }

    /// The index into `posts` an index path names.
    private func flatIndex(for indexPath: IndexPath) -> Int {
        guard style == .discover, segmentStarts.indices.contains(indexPath.section) else { return indexPath.item }
        return segmentStarts[indexPath.section] + indexPath.item
    }

    /// Whether `postID` is drawn as a whole-rectangle tile — every post on the
    /// grid, a chunk's or a pair's on Discover, none on the list. What plays
    /// like a brick and hides whole for a flight.
    private func drawsAsTile(_ postID: PostID) -> Bool {
        switch style {
        case .grid: true
        case .list: false
        case .discover: tilePostIDs.contains(postID) || pairedPostIDs.contains(postID)
        }
    }

    /// The whole-table path every delivery ends on when it is not an append
    /// or an in-place update.
    private func reloadAll(dissolving: Bool) {
        let reload = {
            #if DEBUG
            self.debugReloadCount += 1
            #endif
            HeroScreenCost.measure("gallery.reload") {
                self.collectionView.reloadData()
                self.collectionView.invalidateIntrinsicContentSize()
            }
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
                HeroScreenCost.measure("landing.gallery.layout") {
                    self.collectionView.layoutIfNeeded()
                    self.reconcileAutoplay()
                }
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
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        // One section per stretch on Discover — and one empty one for an empty
        // list, the shape the other styles have when there is nothing to show.
        guard style == .discover, !showsSkeleton else { return 1 }
        return max(1, segments.count)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard !showsSkeleton else { return skeletonCount }
        guard style == .discover else { return posts.count }
        return segments.indices.contains(section) ? segments[section].posts.count : 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        // The one supplementary this page has: "View all" under a chunk.
        let footer = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: DiscoverViewAllFooterView.reuseID, for: indexPath
        ) as! DiscoverViewAllFooterView
        footer.controlAccessibilityHint = "Shows every photo and video on this profile"
        footer.onTap = { [weak self] in self?.onViewAllTapped?() }
        return footer
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        HeroScreenCost.measure("gallery.cell") { cell(at: indexPath) }
    }

    private func cell(at indexPath: IndexPath) -> UICollectionViewCell {
        if showsSkeleton {
            switch style {
            case .list, .discover:
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
        let post = posts[flatIndex(for: indexPath)]
        switch style {
        case .grid:
            return tileCell(at: indexPath, post: post,
                            cornerRadius: ChaoticSliceLayout.harmonisedCornerRadius, showsInfo: false)
        case .discover where pairedPostIDs.contains(post.id):
            // A pair's half-width card is For You's Following card: all
            // picture, its author and first lines over its foot, at the list
            // card's media corner — a tile wearing exactly that.
            return tileCell(at: indexPath, post: post,
                            cornerRadius: PostGridListRowCell.mediaCornerRadius, showsInfo: true)
        case .discover where tilePostIDs.contains(post.id):
            // A chunk's tile wears its words when it is large enough for them,
            // as For You's chunks do (`PostTileInfo`).
            return tileCell(at: indexPath, post: post,
                            cornerRadius: ChaoticSliceLayout.harmonisedCornerRadius, showsInfo: true)
        case .list, .discover:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            // ⚠️ THE SAME CARD FOR YOU DRAWS, wired the same way. A profile
            // shows reposts among the posts, so the author on the card is
            // news even here — the row is not a place to abbreviate.
            cell.configure(
                with: post,
                imagePipeline: imagePipeline,
                captionExpanded: captionExpansion.isExpanded(post.id)
            )
            // See `ForYouGridPage`: repost has no action yet, so it is not
            // drawn (#801); save toggles the shared pile and reads its answer
            // back.
            cell.onRepostTapped = repostHandler(for: post)
            // The like chip stakes — see `PostCardStaking`.
            staking?.bind(cell, to: post.id)
            // The comment chip opens the post at its thread, resolved through
            // the CELL's index path: the row can have moved under the finger.
            cell.onCommentsTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let path = self.collectionView.indexPath(for: cell) else { return }
                self.open(at: path, showingComments: true)
            }
            if let bookmarks {
                cell.isBookmarked = bookmarks.isSaved(post.id.rawValue)
                cell.onBookmarkTapped = { [weak cell] in
                    guard let cell else { return }
                    MemberGates.perform(.save, from: cell) { [weak cell] in
                        _ = bookmarks.toggle(post.id.rawValue)
                        // The fill says it; the hand feels it (#803).
                        Feedback.toggled()
                        cell?.isBookmarked = bookmarks.isSaved(post.id.rawValue)
                    }
                }
            }
            // Captured by POST, never by index path: the row that asked can
            // have moved by the time the answer is applied.
            cell.onRevealFullCaption = { [weak self] in
                guard let self else { return }
                captionExpansion.expand(post.id, in: collectionView)
            }
            // Autoplay is gated on the cover, so a cover arriving is the only
            // event that can re-open the gate for an item that came up
            // faceless while the page sat still.
            cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
            // See `ForYouGridPage`: a collection row's media is a scroll view,
            // which swallows the collection view's selection, so the tap needs
            // its own route into the same handler.
            cell.onMediaTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let path = self.collectionView.indexPath(for: cell) else { return }
                self.collectionView(self.collectionView, didSelectItemAt: path)
            }
            // The band's identity and its "...". A profile gallery's rows carry
            // an author like any other — the repository decorates them (the
            // Tagged tab is other people's posts, so the name is not always the
            // profile's own).
            if let authorID = post.authorID {
                cell.onAuthorTapped = { [weak self] in self?.onAuthorTapped?(post) }
                cell.authorMenuActions = { [weak self, weak cell] in
                    guard let self, let cell else { return [] }
                    return authorMenuActions?(
                        AuthorMenuContext(
                            post: post, authorID: authorID, anchor: cell.authorMenuAnchor
                        )
                    ) ?? []
                }
            }
            // ⚠️ CONCEALMENT IS RE-APPLIED ON EVERY CONFIGURE, keyed by post,
            // the For You grid's rule. A reload while a flight is up (the Saved
            // tab refreshes on every appearance, which a close triggers)
            // re-dequeues the flying post's cell, and an `isHidden` set on the
            // previous instance does not follow it: the tile showed under the
            // card landing on it. Also resets a recycled cell that was hidden.
            cell.setHeroConcealed(post.id == heroFlyingPostID, carrying: heroFlyingCarry)
            return cell
        }
    }

    /// A mosaic tile — the grid's every cell, Discover's chunks and pairs.
    private func tileCell(
        at indexPath: IndexPath, post: GalleryPost, cornerRadius: CGFloat, showsInfo: Bool
    ) -> PostGridTileCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath
        ) as! PostGridTileCell
        cell.cornerRadius = cornerRadius
        cell.configure(with: post, imagePipeline: imagePipeline, showsInfo: showsInfo)
        // The count's heart reads the viewer's stake, as For You's tiles do.
        if showsInfo { staking?.bindReadout(cell, to: post.id) }
        cell.onCoverLoaded = { [weak self] in self?.reconcileAutoplay() }
        // Re-applied per configure — see the row's concealment.
        cell.isHidden = post.id == heroFlyingPostID
        return cell
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
            let index = flatIndex(for: indexPath)
            guard !showsSkeleton, posts.indices.contains(index) else { return nil }
            let post = posts[index]
            // Square video stays still in a MOSAIC and plays in a timeline row,
            // for the reason `hasPlayableVideo` records — the same split the
            // For You pages make.
            // On Discover, per post: a tile plays as a brick, a card as a row.
            let playsHere = drawsAsTile(post.id) ? post.autoplaysInGrid : post.hasPlayableVideo
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
        // ⚠️ ALSO when the list is NOT empty but the surface is not visible.
        // Those candidates are discarded inside `update`, so without this arm
        // the silenced case prints nothing and is indistinguishable from a
        // gallery that simply holds no video.
        if ProcessInfo.processInfo.arguments.contains("-grid-playback-log"),
           candidates.isEmpty || !playback.debugIsSurfaceVisible {
            let visible = collectionView.indexPathsForVisibleItems
            let videos = posts.filter(\.hasPlayableVideo).count
            let realized = visible.filter { collectionView.cellForItem(at: $0) != nil }.count
            print("[profile-autoplay] none: posts=\(posts.count) videos=\(videos) "
                  + "candidates=\(candidates.count) surfaceVisible=\(playback.debugIsSurfaceVisible) "
                  + "skeleton=\(showsSkeleton) visible=\(visible.count) realized=\(realized) "
                  + "style=\(style) "
                  + "viewport=\(Int(viewport.minY))…\(Int(viewport.maxY)) "
                  + "inset=\(Int(collectionView.adjustedContentInset.top))/"
                  + "\(Int(collectionView.adjustedContentInset.bottom))")
            for indexPath in visible where posts.indices.contains(flatIndex(for: indexPath)) {
                let post = posts[flatIndex(for: indexPath)]
                guard post.hasPlayableVideo else { continue }
                let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell
                let frame = cell.map { $0.convert($0.videoMediaRect, to: collectionView) } ?? .zero
                let overlap = frame.intersection(viewport)
                let fraction = frame.height > 0 && !overlap.isNull
                    ? (overlap.height * overlap.width) / (frame.height * frame.width) : 0
                print("[profile-autoplay]   \(post.id.rawValue) shape=\(post.shape) "
                      + "playsHere=\(drawsAsTile(post.id) ? post.autoplaysInGrid : post.hasPlayableVideo) "
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
              let cell = collectionView.cellForItem(at: indexPath(for: index))
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
            // ⚠️ A PAIRED CARD FLIES AS THE LIST'S MEDIA, not as a tile: it
            // is For You's Following card, which takes off and lands on the
            // list card's curve (`.listMedia`) — its own corner.
            isTile: cell is PostGridTileCell && !pairedPostIDs.contains(postID)
        )
    }

    /// The realized cell for a post, or nil — the lookup every question below
    /// starts from.
    private func cell(for postID: PostID) -> UICollectionViewCell? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        return collectionView.cellForItem(at: indexPath(for: index))
    }

    /// The whole CARD of a text-only row, which is what a reveal's window opens
    /// from — see `TextRevealOrigin`.
    ///
    /// The mirror of `heroGeometry` above, and the pair says the transition
    /// policy out loud: that one answers with the MEDIA's rect and goes nil for
    /// a text row, which is what sends it down this path; this one answers only
    /// FOR a text row, with the card's own bounds.
    ///
    /// Nil for anything that is not a realized text row — a media row, a tile,
    /// or a post scrolled out of the viewport. The reveal then falls back to a
    /// centred window, exactly as a hero falls back to a centred collapse.
    func textRowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let row = cell(for: postID) as? PostGridListRowCell,
              row.mediaHeroRect == nil
        else { return nil }
        // The WHOLE card. Departing from below the author band was the first
        // attempt and the frames killed it: a window that stops short of the
        // card's top leaves the band outside the transition, so the card gains
        // it in one frame at the landing. The offset is carried instead — see
        // `PostGridListRowCell.revealCaptionTop`.
        return row.convert(row.bounds, to: space)
    }

    /// Where the page stops matching the row, in the row's own space — the
    /// reveal's cut line. Nil when the row is not realized.
    /// How far below the row's top its caption begins — the band's height plus
    /// its gap, or zero. See `PostGridListRowCell.revealCaptionTop`.
    func textRowCaptionTop(for postID: PostID) -> CGFloat {
        (cell(for: postID) as? PostGridListRowCell)?.revealCaptionTop ?? 0
    }

    func textRowCaptionEnd(for postID: PostID) -> CGFloat? {
        (cell(for: postID) as? PostGridListRowCell)?.revealCut
    }

    /// The card a dismissal carries home, drawn at the ROW's own width so its
    /// caption wraps and truncates exactly as the row's does.
    ///
    /// Without one the close flies the live PAGE, which only works while the
    /// page still shows, in the same place, what the card shows — and a viewer
    /// who scrolled the comments has already broken that. Same view For You
    /// flies, because a viewer opening the same post from either screen is
    /// looking at one screen and must get one transition.
    /// ⚠️ THE ANY-KIND FLOOR under `textRowFrame`, which refuses a row carrying
    /// media on purpose.
    ///
    /// A close whose anchor turned out to be a photograph asked for a rect, was
    /// told nil, and landed on a 96pt square in the middle of the screen — a
    /// white card floating over the list, unaligned with anything. Filmed. For
    /// You added this floor for the same reason and this list never got it.
    func rowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = cell(for: postID) else { return nil }
        return cell.convert(cell.bounds, to: space)
    }

    func makeDismissStandIn(for postID: PostID) -> UIView? {
        guard let post = posts.first(where: { $0.id == postID }) else { return nil }
        // The realized row's width when there is one, the list's own otherwise:
        // a row scrolled out still has to produce a card, and the width is a
        // property of the LIST rather than of any particular cell.
        let width = cell(for: postID)?.bounds.width ?? collectionView.bounds.width
        guard width > 0 else { return nil }
        return RevealDismissCardView(
            post: post,
            width: width,
            imagePipeline: imagePipeline,
            // See For You's twin: the expansion belongs to the surface, and a
            // stand-in built without it lands a truncated card on an expanded
            // row.
            captionExpanded: captionExpansion.isExpanded(postID),
            showsAuthorMenu: showsAuthorMenu(for: post),
            // What the row wires — see `configure`: repost once something
            // handles it (#801), save when there is a pile — so the stand-in
            // lands on a card drawing the same controls rather than ending
            // with one vanishing.
            actions: .init(
                repost: onRepostRequested != nil, bookmark: bookmarks != nil,
                saved: bookmarks?.isSaved(postID.rawValue) ?? false,
                // And the like as the row draws it — see For You's twin.
                stake: staking?.viewerStake(on: postID)
            ),
            // The row's own date when there is a row — a compact age is a
            // function of the clock, and the row worked its own out when it was
            // configured.
            ageText: (cell(for: postID) as? PostGridListRowCell)?.renderedAgeText,
            // The ROW's own height when it is realized — the card is centred
            // in the window, so a height that disagrees with the row's puts
            // every line inside it half the difference out.
            height: cell(for: postID)?.bounds.height
        )
    }

    /// Whether the row for `post` draws a "...", asked of the same provider the
    /// row itself asks.
    ///
    /// The stand-in has to match, and on THIS surface the answer is often no: a
    /// viewer's own post offers nothing, so a stand-in that always drew the
    /// control ended every dismissal with it vanishing.
    ///
    /// The provider rather than the realized cell, because a row that scrolled
    /// out still has to produce a card and cannot be asked what it is showing.
    private func showsAuthorMenu(for post: GalleryPost) -> Bool {
        guard let authorID = post.authorID, let authorMenuActions else { return false }
        // The anchor is only ever read to place a popover, and nothing is being
        // presented here — this asks the provider what it WOULD offer.
        let context = AuthorMenuContext(post: post, authorID: authorID, anchor: UIView())
        return !authorMenuActions(context).isEmpty
    }

    /// The row's author band, for the destination to borrow during a flight, so
    /// the window a viewer holds shows the header the card does instead of a
    /// blank strip the card's own header then appears into.
    ///
    /// Read from the POST rather than from the cell, so it answers for a row
    /// that has scrolled out as readily as for one on screen.
    func textRowAuthorBand(for postID: PostID) -> PostAuthorBandView.Model? {
        if let row = cell(for: postID) as? PostGridListRowCell { return row.authorBandModel }
        return posts.first { $0.id == postID }.map { PostAuthorBandView.Model(post: $0) }
    }


    /// Hides just what the transition is carrying: a tile goes whole, and a row
    /// gives up its preview to a FLIGHT and its whole card to a WINDOW. Same
    /// invariant the For You grid keeps, and `carrying` is how the caller says
    /// which — see `PostGridListRowCell.HeroCarry`.
    func setHeroConcealed(
        _ concealed: Bool,
        for postID: PostID,
        carrying carry: PostGridListRowCell.HeroCarry = .media
    ) {
        heroFlyingPostID = concealed ? postID : nil
        heroFlyingCarry = carry
        if !concealed { reconcileAutoplay() }
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let cell = collectionView.cellForItem(at: indexPath(for: index))
        else { return }
        if let row = cell as? PostGridListRowCell {
            // The CALLER says what it carried; the row hides that much. Reading
            // the row's own kind instead is what left a media row's words on
            // screen under a window that was drawing them too.
            row.setHeroConcealed(concealed, carrying: carry)
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
        let path = indexPath(for: index)
        // REALIZED FIRST, and it is not a convenience. A finger can only tap a
        // row that is on screen, and this page shows very few at rest — the
        // header takes most of the screen, so an Activity list of nine posts
        // had exactly one realized cell. Selecting straight through opened a
        // post whose cell had never existed, and every rect the transition then
        // asked for came back nil: the reveal departed from its centred
        // fallback and the capture read as a broken transition rather than as a
        // harness tapping through the floor.
        //
        // Scrolls ONLY when the row is not already realized, so a run that
        // could have happened under a thumb is not turned into a travelling
        // list.
        if collectionView.cellForItem(at: path) == nil {
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        collectionView(collectionView, didSelectItemAt: path)
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
        let rect = collectionView.layoutAttributesForItem(at: indexPath(for: index))?.frame
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
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard !showsSkeleton, flatIndex(for: indexPath) >= posts.count - Self.nearEndTileCount else { return }
        onNearEnd?()
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
        open(at: indexPath, showingComments: false)
    }

    /// Both ways into a post — the card, and its comment chip.
    private func open(at indexPath: IndexPath, showingComments: Bool) {
        let index = flatIndex(for: indexPath)
        guard !showsSkeleton, posts.indices.contains(index) else { return }
        // Same contract as the For You grids: the flight leaves from where
        // the tile IS, and the reveal waits until the post has covered this
        // page (`applyPendingReveal`). Moving the grid under the thumb at tap
        // time is a jump the viewer is looking straight at.
        let post = posts[index]
        pendingRevealPostID = post.id
        let stream = Array(posts[index...].prefix(Self.streamWindow))
        // ⚠️ A TEXT POST'S COMMENTS ARE ITS PAGE — see `ForYouGridPage.open`.
        if showingComments, post.kind != .text, let openComments = onItemCommentsTapped {
            openComments(post, stream)
        } else {
            onItemTapped?(post, stream)
        }
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
        let visibleBottom = bounds.height - baseBottomInset
        let blockHeight = emptyStateHeight
        let centre = ProfileEmptyStatePlacement.centreY(
            visibleTop: visibleTop, visibleBottom: visibleBottom, blockHeight: blockHeight
        )
        statusTopConstraint?.constant = centre - verticalOffset
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-profile-layout-audit"), !emptyStateView.isHidden {
            print(String(format: "PROFILE-EMPTY-STATE pageH=%.0f visibleTop=%.0f visibleBottom=%.0f "
                         + "block=%.0f centre=%.0f offset=%.0f bottomInset=%.0f",
                         bounds.height, visibleTop, visibleBottom, blockHeight,
                         centre, verticalOffset, baseBottomInset))
        }
        #endif
    }

    /// The empty state's own height — asked of it rather than assumed, because
    /// the block's height is its glyph, title, subtitle and optional action, and
    /// which of those it carries changes with the state being shown.
    ///
    /// ⚠️ Measured once per state and width, not per scroll: it is read on
    /// every frame the page moves — on a page with posts, where the block is
    /// not even shown — and each read was a fitting pass.
    private var emptyStateHeight: CGFloat {
        let key = EmptyStateKey(
            width: bounds.width, revision: emptyStateRevision,
            contentSize: traitCollection.preferredContentSizeCategory
        )
        if let cached = emptyStateHeightCache, cached.key == key { return cached.height }
        #if DEBUG
        debugEmptyStateMeasureCount += 1
        #endif
        let height = emptyStateView.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        emptyStateHeightCache = (key, height)
        return height
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

    /// ⚠️ THE SNAP IS WRITTEN INTO THE TARGET, not applied after the fact.
    ///
    /// Moving the offset once deceleration has finished is a second motion
    /// the viewer sees start. Rewriting where the deceleration is heading,
    /// here, folds the snap into the one motion already under way — the
    /// scroll simply arrives at the detent as if that were where it was
    /// always going.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        pendingSnap = nil
        let inset = scrollView.contentInset.top
        let target = targetContentOffset.pointee.y + inset
        let snapped = ProfileScrollDetents.snapped(target: target, detents: snapDetents)
        #if DEBUG
        // `-profile-snap-audit`: where a release was heading, and where it
        // was sent instead.
        if ProcessInfo.processInfo.arguments.contains("-profile-snap-audit") {
            print("[profile-snap] from=\(Int(verticalOffset)) target=\(Int(target)) velocity=\(Int(velocity.y * 100))"
                + " detents=\(snapDetents.map { Int($0) }) → \(snapped.map { String(Int($0)) } ?? "free")")
        }
        #endif
        guard let snapped, abs(snapped - target) > 0.5 else { return }
        targetContentOffset.pointee.y = snapped - inset
        // With no momentum the scroll view stops where the finger left it and
        // ignores the target, so the snap has to be driven by hand.
        if abs(velocity.y) < 0.01 { pendingSnap = snapped - inset }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reconcileAutoplay() }
        onPullReleased?(max(0, -verticalOffset))
        if !decelerate, let pendingSnap {
            self.pendingSnap = nil
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: pendingSnap), animated: true)
        }
    }
}
