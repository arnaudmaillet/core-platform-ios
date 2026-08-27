import CoreModels
import CoreStorage
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
/// Lets a layout built in `init` ask the page that owns it a question, without
/// either holding the other alive. See `ForYouGridPage.init`.
@MainActor
private final class WeakPageBox {
    weak var page: ForYouGridPage?
}

final class ForYouGridPage: UIView {
    /// The saved-posts pile, shared with the post page and the profile's Saved
    /// tab through `UserDefaults` — see `PostBookmarkStore`.
    private let bookmarks = PostBookmarkStore()

    /// The viewer asked to repost. UNSET today — see the note at the wiring
    /// site: the control is drawn because the card's design calls for it, and
    /// there is no client path that publishes a repost yet.
    var onRepostRequested: ((GalleryPost) -> Void)?

    /// The page's fixed shape, chosen by its format at init.
    enum Style {
        case grid
        case list
    }

    /// The tapped item's index into `posts`.
    var onItemTapped: ((Int) -> Void)?

    /// The same open, with the comments already engaged — see
    /// `PostGridListRowCell.onCommentsTapped`.
    ///
    /// ⚠️ FALLS BACK TO `onItemTapped` when unset, and that is not politeness.
    /// The chip is drawn by the cell on every screen this page appears on; a
    /// host that has not wired the shorter route must still get the ordinary
    /// one, or the count becomes a control that does nothing on exactly the
    /// screens nobody thought about.
    var onItemCommentsTapped: ((Int) -> Void)?

    /// The posts whose cards are ON SCREEN and worth warming — their first page
    /// of comments, and anything else a host wants ready before a tap.
    ///
    /// ⚠️ IT RIDES THE AUTOPLAY RECONCILE, deliberately, which is what gives it
    /// the fling gate for free. A feed that warms while the viewer is throwing
    /// it spends a request per card it will never show for longer than a
    /// glance; the same argument that stops a player being ATTACHED above
    /// `maximumStartVelocity` stops the warm above it, and the two can never
    /// drift apart because they are one decision.
    var onWarmRequested: (([GalleryPost]) -> Void)?
    /// The page scrolled near its end and wants another page.
    var onNearEnd: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// A row's author was tapped — its disc, its name or its handle.
    var onAuthorTapped: ((GalleryPost) -> Void)?
    /// What a row's "..." should offer. Asked at press time, per row.
    ///
    /// The page holds no opinion about the answer: which rows exist depends on
    /// what the SCREEN can service (a reporting seam, a social graph), and this
    /// view has neither. It supplies the context and renders whatever comes
    /// back — including nothing, which hides the control.
    var authorMenuActions: ((AuthorMenuContext) -> [PostCardMenuAction])?

    /// Everything a host needs to build one row's menu.
    struct AuthorMenuContext {
        let post: GalleryPost
        let authorID: ProfileID
        /// The control that was pressed, for a popover-shaped follow-up sheet.
        let anchor: UIView
    }

    /// Display order — the mosaic's arrangement of `rawPosts`. What the cells,
    /// the hero, and a tile tap all read.
    private(set) var posts: [GalleryPost] = []
    /// The order the view model handed over, kept so an append can be
    /// recognised as one before arrangement permutes it.
    private var rawPosts: [GalleryPost] = []

    /// WHICH posts arrived since the session opened. The page is TOLD this
    /// rather than deriving it, so the header and the tab badge cannot be two
    /// answers to one question — see `ForYouViewModel.onNewPostsChange`.
    private var newPostIDs: Set<PostID> = []

    /// Where the "New" section ends, or 0 for a list that is one plain run.
    ///
    /// Read off `posts` rather than stored, because `posts` is kept partitioned
    /// — the arrivals lead it. Three conditions, and each removes a header that
    /// would say nothing: a grid page is a ranked mosaic with no "since" to
    /// divide on; a skeleton has no posts to have arrived; and a corpus that is
    /// ENTIRELY new would put "New" over everything and "Recent" over nothing,
    /// which is a label rather than a division. The inbox lists follow the same
    /// rule for the same reason.
    private var split: Int {
        guard style == .list, !showsSkeleton, !newPostIDs.isEmpty else { return 0 }
        let leading = posts.prefix { newPostIDs.contains($0.id) }.count
        return leading < posts.count ? leading : 0
    }

    /// Arrivals first, everything else after, each half keeping the order it
    /// arrived in.
    ///
    /// ⚠️ **This reorders the list, and it has to.** The display order is
    /// whatever the discovery source ranked — Trending puts the most-reacted
    /// posts on top — so the arrivals are scattered through it. A "New" header
    /// over the leading rows would then be over the wrong rows. Sections mean
    /// the list is grouped, and grouping is a reordering; the inbox's lists do
    /// exactly this. Within each half nothing moves, so the ranking still
    /// decides everything it can still decide.
    private func partitioned(_ list: [GalleryPost]) -> [GalleryPost] {
        guard style == .list, !newPostIDs.isEmpty else { return list }
        var arrivals: [GalleryPost] = []
        var earlier: [GalleryPost] = []
        for post in list {
            if newPostIDs.contains(post.id) { arrivals.append(post) } else { earlier.append(post) }
        }
        return arrivals + earlier
    }

    /// The sections this page currently has, in order.
    private var sections: [Section] {
        split > 0 ? [.new, .earlier] : [.earlier]
    }

    /// The two halves of a sectioned list, and the words they wear.
    ///
    /// The SAME pair the inbox uses — "New" and "Recent". A viewer moving
    /// between Messages and For You should not have to re-read a header to
    /// learn that it means what the last one meant.
    private enum Section {
        case new
        case earlier

        var title: String {
            switch self {
            case .new: "New"
            case .earlier: "Recent"
            }
        }
    }

    /// Where a flat index into `posts` lives in the sectioned list.
    private func indexPath(for index: Int) -> IndexPath {
        let split = split
        guard split > 0 else { return IndexPath(item: index, section: 0) }
        return index < split
            ? IndexPath(item: index, section: 0)
            : IndexPath(item: index - split, section: 1)
    }

    /// The flat index into `posts` an index path names.
    private func flatIndex(for indexPath: IndexPath) -> Int {
        indexPath.section == 0 ? indexPath.item : split + indexPath.item
    }

    /// Armed when the next content to arrive is a re-derived corpus rather than
    /// an extended one. Consumed by the `apply` that follows.
    private var mustReload = false

    /// The corpus this page is about to be handed was RE-DERIVED — a lens
    /// change or a re-ordering — so whatever similarity it bears to what is on
    /// screen is a coincidence, not an append. See `ForYouViewModel.onCorpusReset`.
    func invalidateIncrementalUpdates() {
        mustReload = true
    }

    /// Whether appending `count` posts leaves the section structure alone, so
    /// the append can stay an insert rather than becoming a reload.
    ///
    /// A page landing is always OLDER content, so it joins the second half and
    /// the leading run of arrivals is untouched. The only structural move is a
    /// list that was entirely new gaining its first non-new row.
    private func splitWouldHold(afterAppending count: Int, to current: Int) -> Bool {
        guard style == .list else { return true }
        let leading = posts.prefix { newPostIDs.contains($0.id) }.count
        let after = leading < posts.count + count ? leading : 0
        return after == current
    }

    /// Adopts a new set of arrivals. Re-groups the rows and reloads, because
    /// both which section a row is in and how many sections there are can move.
    func setNewPosts(_ ids: Set<PostID>) {
        guard newPostIDs != ids else { return }
        newPostIDs = ids
        posts = partitioned(posts)
        collectionView.reloadData()
    }

    /// Grid pages steer each post into the block whose shape crops it least;
    /// list pages are a timeline, where order carries meaning and must not be
    /// rearranged for looks.
    ///
    /// The slot shapes come from the layout rather than from a table, because a
    /// BSP tiling generates them — see `PostGridSliceArrangement`. Before the
    /// page has been laid out there are no shapes yet and this is the identity;
    /// `onPlanInvalidated` re-runs it when geometry resolves.
    private func arrange(_ posts: [GalleryPost], startingAt index: Int) -> [GalleryPost] {
        guard style == .grid, let sliceLayout else { return posts }
        return PostGridSliceArrangement.arranged(
            posts, startingAt: index,
            slotMetrics: sliceLayout.slotMetrics(forItemCount: index + posts.count)
        )
    }

    private var sliceLayout: ChaoticSliceLayout? {
        collectionView.collectionViewLayout as? ChaoticSliceLayout
    }

    /// The rounding this page's tiles take, paired with the layout's gutter.
    /// List pages fall back to the tile default, which they never use.
    private var tileCornerRadius: CGFloat {
        sliceLayout?.tileCornerRadius ?? PostGridTileCell.mosaicCornerRadius
    }

    /// Re-places every post against slot shapes that have just changed — a
    /// rotation, or any resize that alters the slice's aspect and therefore what
    /// shape each block is.
    ///
    /// Guarded on the two states where moving a cell would be destructive: a
    /// staged dismissal has already measured where its card is landing, and a
    /// hidden hero means a card is in the air over a tile that must not move
    /// out from under it. Reloading is also skipped when the new arrangement
    /// matches the old, which is the common case on first layout and keeps the
    /// cold start to a single reload.
    private func replanArrangement() {
        guard style == .grid, !showsSkeleton, !rawPosts.isEmpty,
              heroHiddenPostID == nil
        else { return }
        let rearranged = arrange(rawPosts, startingAt: 0)
        guard rearranged.map(\.id) != posts.map(\.id) else { return }
        posts = rearranged
        collectionView.reloadData()
        DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
    }

    private let imagePipeline: ImagePipeline
    /// Autoplay for video media, on both shapes — absent only where the host
    /// didn't supply a player pool.
    ///
    /// List pages used to be excluded outright ("a timeline row is a reading
    /// surface, not a viewing one"). They now play on the same centre-ranked
    /// terms as the mosaic. The concurrency is the whole difference between the
    /// two shapes' playback — everything below this line is shared.
    private let playback: GridVideoPlaybackCoordinator?
    /// The pool itself, held only so the audit can ask whether a surface is
    /// ADVANCING — a question the coordinator does not answer, because "playing"
    /// there means "holds a loan", not "is moving".
    private let videoPool: VideoPlaybackController?

    /// How many videos may play at once, per shape.
    ///
    /// Both surfaces rank candidates by distance from the viewport centre and
    /// keep the nearest N; N is the only thing that differs. Five for a
    /// timeline rather than the mosaic's six because a column fits fewer
    /// previews on screen at once, so the sixth slot would go to a row well
    /// outside the viewport — and the idle-player cache is six, which the two
    /// pages share.
    static func concurrentPlayers(for style: Style) -> Int {
        style == .grid ? 6 : 5
    }
    private let style: Style
    private let collectionView: UICollectionView
    /// The centred "nothing here" block, shared with every other surface that
    /// has to say it. Hidden unless the page is genuinely empty or failed.
    private let emptyState = EmptyStateView()
    private let refreshControl = UIRefreshControl()
    private var showsSkeleton = false
    /// The post whose cell is standing in for a flight card and must stay
    /// invisible until the card lands. See `setHeroHidden`.
    private var heroHiddenPostID: PostID?
    /// The exact cell hidden at takeoff.
    ///
    /// Held by reference because the post→cell mapping is not stable across a
    /// flight: staging swaps the active post into the departure slot, so by
    /// landing `cell(for:)` resolves the anchor to a DIFFERENT instance than the
    /// one the hide was applied to. Unhiding by lookup therefore cleared the
    /// wrong cell and left the original invisible for good — with the flag
    /// correctly nil, which is why it survived every check that looked at the
    /// flag. Weak: the collection view owns cells and may recycle this one,
    /// and a recycled cell is corrected by `cellForItemAt` anyway.
    private weak var heroHiddenCell: UICollectionViewCell?
    /// The post whose twin is in the air, concealed or not.
    ///
    /// Split from `heroHiddenPostID` because the two questions came apart: a
    /// dismissal wants its landing tile VISIBLE under the incoming card, but
    /// still must not let it claim a player while the card is flying that same
    /// playback.
    private var heroFlyingPostID: PostID?
    /// The inset to hand back when a flight ends; non-nil means frozen.
    private var frozenContentInset: UIEdgeInsets?
    /// The post to bring clear of the chrome once this page is out of sight.
    /// Held as an ID rather than an index path because the corpus can change
    /// while the post is open — a page can land, or a lens can re-derive the
    /// whole list — and an index would then name a different post.
    private var pendingRevealPostID: PostID?
    /// Which captions the viewer has opened out. Owned here rather than by the
    /// rows, which are recycled — see `CaptionExpansion`.
    private let captionExpansion = CaptionExpansion()
    /// The row a REVEAL is currently holding, hidden until its window lands.
    ///
    /// Its own slot, deliberately not `heroHiddenPostID`. Sharing that one was
    /// the first attempt and the frames caught it: a media flight ending
    /// anywhere on this grid calls `setHeroHidden(false, …)`, which nulls the
    /// flag for WHATEVER post it names and then sweeps every visible cell —
    /// and the sweep only knows how to un-hide a preview. So a reveal's row
    /// came back mid-grab, and the viewer held a window with a second copy of
    /// the same post sitting underneath it.
    ///
    /// Two flights, two kinds of concealment, two slots. They are OR-ed at the
    /// one place that applies them, so neither can clear the other.
    private var revealConcealedPostID: PostID?
    /// Throttle state for the during-scroll autoplay reconcile.
    private var lastReconcileTime: CFTimeInterval = 0
    private var lastReconcileOffset: CGFloat = 0
    #if DEBUG
    private var hasScheduledDiagnostics = false
    #endif

    /// List pages show a column of placeholder cards; the grid shows two full
    /// slices — a scrolling page has a whole viewport to fill, and a slice is
    /// only a little over one screenful.
    private var skeletonCount: Int {
        style == .grid ? (sliceLayout?.cellsPerSlice ?? ChaoticSliceEngine.defaultCellsPerSlice) * 2 : 6
    }

    /// How close to the end a scroll gets before the next page is requested.
    private static let prefetchDistance: CGFloat = 800

    init(imagePipeline: ImagePipeline, style: Style, videoPlayback: VideoPlaybackController? = nil) {
        self.imagePipeline = imagePipeline
        videoPool = videoPlayback
        #if DEBUG
        CarouselPlaybackAudit.capturePoolTrace()
        #endif
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: Self.concurrentPlayers(for: style))
        }
        self.style = style
        // `headerHost` breaks the chicken-and-egg: the layout needs to ask the
        // page which sections are titled, and the page does not exist until
        // after `super.init`. The box is filled in below, and the layout only
        // ever asks during a layout pass — long after that.
        let headerHost = WeakPageBox()
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: style == .grid
                ? ChaoticSliceLayout()
                : PostGridListLayout.layout(hasHeader: { [headerHost] index in
                    headerHost.page?.hasHeader(inSection: index) ?? false
                })
        )
        super.init(frame: .zero)
        headerHost.page = self

        sliceLayout?.onPlanInvalidated = { [weak self] in self?.replanArrangement() }
        pagingSpinner.alpha = 0
        pagingSpinner.hidesWhenStopped = false
        collectionView.addSubview(pagingSpinner)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        // No indicators: the header floats over these pages, so a vertical bar
        // runs the whole viewport and crosses the chrome instead of stopping
        // under it. Same reason as the profile's pages.
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.register(PostGridTileCell.self, forCellWithReuseIdentifier: PostGridTileCell.reuseID)
        collectionView.register(PostGridListRowCell.self, forCellWithReuseIdentifier: PostGridListRowCell.reuseID)
        collectionView.register(
            PostGridSkeletonTileCell.self, forCellWithReuseIdentifier: PostGridSkeletonTileCell.reuseID
        )
        collectionView.register(
            PostGridSkeletonListCell.self, forCellWithReuseIdentifier: PostGridSkeletonListCell.reuseID
        )
        collectionView.register(
            ForYouSectionHeaderView.self,
            forSupplementaryViewOfKind: PostGridListLayout.headerElementKind,
            withReuseIdentifier: ForYouSectionHeaderView.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        refreshControl.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        collectionView.pin(to: self)

        // Centred in the page, and pinned to the page rather than to the
        // collection view: a scroll view's centre moves with its content
        // insets, so an empty state hung inside one drifts down as chrome is
        // added above it. The page's own bounds do not move.
        //
        // Not user-interactive, so a pull-to-refresh started on top of the
        // message still reaches the scroll view underneath — the empty state is
        // exactly where someone reaches to pull.
        emptyState.isUserInteractionEnabled = false
        emptyState.isHidden = true
        emptyState.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The content inset the pager's owner needs to clear with its tray — the
    /// page scrolls under it, so the last row must be reachable above it.
    var additionalBottomInset: CGFloat {
        get { trayInset }
        set {
            trayInset = newValue
            applyBottomInset()
        }
    }

    /// The tray's clearance and the paging footer's, kept apart because they
    /// change independently and both land on the same inset.
    private var trayInset: CGFloat = 0
    private var footerInset: CGFloat = 0

    private func applyBottomInset() {
        // A hero flight pins the inset so its landing measurement stays valid —
        // see `beginHeroFreeze`. Writing to it here would unpick that, so the
        // value is held and applied when the flight thaws.
        guard frozenContentInset == nil else { return }
        var bottom = trayInset + footerInset + hostedBottomInset
        if hostedTopInset != nil {
            // Hosted pages must be ABLE to travel the header's full distance
            // whatever they hold — a short tab with nowhere to put the viewer
            // is what makes the header snap back on a tab switch (the same
            // rule, for the same reason, as the profile grid's
            // `setMinimumScrollTravel`). The room is empty space below the
            // last row.
            let needed = minimumScrollTravel
                + collectionView.bounds.height
                - collectionView.contentSize.height
                - collectionView.contentInset.top
            bottom = max(bottom, needed)
        }
        // Value-guarded: this runs per scroll tick in hosted mode, and an
        // unconditional write mid-drag disturbs the pan.
        guard abs(collectionView.contentInset.bottom - bottom) > 0.5 else { return }
        collectionView.contentInset.bottom = bottom
        collectionView.verticalScrollIndicatorInsets.bottom =
            trayInset + footerInset + hostedBottomInset
    }

    // MARK: - Hosted collapsible header (the Place Profile's mechanics)

    /// The page's distance from its content top, every scroll tick — what a
    /// floating header rides. Fired for every page; a pager gates on the
    /// active one.
    var onVerticalScroll: ((CGFloat) -> Void)?

    /// Where this page is scrolled to, measured from the top of its CONTENT
    /// rather than from its own origin: hosted pages rest at `-inset`, and
    /// reporting travel keeps every caller out of that arithmetic.
    var verticalOffset: CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    /// Non-nil once hosted — the height of the header floating above.
    private var hostedTopInset: CGFloat?
    private var hostedBottomInset: CGFloat = 0
    private var minimumScrollTravel: CGFloat = 0

    /// Puts the page under a floating header: `top` is the header's height
    /// (content starts below it, scrolls under it), `bottom` the chrome at the
    /// screen's foot. Switches inset management to manual (`.never`) — the
    /// host's safe areas are the header's business now, and UIKit adding its
    /// own on top double-counted the bar region.
    func setHostedInsets(top: CGFloat, bottom: CGFloat) {
        guard hostedTopInset != top || hostedBottomInset != bottom else { return }
        let travelled = verticalOffset
        hostedTopInset = top
        hostedBottomInset = bottom
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = top
        collectionView.verticalScrollIndicatorInsets.top = top
        // Changing the inset moves the content under a stationary offset, so
        // the offset is restated to keep the page where it was.
        collectionView.contentOffset.y = travelled - top
        applyBottomInset()
    }

    /// How far this page must be able to scroll, whatever it holds — see the
    /// note in `applyBottomInset`.
    func setMinimumScrollTravel(_ travel: CGFloat) {
        guard minimumScrollTravel != travel else { return }
        minimumScrollTravel = travel
        applyBottomInset()
    }

    /// Scrolls to a travel offset, clamped to what the content can hold.
    /// What keeps a floating header still across a tab switch: the page
    /// arriving is put level with the page leaving BEFORE it shows.
    func setVerticalOffset(_ offset: CGFloat) {
        // Make room BEFORE asking the page to travel: on a tab switch the
        // page may not have laid out since its content arrived, and it would
        // clamp against a range that has not been extended yet.
        collectionView.layoutIfNeeded()
        applyBottomInset()
        let inset = collectionView.adjustedContentInset.top
        let travel = collectionView.contentSize.height
            + inset
            + collectionView.contentInset.bottom
            - collectionView.bounds.height
        let target = offset < 0 ? offset : min(offset, max(0, travel))
        guard abs(verticalOffset - target) > 0.5 else { return }
        collectionView.contentOffset = CGPoint(x: 0, y: target - inset)
    }

    // MARK: - Paging footer

    /// The band reserved below the content while the next page is in flight.
    ///
    /// The tray's own clearance cannot serve here: it is exactly the height the
    /// tray floats over, so anything parked in it sits *behind* the tray at full
    /// scroll. The footer adds its own space above that.
    private static let footerHeight: CGFloat = 56

    private let pagingSpinner = UIActivityIndicatorView(style: .medium)
    private var isPaging = false

    /// Shows or hides the next-page spinner beneath the last tile.
    ///
    /// **Why this cannot jump the scroll.** Reserving the band happens when
    /// pagination fires, which is `prefetchDistance` (800pt) before the end —
    /// growing the bottom inset never moves `contentOffset`, so there is nothing
    /// to see. Releasing it happens once the page has landed and added a whole
    /// slice of content, by which point the viewer is far from the bottom and
    /// the offset cannot be clamped by 56pt. The animation covers the one case
    /// left: a page that lands empty, where the release can nudge a viewer
    /// sitting at the very end.
    func setPaging(_ paging: Bool) {
        guard style == .grid, isPaging != paging else { return }
        isPaging = paging
        if paging {
            pagingSpinner.startAnimating()
            positionPagingFooter()
        }
        footerInset = paging ? Self.footerHeight : 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.applyBottomInset()
            self.pagingSpinner.alpha = paging ? 1 : 0
        } completion: { _ in
            if !self.isPaging { self.pagingSpinner.stopAnimating() }
        }
    }

    /// Parks the spinner just under the content, in the scroll view's own
    /// coordinates, so it travels with the last row instead of floating over it.
    private func positionPagingFooter() {
        guard isPaging else { return }
        let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
        pagingSpinner.center = CGPoint(
            x: collectionView.bounds.width / 2,
            y: contentHeight + Self.footerHeight / 2
        )
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
        requestWarm(allowingStarts)
        guard let playback else { return }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let centreY = viewport.midY
        let candidates = collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> GridVideoPlaybackCoordinator.Candidate? in
            guard !showsSkeleton, posts.indices.contains(flatIndex(for: indexPath)) else { return nil }
            let post = posts[flatIndex(for: indexPath)]
            guard post.id != heroFlyingPostID, // its twin is in the air
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell,
                  let held = playableURL(for: post, in: cell),
                  hasCover(for: post, in: cell)
            else { return nil }
            // Held versus ADVANCING. A row keeps its player while the viewer is
            // on another page of the same collection — the clip is still on
            // screen there, peeking, and stopping it would put that page's
            // thumbnail back.
            // ⚠️ A SINGLE ATTACHMENT IS ALWAYS ON ITS OWN PAGE.
            //
            // `currentPageVideoURL` answers for a CAROUSEL and is nil for a row
            // showing one video — so comparing it to the held URL said "not
            // advancing" for every single-video row in the feed, and the
            // coordinator dutifully started each one and paused it on its first
            // frame. Reported as "the first frame is there but the media does
            // not advance", with a recording that shows exactly that.
            //
            // The question only means anything for a collection: is the viewer
            // on the clip's page, or on a photograph beside it.
            let advancing = (cell as? PostGridListRowCell).map {
                !$0.showsCarousel || $0.currentPageVideoURL == held
            } ?? true

            // Measured against the cell's MEDIA, which each shape locates for
            // itself (`videoMediaRect`) — a tile's is its bounds, a row's is
            // the preview box inside its card.
            let frame = cell.convert(cell.videoMediaRect, to: collectionView)
            let visible = frame.intersection(viewport)
            guard !visible.isNull, frame.height > 0,
                  (visible.height * visible.width) / (frame.height * frame.width)
                      >= Self.minimumVisibleFraction
            else { return nil }

            return .init(
                id: post.id, url: held, cell: cell,
                distanceFromCentre: abs(frame.midY - centreY),
                isPaused: !advancing
            )
        }
        playback.update(candidates: candidates, allowingStarts: allowingStarts)
        preloadAutoplayCovers(around: collectionView.indexPathsForVisibleItems)
        #if DEBUG
        logRejectedCandidates(chosen: Set(candidates.map(\.id)))
        auditCarouselPlayback()
        #endif
    }

    #if DEBUG
    /// ⚠️ THE DENOMINATOR THE RANKING LOG NEVER HAD.
    ///
    /// `[grid-rank]` reports what was CHOSEN, and an empty ranking reads
    /// exactly like a page of photographs — which is how "no video row on this
    /// page plays at all" stayed invisible while the log looked clean. Each
    /// rejection below is a different reason a row can hold a clip and still
    /// never reach the coordinator, and each is a different bug when it is the
    /// wrong answer.
    private func logRejectedCandidates(chosen: Set<PostID>) {
        guard ProcessInfo.processInfo.arguments.contains("-grid-playback-log"),
              !showsSkeleton
        else { return }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            let index = flatIndex(for: indexPath)
            guard posts.indices.contains(index) else { continue }
            let post = posts[index]
            guard !chosen.contains(post.id),
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell
            else { continue }
            let row = cell as? PostGridListRowCell
            let held = playableURL(for: post, in: cell)
            // A row with no clip anywhere is the ordinary case and says
            // nothing; everything else is worth a line.
            guard held != nil || post.kind == .video || post.isCollection else { continue }
            let frame = cell.convert(cell.videoMediaRect, to: collectionView)
            let visible = frame.intersection(viewport)
            let fraction = visible.isNull || frame.width <= 0 || frame.height <= 0
                ? 0
                : (visible.height * visible.width) / (frame.height * frame.width)
            print("[grid-reject] \(post.id.rawValue) kind=\(post.kind)"
                + " collection=\(post.isCollection ? "Y" : "N")"
                + " carousel=\(row.map { $0.showsCarousel ? "Y" : "N" } ?? "-")"
                + " page=\(row?.currentPageVideoURL?.lastPathComponent ?? "nil")"
                + " held=\(held?.lastPathComponent ?? "nil")"
                + " cover=\(hasCover(for: post, in: cell) ? "Y" : "N")"
                + " flying=\(post.id == heroFlyingPostID ? "Y" : "N")"
                + String(format: " frac=%.2f", fraction))
        }
    }

    /// Asks every visible collection row the audit's four questions.
    ///
    /// Run after the reconcile rather than inside it: what matters is the state
    /// the VIEWER is left in once everything has had its say, not the state any
    /// one participant believes it produced.
    /// Whether this page is the one the viewer is looking at.
    ///
    /// ⚠️ The audit's scope, and it needs one. A grid covered by an open post
    /// legitimately holds surfaces that are not hosted and not drawing — the
    /// post has them. Judging the card there reported the handoff working as a
    /// fault, six times in a run.
    private var isAudited = true

    private func auditCarouselPlayback() {
        guard CarouselPlaybackAudit.isEnabled, isAudited, let playback else { return }
        // ⚠️ A HEARTBEAT, unconditionally.
        //
        // Three times this session a run was read as clean when it had produced
        // NOTHING: a console that stopped delivering, a stale file from an
        // earlier build, and a guard that silenced the only writer. A file that
        // is always written and always carries its check count cannot be
        // mistaken for a passing run — an empty one is now impossible rather
        // than indistinguishable.
        CarouselPlaybackAudit.report("card")
        for indexPath in collectionView.indexPathsForVisibleItems {
            let index = flatIndex(for: indexPath)
            guard posts.indices.contains(index),
                  let row = collectionView.cellForItem(at: indexPath) as? PostGridListRowCell
            else { continue }
            let post = posts[index]
            guard post.isCollection else { continue }
            CarouselPlaybackAudit.check(
                surface: "card", subject: post.id.rawValue,
                page: row.currentMediaPage ?? -1,
                playing: playback.isPlaying(post.id),
                clip: row.currentPageVideoURL != nil,
                hosted: row.isRenderingCurrentMedia,
                drawable: row.isSurfaceDrawable
            )
            CarouselPlaybackAudit.checkStillPage(
                surface: "card", subject: post.id.rawValue,
                page: row.currentMediaPage ?? -1,
                drawsVideo: row.drawsVideoOnAStillPage
            )
            // Frozen: on the clip's page, drawing, and not moving.
            CarouselPlaybackAudit.checkAdvancing(
                surface: "card", subject: post.id.rawValue,
                page: row.currentMediaPage ?? -1,
                watching: row.currentPageVideoURL != nil && row.isSurfaceDrawable
                    && playback.isPlaying(post.id),
                advancing: row.playbackSurface.map { videoPool?.isAdvancing(in: $0) ?? true }
                    ?? true,
                hasPlayer: row.playbackSurface.map { videoPool?.hasPlayer(in: $0) ?? true } ?? false
            )
            // ⚠️ Is the coordinator even talking about THIS cell? A collection
            // view recycles, and a loan is held against the instance it was
            // given to.
            if playback.isPlaying(post.id),
               let loaned = playback.loanedCell(post.id), loaned !== row {
                CarouselPlaybackAudit.trace("cell mismatch \(post.id.rawValue)")
            }
        }
    }
    #endif

    /// Brings the last-tapped post clear of the chrome, now that nobody is
    /// looking at this page.
    ///
    /// Called when the post has finished covering the grid. Unanimated because
    /// there is no one to animate for, and because the dismissal that follows
    /// reads the cell's rect when it starts — this has to be settled by then,
    /// not still moving.
    func applyPendingReveal() {
        guard let id = pendingRevealPostID else { return }
        pendingRevealPostID = nil
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        ScrollIntoView.revealImmediately(
            collectionView.layoutAttributesForItem(at: indexPath(for: index))?.frame,
            in: collectionView
        )
    }

    /// Brings `postID`'s tile into the unobstructed viewport NOW, layout
    /// settled — the cluster gallery's landing rule. Unlike the For You
    /// dismissal (which anchors on the departure tile and never scrolls —
    /// see `ForYouGridZoomSource`), a cluster gallery has never been seen
    /// when the first dismissal stages, so there is no viewer context to
    /// preserve and the grid is free to travel to the landing post's own
    /// tile.
    func revealPost(_ postID: PostID) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        collectionView.layoutIfNeeded()
        ScrollIntoView.revealImmediately(
            collectionView.layoutAttributesForItem(at: indexPath(for: index))?.frame,
            in: collectionView
        )
    }

    /// Whether a post autoplays ON THIS PAGE — the one autoplay rule that
    /// differs by shape, so the difference lives in exactly one place.
    ///
    /// `autoplaysInGrid` excludes SQUARE video, and that is a mosaic judgement:
    /// a square brick competing for one of six slots in a dense wall is not
    /// worth the slot. A row's preview is a fixed landscape box that
    /// aspect-fills whatever it is handed, so a square source is no different
    /// there to any other, and applying the grid's rule would leave those rows
    /// permanently still for a reason that never applied to them.
    private func autoplays(_ post: GalleryPost) -> Bool {
        style == .grid ? post.autoplaysInGrid : post.hasPlayableVideo
    }

    /// The stream this cell should be playing right now, or nil for none.
    ///
    /// ⚠️ A COLLECTION answers from its current page, and the post cannot answer
    /// for it.
    ///
    /// `GalleryPost.videoURL` is page one's, for ever. Nothing in `post.v1` says
    /// a carousel's attachments agree about their type, so a post whose first
    /// page is a photograph is a `.photo` post that still has a clip on page
    /// two — `autoplays(post)` would refuse it, and `post.videoURL` would be nil
    /// even if it did not. Both questions move to the page.
    ///
    /// A row showing a still page answers nil, which is what stops the clip the
    /// viewer just scrolled away from.
    private func playableURL(for post: GalleryPost, in cell: any GridPlaybackCell) -> URL? {
        if let row = cell as? PostGridListRowCell, post.isCollection {
            // RETAINED, not current: the row keeps its player while the viewer
            // is on a still page of the same collection. Whether it advances is
            // decided separately, at the call site.
            return row.retainedVideoURL
        }
        guard autoplays(post) else { return nil }
        return post.videoURL
    }

    /// Whether a tile has something to show behind its video surface.
    ///
    /// A video surface covers the tile's cover image, and until the first frame
    /// decodes it has nothing of its own to draw — so a tile that starts
    /// playing before its cover has arrived is simply black, and a hero flight
    /// departing from it flies black. Measured on a cold `-rich-media` grid,
    /// every tile reported `cover=NIL` at play start.
    ///
    /// Gating here rather than in the renderer because this is not a rendering
    /// problem: there is no frame AND no poster, and no amount of sequencing
    /// invents one. Playback simply waits for the tile to have a face.
    ///
    /// A post with no `thumbnailURL` is admitted rather than blocked. Nothing
    /// is coming for it, so waiting would mean never playing — and its first
    /// decoded frame is the only face it will ever have.
    private func hasCover(for post: GalleryPost, in cell: any GridPlaybackCell) -> Bool {
        guard let thumbnail = post.thumbnailURL else { return true }
        // The cell's own image first: it may hold a cover the pipeline has
        // since evicted from its cache.
        if cell.renderedCover != nil { return true }
        // Cached but not yet applied — `configure` asked the cache before the
        // prefetch landed, and the cell's own load has not come back. Apply it
        // now rather than merely reporting it: a gate that passed on a cover
        // the tile is not actually showing would let playback start against a
        // blank face, which is what it exists to prevent.
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        cell.applyCover(cached)
        return true
    }

    /// How far beyond the visible range to pull covers for autoplaying posts.
    private static let autoplayCoverLookahead = 6

    /// The visible range covers were last requested for, so a scroll does not
    /// rebuild the same URL list 30 times a second.
    private var preloadedCoverRange: ClosedRange<Int>?

    /// Fetches cover images for autoplay-capable posts before their tiles need
    /// them.
    ///
    /// An autoplaying tile is the one case where a missing cover is not merely
    /// a slower thumbnail: the video surface sits over it, so until the first
    /// frame decodes the cover IS the tile, and a hero flight departing from it
    /// carries whatever is there. Measured on a cold `-rich-media` grid, covers
    /// landed ~6.3s after launch and the tiles were empty until then — so the
    /// first flight of a session flew from, and landed on, nothing.
    ///
    /// Restricted to `autoplaysInGrid` posts deliberately. A still tile shows
    /// its cover directly and is already served by the normal per-cell load;
    /// prefetching every thumbnail in range would trade this narrow fix for
    /// bandwidth the grid did not ask for.
    private func preloadAutoplayCovers(around visible: [IndexPath]) {
        guard !showsSkeleton, !posts.isEmpty,
              let first = visible.map(\.item).min(),
              let last = visible.map(\.item).max()
        else { return }
        let lower = max(0, first - Self.autoplayCoverLookahead)
        let upper = min(posts.count - 1, last + Self.autoplayCoverLookahead)
        guard lower <= upper else { return }
        let range = lower...upper
        guard range != preloadedCoverRange else { return }
        preloadedCoverRange = range

        let urls = posts[range].filter(\.autoplaysInGrid).compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }
        imagePipeline.prefetch(urls)
    }

    /// The first-load case, where there are no cells yet to be "around".
    private func preloadLeadingAutoplayCovers() {
        guard !showsSkeleton, !posts.isEmpty else { return }
        let upper = min(posts.count - 1, Self.autoplayCoverLookahead * 2)
        let urls = posts[0...upper].filter(\.autoplaysInGrid).compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }
        // Leaves `preloadedCoverRange` unset on purpose: the first real
        // reconcile should still run against the actual visible set rather than
        // believe this guess already covered it.
        imagePipeline.prefetch(urls)
    }

    /// Tab left, feed presented over the grid, app backgrounded. `keeping`
    /// exempts the post whose player a hero flight is still carrying.
    /// Opens the handoff scope for a tapped tile. Replaces the old
    /// "stop everything except this one" call: the scope also makes the post
    /// invisible to `reconcile`, so nothing can restart or stop it mid-flight.
    func beginPlaybackHandoff(of postID: PostID) {
        playback?.beginHandoff(postID)
    }

    /// Points the handoff scope at the post a dismissal is actually landing on.
    /// See `GridVideoPlaybackCoordinator.retargetHandoff`.
    func retargetPlaybackHandoff(to postID: PostID) {
        playback?.retargetHandoff(postID)
    }

    /// Closes the scope and reconciles once — the single act that restores the
    /// grid's full complement of players after a dismissal.
    func endPlaybackHandoff() {
        playback?.endHandoff()
        // The claim ends with the round trip: the post is back to being one
        // tile among others, and holding the claim would pin a player to
        // whatever the viewer opened last, for ever.
        playback?.focus(nil)
        updateAutoplay()
        #if DEBUG
        logVisibility("return-complete")
        #endif
    }

    func setAutoplayActive(_ active: Bool, keeping kept: PostID? = nil) {
        #if DEBUG
        isAudited = active
        #endif
        playback?.setSurfaceVisible(active, keeping: kept)
        if active {
            updateAutoplay()
            #if DEBUG
            schedulePlaybackDiagnosticsIfNeeded()
            #endif
        }
    }

    #if DEBUG
    /// Drives the page's real selection path, the one a finger reaches.
    ///
    /// `-foryou-open` used to call `openFeed` directly, which skipped
    /// `didSelectItemAt` entirely — so nothing scripted ever exercised what a
    /// tap actually does, and the scroll-into-view work went three rounds with
    /// no run able to reach it. Going through the delegate means a scripted
    /// open and a real one differ only in what produced the touch.
    func debugSelectItem(at index: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        collectionView(collectionView, didSelectItemAt: indexPath(for: index))
        return true
    }

    /// Presses a row's comment count, the control a finger reaches — not the
    /// route behind it. Reports false when the row is not on screen or wears no
    /// chip, which is what separates "the shortcut is broken" from "there was
    /// nothing to press".
    func debugTapComments(at index: Int) -> Bool {
        guard posts.indices.contains(index),
              let row = collectionView.cellForItem(
                  at: indexPath(for: index)
              ) as? PostGridListRowCell
        else { return false }
        return row.debugTapCommentsChip()
    }

    /// `-foryou-scroll-demo`: scrolls the page the way a finger would, since
    /// the simulator injects no touches.
    ///
    /// Deliberately `setContentOffset(animated:)` rather than assigning the
    /// offset: an assignment jumps in one step and fires a single
    /// `scrollViewDidScroll`, which would exercise none of what autoplay does
    /// during a scroll. The animated form emits a callback per frame and ends
    /// with `scrollViewDidEndScrollingAnimation`, so the throttled reconcile,
    /// its velocity gate and the settle all run exactly as they do under a
    /// flick.
    func debugScroll(toY y: CGFloat) {
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    var debugScrollableHeight: CGFloat {
        max(0, collectionView.contentSize.height - collectionView.bounds.height)
    }

    var debugViewportHeight: CGFloat { collectionView.bounds.height }

    /// The three numbers that decide where a cell is on screen, for tracing a
    /// landing that missed. A rect alone cannot say WHY it moved; these can.
    var debugInsetState: String {
        String(
            format: "offset=%.1f adjInset=(t%.1f b%.1f) frozen=%@ h=%.1f",
            collectionView.contentOffset.y,
            collectionView.adjustedContentInset.top,
            collectionView.adjustedContentInset.bottom,
            frozenContentInset == nil ? "N" : "Y",
            collectionView.bounds.height
        )
    }

    /// The posts on screen that COULD play, with the same centre distance the
    /// ranking uses — the independent check on what the coordinator chose.
    var debugVisibleVideoRanking: [(id: String, distance: Int)] {
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let centreY = viewport.midY
        return collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> (id: String, distance: Int)? in
            let index = flatIndex(for: indexPath)
            guard posts.indices.contains(index) else { return nil }
            let post = posts[index]
            guard autoplays(post),
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell
            else { return nil }
            let box = cell.convert(cell.videoMediaRect, to: collectionView)
            return (post.id.rawValue, Int(abs(box.midY - centreY)))
        }
        .sorted { $0.distance < $1.distance }
    }

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

    /// Mirrors a playing tile's player onto the flight card and then parks it.
    ///
    /// Order is the whole point, and it is why both steps live here rather than
    /// at the call site. Mirroring first attaches the card's layer while the
    /// tile still owns the player, so the card renders live from frame 0 and,
    /// being the most recently attached layer, is the one that displays.
    /// Parking second releases the tile without interrupting the player, so the
    /// destination can adopt it — same item, same playhead — when the flight
    /// lands.
    ///
    /// Parking first, which is what this used to do, left nothing to mirror:
    /// the card flew a static cover for the whole 420ms zoom while the player
    /// sat parked, and the live frame only reappeared after landing.
    func donateLivePlayback(of postID: PostID) -> VideoRenderView? {
        playback?.donateLiveSurface(of: postID)
    }

    /// The N-surface alternative to `donateLivePlayback`: a NEW surface showing
    /// the same live playback, with the tile keeping its own.
    ///
    /// Nothing is donated, nothing is parked, and the tile is hidden rather
    /// than stopped — so if the flight is abandoned there is nothing to put
    /// back. Returns nil when the tile is not playing, which is the same
    /// contract the donate path had.
    func liveFlightSurface(for postID: PostID) -> VideoRenderView? {
        // ⚠️ The CURRENT PAGE's stream where there is one. `post.videoURL` is
        // page one's for ever, so a collection opened from a clip on page three
        // asked for the wrong asset — and a collection whose head is a
        // photograph asked for nil and never flew live at all.
        let row = cell(for: postID) as? PostGridListRowCell
        guard let playback,
              let index = posts.firstIndex(where: { $0.id == postID }),
              let url = row?.currentPageVideoURL ?? posts[index].videoURL
        else { return nil }
        let made = playback.makeAttachedSurface(for: postID, url: url)
        // Nothing to join. Ask for the player rather than reporting its
        // absence: this call is repeated every frame of the flight (see
        // `ZoomLiveMediaRetry`), so a start kicked here is picked up by the
        // next ask — which is the difference between a hero that shows video
        // 100ms in and one that shows a poster all the way home.
        if made == nil, let row {
            playback.demandFlightPlayback(of: postID, url: url, in: row)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f producer GRID liveFlightSurface -> %@",
                         CACurrentMediaTime(), made == nil ? "NIL (tile not playing)" : "surface"))
        }
        #endif
        return made
    }

    /// Forces the landing cell through a layout pass while the card still
    /// covers it.
    ///
    /// The surface can report a decoded frame while the CELL around it has a
    /// pending layout — the render view was just inserted or unhidden, and its
    /// frame resolves on the next pass. Unmounting the card into that gap
    /// shows the cell mid-composition for a frame. Doing the pass under the
    /// card costs nothing visible.
    func finalizeLandingLayout(for postID: PostID) {
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let cell = collectionView.cellForItem(at: indexPath(for: index))
        else { return }
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    /// Whether the tile a dismissal is landing on has something to show yet.
    ///
    /// The card is held over the landing until this is true, so "ready" has to
    /// mean *the viewer would see content*, not merely *playback is running*.
    /// Three cases, and the first two are why a swapped-in post could flash:
    ///
    /// - The tile has TAKEN a surface. A dismissal hands its live surface to any
    ///   post carrying a stream, but the old gate only waited when the post also
    ///   passed `autoplaysInGrid` — which excludes square clips. So a square
    ///   video adopted a surface, the gate said ready, the card let go, and the
    ///   surface's first frame had not arrived: one empty tile.
    /// - A still tile is ready when it has a cover. Nothing waited on that at
    ///   all, so landing on a post whose thumbnail was not already cached — the
    ///   normal case for one swapped in from further down the feed — showed the
    ///   tile's background colour until the load returned.
    /// - Nothing realized, or nothing to load: there is no gap to cover.
    ///
    /// `ZoomAnimator.holdCard`'s ceiling bounds all of this, so a cover that
    /// never arrives is a brief pause rather than a stuck card.
    func isLandingPlaybackReady(for postID: PostID) -> Bool {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return true }
        let post = posts[index]
        let cell = collectionView.cellForItem(
            at: indexPath(for: index)
        ) as? any GridPlaybackCell
        if let playback, post.videoURL != nil,
           autoplays(post) || cell?.loadedVideoRenderView != nil {
            return playback.isSurfaceRendering(for: postID)
        }
        guard let cell, post.thumbnailURL != nil else { return true }
        return cell.renderedCover != nil
    }



    /// Lands a hosted surface WITHOUT moving it into the cell: the layer stays
    /// where it is and the tile publishes geometry instead.
    @discardableResult
    func adoptHostedPlayback(_ view: VideoRenderView, for postID: PostID) -> Bool {
        guard let playback,
              let index = posts.firstIndex(where: { $0.id == postID }),
              let url = posts[index].videoURL,
              let cell = collectionView.cellForItem(
                  at: indexPath(for: index)
              ) as? any GridPlaybackCell
        else { return false }
        let adopted = playback.adoptHostedSurface(view, for: postID, url: url, cell: cell)
        #if DEBUG
        if !adopted, ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            // Both URLs, because a refusal is almost always the two sides
            // naming the same asset differently.
            print("[zoom-live] adopt REFUSED tile=\(url.absoluteString) parked=\(playback.debugParkedURL?.absoluteString ?? "nil")")
        }
        #endif
        return adopted
    }

    /// Where the tile for `postID` currently is, in `space`. The host reads
    /// this every scroll frame to keep the hosted surface glued to its brick.
    /// `nil` once the tile is no longer realized.
    func tileRect(for postID: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let cell = collectionView.cellForItem(at: indexPath(for: index))
        else { return nil }
        return cell.convert(cell.bounds, to: space)
    }

    /// The grid's own rect, so the host can clip a hosted surface to it rather
    /// than letting it draw over the bars.
    func gridRect(in space: UICoordinateSpace) -> CGRect {
        collectionView.convert(collectionView.bounds, to: space)
    }

    /// Called on every scroll frame while a surface is hosted.
    var onGeometryChanged: (() -> Void)?

    /// Forwards the coordinator's teardown so the host can drop its reference.
    func setHostedSurfaceReleasedHandler(_ handler: @escaping (PostID) -> Void) {
        playback?.onHostedSurfaceReleased = handler
    }

    /// Installs the flight card's live surface on the landing tile, so it is
    /// rendering before the card is removed.
    func adoptLivePlayback(_ view: VideoRenderView, for postID: PostID) {
        guard let playback,
              let index = posts.firstIndex(where: { $0.id == postID }),
              let url = posts[index].videoURL,
              let cell = collectionView.cellForItem(
                  at: indexPath(for: index)
              ) as? any GridPlaybackCell
        else { return }
        // Same rule as the present leg: the surface must land in a VISIBLE
        // hierarchy or the layer stops rendering. The cell is still standing in
        // for the flight card at this point, so reveal it first — the card is
        // on top and covers the swap.
        //
        // Through `applyHeroConcealment` rather than `isHidden`, because the
        // two shapes conceal differently: a tile hides whole, a row fades only
        // its preview. Setting `isHidden` on a row would reveal nothing (it was
        // never hidden) and leave the preview — and the surface inside it — at
        // alpha 0, so the video would land invisible.
        Self.applyHeroConcealment(false, to: cell as? UICollectionViewCell)
        if VideoRenderFlags.usesSampleBufferLayer {
            // The card's surface is one of several showing this playback, not
            // the playback itself. The tile gets its OWN surface — primed with
            // the current frame on attach — and takes the pool loan; the card's
            // is released once it leaves the window. Nothing is re-parented,
            // which is the ~65ms drop `holdCard` was covering.
            playback.adoptAttachedSurface(for: postID, url: url, cell: cell)
            return
        }
        playback.adoptLiveSurface(view, for: postID, url: url, cell: cell)
    }

    /// The destination never adopted the parked player — a cancelled flight, or
    /// a plain push. Retires it rather than leaving it decoding unseen.
    ///
    /// Kept for the plain-push fallback, where no handoff scope was opened.
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
        // media is one part, so fly that part. A TEXT row has no media and no
        // hero — see `heroAppearance`.
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
            // A TEXT row answers nil, and that is the whole of its transition
            // policy: no hero, so `openFeed` pushes it natively.
            //
            // It used to fly its whole card, and the attempt is worth one line
            // of warning. A media hero works because the media is the same
            // object at both ends. A text page is its COMMENTS, which a row
            // card has none of, so the card had to impersonate them — first by
            // photographing the page, then by fading the real one in behind a
            // growing card. Each version fixed the previous one's artifact and
            // introduced its own: a skeleton in the still, a blank card, wrong
            // safe area, two captions, a caption floating outside the card. A
            // native push has none of them and is what the platform does.
            row.mediaHeroRect == nil
                ? nil
                : (cover: row.renderedCover, style: .listMedia)
        default:
            nil
        }
    }

    /// **THE TEXT REVEAL**. The whole card of a TEXT row, in
    /// `space` — the rect a clip-window reveal opens from and closes onto.
    ///
    /// Deliberately NOT `hero(for:in:)`'s rect, and the difference is the
    /// point. A media row flies its PREVIEW, because the preview is the one
    /// object that exists at both ends; a text row has no such object, so what
    /// opens is the card itself — caption, metrics and all. The card fills the
    /// cell (`PostGridListRowCell` pins it to `contentView`), so the cell's
    /// own bounds are the card's.
    ///
    /// Answers nil for anything that is not a realized text row: a media row,
    /// a tile, or a post scrolled out of the viewport. The reveal then falls
    /// back to a centred window, exactly as a hero falls back to a centred
    /// collapse.
    func textRowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let row = cell(for: postID) as? PostGridListRowCell,
              row.mediaHeroRect == nil
        else { return nil }
        // ⚠️ THE GUARD ABOVE IS A POLICY, not arithmetic: a row WITH media has
        // a hero, so it flies rather than opening as a window.
        // The WHOLE card. Departing from below the author band was the first
        // attempt and the frames killed it: a window that stops short of the
        // card's top leaves the band outside the transition, so the card gains
        // it in one frame at the landing. The offset is carried instead — see
        // `PostGridListRowCell.revealCaptionTop`.
        return row.convert(row.bounds, to: space)
    }

    #if DEBUG
    /// `-foryou-expand <index>`: presses the row's "Show more". Returns false
    /// when the row is not realized or its caption fits, so a harness can tell
    /// "did not expand" from "had nothing to expand".
    @discardableResult
    func debugTapShowMore(atIndex index: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        let path = indexPath(for: index)
        // Scroll ONLY if the row is not already realized. Scrolling anyway is
        // what the first version did, and it made the expansion impossible to
        // film: every frame of the capture was the list travelling, with the
        // growth buried inside it.
        if collectionView.cellForItem(at: path) == nil {
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        guard let row = collectionView.cellForItem(at: path) as? PostGridListRowCell
        else { return false }
        return row.debugTapShowMore()
    }

    /// Swipes a row's carousel to a page. Same realize-then-act shape as
    /// `debugTapShowMore(atIndex:)`, and false for a row with no collection.
    @discardableResult
    func debugScrollCarousel(atIndex index: Int, toPage page: Int) -> Bool {
        guard posts.indices.contains(index) else { return false }
        let path = indexPath(for: index)
        if collectionView.cellForItem(at: path) == nil {
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        guard let row = collectionView.cellForItem(at: path) as? PostGridListRowCell
        else { return false }
        return row.debugScrollCarousel(toPage: page)
    }
    #endif

    /// Moves a row's carousel to `page`, so the card follows the post opened
    /// from it. A no-op for a row that is not realized — a card that scrolled
    /// away has no carousel to move, and will be configured fresh when it
    /// comes back.
    func setMediaPage(_ page: Int, for id: PostID) {
        (cell(for: id) as? PostGridListRowCell)?.setMediaPage(page, animated: false)
    }

    /// Which page of a row's carousel is showing, or nil for a row that has
    /// none — or one the collection view has not realized, which is the honest
    /// answer rather than a guess of zero.
    func currentMediaPage(atIndex index: Int) -> Int? {
        guard posts.indices.contains(index) else { return nil }
        let row = collectionView.cellForItem(at: indexPath(for: index)) as? PostGridListRowCell
        return row?.currentMediaPage
    }

    /// Where the page stops matching the row, in the row's own space — the
    /// reveal's cut line. `nil` when the row is not realized.
    /// The card a dismissal carries home, drawn at the ROW's own width so its
    /// caption wraps and truncates exactly as the row's does.
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
            // The viewer may have opened this caption out before opening the
            // post. The expansion belongs to the SURFACE, not to the cell, so
            // it is here to be asked for — and a stand-in that does not ask
            // flies a truncated card home, "Show more" and all, onto a row that
            // is showing the whole thing.
            captionExpanded: captionExpansion.isExpanded(postID),
            showsAuthorMenu: showsAuthorMenu(for: post),
            // ⚠️ Both controls, because every row on THIS surface wires both —
            // see `configure`, where the repost and bookmark handlers are set
            // unconditionally. The saved state is read from the same store the
            // row reads, so a post saved a moment ago flies home filled in.
            actions: .init(
                repost: true, bookmark: true, saved: bookmarks.isSaved(postID.rawValue)
            ),
            // The row's own date when there is a row — see
            // `PostGridListRowCell.renderedAgeText`.
            ageText: (cell(for: postID) as? PostGridListRowCell)?.renderedAgeText,
            // The ROW's own height when it is realized — see the profile's
            // twin, and `RevealDismissCardView.init`.
            height: cell(for: postID)?.bounds.height
        )
    }

    /// Whether the row for `post` draws a "...", asked of the same provider the
    /// row asks. The stand-in has to match it or the control pops in or out in
    /// the last frame — see `RevealDismissCardView`.
    private func showsAuthorMenu(for post: GalleryPost) -> Bool {
        guard let authorID = post.authorID, let authorMenuActions else { return false }
        // The anchor only ever places a popover, and nothing is being presented
        // here: this asks the provider what it WOULD offer.
        let context = AuthorMenuContext(post: post, authorID: authorID, anchor: UIView())
        return !authorMenuActions(context).isEmpty
    }

    /// The row's author band, for the destination to borrow during a flight.
    /// Read from the POST rather than from the cell, so it answers for a row
    /// that has scrolled out as readily as for one on screen.
    func textRowAuthorBand(for postID: PostID) -> PostAuthorBandView.Model? {
        posts.first { $0.id == postID }.flatMap(PostAuthorBandView.Model.init(post:))
    }

    /// The pipeline this page draws with, so a borrowed band can load the same
    /// avatar from the same cache rather than fetching its own copy.
    var bandImagePipeline: ImagePipeline { imagePipeline }

    /// How far below the row's top its caption begins — the band's height plus
    /// its gap, or zero. See `PostGridListRowCell.revealCaptionTop`.
    func textRowCaptionTop(for postID: PostID) -> CGFloat {
        (cell(for: postID) as? PostGridListRowCell)?.revealCaptionTop ?? 0
    }

    func textRowCaptionEnd(for postID: PostID) -> CGFloat? {
        (cell(for: postID) as? PostGridListRowCell)?.revealCut
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
    /// The OFFSET is preserved across the switch, and that is not belt and
    /// braces — it is the difference between freezing the grid and scrolling
    /// it.
    ///
    /// `contentInsetAdjustmentBehavior = .never` lands one assignment before
    /// `contentInset = resolved`, and in that instant the adjusted inset
    /// collapses to whatever `contentInset` still holds (zero, for this grid).
    /// UIKit re-clamps `contentOffset` against it immediately, so a grid
    /// resting at the TOP — where `offset.y == -adjustedInset.top` — is
    /// yanked to 0 and every cell moves up by the whole top inset. Measured
    /// on this screen: `offset=-116 → offset=0`, which put a landing rect
    /// 116pt above the row it departed from.
    ///
    /// It only shows when the grid is scrolled to its very top, because that
    /// is the only place where the offset is pinned to the inset it is about
    /// to lose — which is why a freeze that has been correct for every
    /// mid-scroll flight still had this in it.
    func beginHeroFreeze() {
        guard frozenContentInset == nil else { return }
        let offset = collectionView.contentOffset
        frozenContentInset = collectionView.contentInset
        let resolved = collectionView.adjustedContentInset
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = resolved
        collectionView.contentOffset = offset
    }

    /// Symmetrical with the freeze, and for the same reason: the two
    /// assignments below each re-clamp `contentOffset` against an inset that
    /// is momentarily wrong, so the offset is carried across by hand rather
    /// than left to survive them.
    func endHeroFreeze() {
        guard let frozenContentInset else { return }
        let offset = collectionView.contentOffset
        self.frozenContentInset = nil
        // A hosted page manages its insets manually for its whole life — the
        // pre-freeze behaviour to restore is `.never` there, not the default.
        collectionView.contentInsetAdjustmentBehavior =
            hostedTopInset == nil ? .automatic : .never
        collectionView.contentInset = frozenContentInset
        collectionView.contentOffset = offset
        // The footer may have opened or closed while the inset was pinned, and
        // those writes were dropped. Re-apply now that it is ours again.
        applyBottomInset()
    }

    /// Puts the post the viewer ended on into the slot they LEFT from, swapping
    /// it with whatever was there. Reports whether anything moved.
    ///
    /// A dismissal has to land somewhere, and there are two candidates: the tile
    /// the active post already occupies — which means scrolling the grid under
    /// the viewer to reach it — or the tile they tapped, which is still exactly
    /// where they left it. This is the second. The slot becomes a window onto
    /// whatever the feed settled on, and the card flies home to the frame it
    /// launched from.
    ///
    /// **A swap, not an overwrite.** Every lookup on this page resolves a post
    /// id to a cell through `firstIndex`. Writing the active post into the
    /// departure slot while it still sat in its own would put one id in two
    /// places, and `firstIndex` would answer with whichever came first — so the
    /// flight rect, the hero hide and the playback adoption could each end up
    /// addressing a different tile. Swapping keeps ids unique, which is what
    /// lets the rest of the machinery go on addressing cells by post with no
    /// idea this happened.
    ///
    /// **Geometry cannot shift.** The chaotic layout maps *index* to frame, so
    /// exchanging the contents of two indices moves nothing. What does change is
    /// the shape each of the two posts is cropped to: `PostGridSliceArrangement`
    /// paired them with slots chosen for their own aspects, and a swap trades
    /// those pairings.
    @discardableResult
    func adoptPost(_ postID: PostID, intoSlotOf occupantID: PostID) -> Bool {
        guard style == .grid, !showsSkeleton,
              let slot = posts.firstIndex(where: { $0.id == occupantID }),
              let current = posts.firstIndex(where: { $0.id == postID }),
              slot != current
        else { return false }
        // The pixels each cell is showing RIGHT NOW, carried across the reload.
        //
        // `configure` clears the image and re-asks the cache, so a cell whose
        // cover the cache has since evicted comes back empty — a blank square
        // where a tile used to be, for as long as the refetch takes. Both cells
        // are on screen during a dismissal, so both would show it.
        let carried = [slot, current].reduce(into: [Int: UIImage]()) { covers, index in
            let path = indexPath(for: index)
            if let cover = (collectionView.cellForItem(at: path) as? any GridPlaybackCell)?.renderedCover {
                covers[index] = cover
            }
        }
        posts.swapAt(slot, current)
        // Reloaded rather than reconfigured: `reconfigureItems` reuses the cell
        // without `prepareForReuse`, so a tile would keep the previous post's
        // video surface and play one post's motion under another's cover.
        UIView.performWithoutAnimation {
            collectionView.reloadItems(at: [
                indexPath(for: slot),
                indexPath(for: current)
            ])
            // Force the pass NOW. `reloadItems` only marks the items dirty; the
            // cells are rebuilt on the next layout, and the caller reads the
            // landing rect from a realized cell immediately after this returns.
            // Without it `cellForItem(at:)` answers nil, the source reports
            // itself off-screen, and the flight collapses to the middle of the
            // screen instead of flying to the tile — measured exactly that way.
            collectionView.layoutIfNeeded()
            // Re-apply after the rebuild: `applyCover` is a no-op on a cell that
            // already found its image, so a cache hit still wins.
            for (index, cover) in carried {
                let moved = index == slot ? current : slot
                (collectionView.cellForItem(at: indexPath(for: moved))
                    as? any GridPlaybackCell)?.applyCover(cover)
            }
            // Both swapped cells are on screen for the whole return, and both
            // must be drawn before it starts. The displaced post's slot is the
            // one that gets forgotten: nothing is flying to it, so no landing
            // step ever revisits it, and it would carry whatever state the
            // rebuild left until something else happened to touch it.
            for index in [slot, current] {
                guard let cell = collectionView.cellForItem(
                    at: indexPath(for: index)
                ) else { continue }
                cell.isHidden = false
                cell.alpha = 1
                cell.layoutIfNeeded()
            }
            // And commit them to the render server in this turn rather than the
            // next. Everything downstream — the hero rect, the flight card built
            // from this cell's cover, the landing gate — reads the cell
            // immediately, and a cell whose layers are still pending answers as
            // though it were empty.
            CATransaction.flush()
        }
        // The landing tile is about to be flown onto; give its cover a head
        // start in case the cache does not already hold it.
        if let url = posts[slot].thumbnailURL { imagePipeline.prefetch([url]) }
        return true
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
    #if DEBUG
    /// `-foryou-visibility-log`: the state of the grid's visibility invariant at
    /// a named moment.
    ///
    /// Written to answer one question the simulator would not: when a tile has
    /// vanished on device, is it HIDDEN or is it ABSENT? Those point at opposite
    /// halves of the system — a leaked hero hide against a data/arrangement
    /// fault — and no screenshot distinguishes them.
    ///
    /// `hero` should be nil whenever no flight is in the air; a non-nil value
    /// here is a leaked hide, and every future dequeue of that post will hide
    /// its cell. `hidden` should be empty for the same reason. `posts` and
    /// `items` must agree, or the data source and the collection view have
    /// diverged and cells are missing rather than invisible.
    func logVisibility(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-visibility-log"),
              style == .grid
        else { return }
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        let invisible = visible.compactMap { path -> String? in
            guard let cell = collectionView.cellForItem(at: path) else { return nil }
            guard cell.isHidden || cell.alpha == 0 else { return nil }
            let id = posts.indices.contains(path.item) ? posts[path.item].id.rawValue : "?"
            return "\(path.item):\(id)\(cell.isHidden ? "/hidden" : "")\(cell.alpha == 0 ? "/alpha0" : "")"
        }
        let blank = visible.compactMap { path -> String? in
            guard let cell = collectionView.cellForItem(at: path) as? any GridPlaybackCell,
                  posts.indices.contains(path.item) else { return nil }
            let post = posts[path.item]
            guard post.thumbnailURL != nil, cell.renderedCover == nil,
                  cell.loadedVideoRenderView?.isReadyForDisplay != true
            else { return nil }
            return "\(path.item):\(post.id.rawValue)"
        }
        let items = collectionView.numberOfSections > 0
            ? collectionView.numberOfItems(inSection: 0) : 0
        let ids = Set(posts.map(\.id))
        print("[vis] \(moment) hero=\(heroHiddenPostID?.rawValue ?? "nil")"
            + " posts=\(posts.count) items=\(items) uniqueIDs=\(ids.count)"
            + " visible=\(visible.count) invisible=\(invisible.isEmpty ? "none" : invisible.joined(separator: ","))"
            + " blank=\(blank.isEmpty ? "none" : blank.joined(separator: ","))"
            + (posts.count == items && ids.count == posts.count ? "" : "  <<< DATA SOURCE DIVERGED"))
    }
    #endif

    /// `conceals` is false for a DISMISSAL. The card is flying home TO this
    /// tile, so hiding it opens a hole in the grid for the whole flight and the
    /// tile pops in at the end. Left visible, the card simply lands on top of
    /// content that was already there. A presentation still conceals: there the
    /// card is flying AWAY from the tile, and two copies of the same post would
    /// be on screen at once.
    /// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES.
    ///
    /// A tile IS its media edge to edge, so the whole cell goes. A row is a
    /// card of which the media is one part, and `hero(for:in:)` flies that
    /// part — so hiding the whole row removed the caption, author line and
    /// metrics that nothing in the air was standing in for. They were absent
    /// for the length of the flight and snapped back on its last frame, which
    /// is the reported "the rest of the post pops in at the end".
    ///
    /// One function so the two paths that conceal — this and `cellForItemAt`,
    /// which re-applies on every dequeue — cannot drift apart. They already
    /// had to agree; now they agree by construction.
    /// Internal, not private, so the routing itself is testable: the defect
    /// was not in either cell, it was in one call site treating a row like a
    /// tile.
    static func applyHeroConcealment(_ concealed: Bool, to cell: UICollectionViewCell?) {
        switch cell {
        // A row keeps everything the flight is not carrying — and which part
        // that is depends on the row, so the row is asked. It used to be
        // assumed: only media rows flew, so the preview was hard-coded here.
        // A text row flies too now, and what it carries away is the whole card.
        case let row as PostGridListRowCell:
            row.isHidden = false
            row.setHeroConcealed(concealed)
        case let other?:
            other.isHidden = concealed
        case nil:
            break
        }
    }

    /// Hides the row a reveal's window was taken from, for the flight's length.
    /// See `revealConcealedPostID` for why this does not go through
    /// `setHeroHidden`.
    func setRevealConcealed(_ concealed: Bool, for postID: PostID) {
        revealConcealedPostID = concealed ? postID : nil
        (cell(for: postID) as? PostGridListRowCell)?.setHeroConcealed(concealed)
    }

    func setHeroHidden(_ hidden: Bool, for postID: PostID, conceals: Bool = true) {
        heroFlyingPostID = hidden ? postID : nil
        heroHiddenPostID = (hidden && conceals) ? postID : nil
        // Apply to whatever is on screen right now; `cellForItemAt` covers
        // everything realized from here on.
        let resolved = cell(for: postID)
        Self.applyHeroConcealment(hidden, to: resolved)
        if hidden {
            heroHiddenCell = resolved
        } else {
            // The instance that was actually hidden, which a lookup may no
            // longer reach.
            Self.applyHeroConcealment(false, to: heroHiddenCell)
            heroHiddenCell = nil
            // And a sweep, because a flight can end without either reference
            // naming the hidden cell — an interrupted transition, or a swap
            // that moved the post twice. No flight is in the air once the flag
            // is nil, so nothing on screen may legitimately be invisible.
            for visible in collectionView.visibleCells {
                if visible.isHidden { visible.isHidden = false }
                // Skip a row a REVEAL is holding: this broom is for a media
                // flight's leftovers, and sweeping the other flight's row back
                // into view mid-grab is exactly what it must not do.
                if let row = visible as? PostGridListRowCell,
                   revealConcealedPostID == nil || cell(for: revealConcealedPostID!) !== row {
                    row.setHeroConcealed(false)
                }
            }
        }
        // Unhiding is the end of a flight. The tile is excluded from
        // candidates while its twin is in the air (or it would adopt the
        // player mid-flight and blank the card), so this is the first moment
        // it may claim the player the destination parked for it.
        if !hidden {
            updateAutoplay()
            #if DEBUG
            logVisibility("unhide")
            #endif
        }
    }

    /// The post behind an id, for a flight card that must configure itself
    /// from the model rather than from a cell that may not be realized.
    func post(for postID: PostID) -> GalleryPost? {
        posts.first { $0.id == postID }
    }

    /// The posts `new` adds to `old`, or nil when this is not an addition.
    ///
    /// Membership, not order. The old rule demanded that `new` be exactly `old`
    /// plus a suffix, so a page landing failed it whenever the discovery source
    /// had re-ranked the corpus in the meantime — which Trending does on every
    /// page. `apply` then took the reload branch and re-permuted EVERY slot,
    /// and the grid visibly reshuffled under the viewer: tiles they were looking
    /// at jumped elsewhere, reading as tiles vanishing.
    ///
    /// So a re-rank that only ADDS is treated as an addition. The upstream
    /// ordering is honoured for the newcomers and ignored for posts already
    /// placed, which is what the layout's immutable slices promise anyway — a
    /// slot's contents do not move once the viewer has seen them. A genuine
    /// removal or replacement still falls through to the reload.
    static func addedPosts(from old: [GalleryPost], to new: [GalleryPost]) -> [GalleryPost]? {
        guard !old.isEmpty, new.count > old.count else { return nil }
        let existing = Set(old.map(\.id))
        // Everything already on screen must still be there. A post that
        // disappeared is a removal, which an insert cannot express.
        guard existing.isSubset(of: Set(new.map(\.id))) else { return nil }
        let added = new.filter { !existing.contains($0.id) }
        // And the arithmetic has to close: same membership plus the newcomers,
        // or something was duplicated and the counts would drift.
        guard added.count == new.count - old.count else { return nil }
        return added
    }

    private func cell(for postID: PostID) -> UICollectionViewCell? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        return collectionView.cellForItem(at: indexPath(for: index))
    }

    func render(_ state: ForYouViewModel.PageState) {
        switch state {
        case .loading:
            emptyState.isHidden = true
            // A refresh keeps the existing rows under the spinner rather than
            // blanking to skeletons — the content is still valid until the
            // new page lands.
            apply(posts, skeleton: !refreshControl.isRefreshing && posts.isEmpty)
        case .content(let posts):
            emptyState.isHidden = true
            apply(posts, skeleton: false)
        case .empty(let empty):
            emptyState.configure(
                symbolName: style == .grid ? "photo.on.rectangle.angled" : "tray",
                title: empty.title,
                subtitle: empty.subtitle
            )
            emptyState.isHidden = false
            apply([], skeleton: false)
        case .failed(let message):
            // A failure gets the one thing an empty page does not: something to
            // press. Pull-to-refresh is already here, but a page with no rows
            // is a page with nothing to pull, so the retry has to be visible.
            emptyState.configure(
                symbolName: "exclamationmark.triangle",
                title: message,
                actionTitle: "Try Again",
                actionHandler: { [weak self] in self?.onRefresh?() }
            )
            emptyState.isHidden = false
            apply([], skeleton: false)
        }
    }

    private func apply(_ incoming: [GalleryPost], skeleton: Bool) {
        // Consumed here whatever happens next: it describes THIS delivery, and
        // leaving it armed would force the next genuine page landing to reload.
        let mustReload = mustReload
        self.mustReload = false
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
        // A data change ends any flight this page still thinks is in the air.
        // The flag is written in exactly one place and cleared only by the
        // matching unhide, so a flight that never delivered one would hide its
        // post's cell on every future dequeue — for the life of the page.
        if !posts.contains(where: { $0.id == heroHiddenPostID }) { heroHiddenPostID = nil }
        let added = Self.addedPosts(from: rawPosts, to: incoming)
        rawPosts = incoming
        showsSkeleton = skeleton
        // ⚠️ An append can change the SECTIONING, not just the item count: a
        // corpus that was entirely new is one unlabelled run, and the first
        // older page landing under it splits the list in two. Inserting items
        // into a collection view whose section count changed in the same pass
        // is the classic inconsistency exception, so that case takes the
        // reload path below instead.
        let splitBefore = split
        if let added, !added.isEmpty, !showsSkeleton, !skeleton, !dissolving, !mustReload,
           splitWouldHold(afterAppending: added.count, to: splitBefore) {
            // Arrange only the newcomers, against the absolute slots they will
            // occupy. Placement depends solely on the absolute index, so the
            // items already on screen cannot move — which is what keeps this an
            // insert rather than a reload.
            //
            // Indexed off `posts`, not off `incoming`: the two are no longer the
            // same order once a swap or a re-rank has happened, and the rows
            // being inserted are this page's, not upstream's.
            let start = posts.count
            posts += arrange(added, startingAt: start)
            collectionView.performBatchUpdates {
                collectionView.insertItems(
                    at: (start..<posts.count).map { indexPath(for: $0) }
                )
            }
            DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
            return
        }
        posts = partitioned(arrange(incoming, startingAt: 0))
        // Kick the leading covers before any cell exists. `preloadAutoplayCovers`
        // keys off visible index paths, which are empty on a first load — the
        // one moment the grid is coldest and the fetch has the most latency to
        // hide.
        preloadLeadingAutoplayCovers()
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
    /// Whether a section carries a pill. False for a single unlabelled run —
    /// see `split`. Asked by the LAYOUT, which is why it is not private.
    func hasHeader(inSection index: Int) -> Bool {
        split > 0 && sections.indices.contains(index)
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        showsSkeleton ? 1 : sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard !showsSkeleton else { return skeletonCount }
        let split = split
        guard split > 0 else { return posts.count }
        return section == 0 ? split : posts.count - split
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: ForYouSectionHeaderView.reuseID,
            for: indexPath
        ) as! ForYouSectionHeaderView
        let section = sections.indices.contains(indexPath.section) ? sections[indexPath.section] : .earlier
        header.setTitle(section.title)
        // Tapping a header means "show me this part" — the same gesture the
        // inbox's pills answer.
        header.onTap = { [weak self] in self?.scrollToSection(indexPath.section) }
        return header
    }

    /// Puts a section's first row directly under its header.
    ///
    /// A no-op for a list too short to scroll: `scrollToItem` cannot invent
    /// content, so a two-section list that already fits stays where it is.
    private func scrollToSection(_ index: Int) {
        guard collectionView.numberOfSections > index,
              collectionView.numberOfItems(inSection: index) > 0
        else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: 0, section: index), at: .top, animated: true
        )
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
                cell.cornerRadius = tileCornerRadius
                return cell
            }
        }
        let post = posts[flatIndex(for: indexPath)]
        // Set on EVERY dequeue, both ways: the flight's stand-in stays hidden
        // across reloads, and a recycled cell can never carry a stale hide to
        // another tile.
        // Either flight hides it, and neither knows about the other.
        let isFlying = post.id == heroHiddenPostID || post.id == revealConcealedPostID
        switch style {
        case .list:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            cell.configure(
                with: post,
                imagePipeline: imagePipeline,
                captionExpanded: captionExpansion.isExpanded(post.id)
            )
            // Captured by POST, never by index path: the row that asked can
            // have moved by the time the answer is applied, and an index path
            // held across a reload names a different post.
            cell.onRevealFullCaption = { [weak self] in
                guard let self else { return }
                captionExpansion.expand(post.id, in: collectionView)
            }
            // Same reason as the tile below: autoplay is gated on the cover, so
            // a cover arriving is the only event that can re-open the gate for
            // a row that came up faceless while the timeline sat still.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            // A COLLECTION row's media is a scroll view, and a scroll view in
            // the content path swallows the collection view's own selection —
            // so a tap on the photograph has to arrive by its own route or the
            // card simply stops opening. Straight into the SAME handler a tap
            // anywhere else on the row lands in.
            // Save, on the row. The pile is the SAME one the post page and the
            // profile's Saved tab read — a second store here would let a card
            // and the post it opens disagree about whether a post is saved.
            //
            // The control never toggles itself: `isBookmarked` is set from the
            // store's answer, before and after, so a store that refused would
            // leave the glyph telling the truth.
            // ⚠️ REPOST HAS NO ACTION YET, and this closure is what makes the
            // control visible anyway.
            //
            // The band hides a button whose handler is nil — visibility tracks
            // the answer — so a repost with nothing behind it would simply not
            // appear. The card's design calls for it, so it is drawn and the
            // request fans out to `onRepostRequested`, which nothing sets.
            // Pressing it does nothing today.
            //
            // What it needs is a real mutation, not a handler: `CreatePost`
            // carries `parent_id` on the wire and `GalleryPost.isRepost` already
            // reads it (the profile's Posts/Reposts split), but `PostComposer`
            // takes no parent, so there is no client path that publishes one.
            cell.onRepostTapped = { [weak self] in self?.onRepostRequested?(post) }
            cell.isBookmarked = bookmarks.isSaved(post.id.rawValue)
            cell.onBookmarkTapped = { [weak self, weak cell] in
                guard let self else { return }
                _ = bookmarks.toggle(post.id.rawValue)
                cell?.isBookmarked = bookmarks.isSaved(post.id.rawValue)
            }
            cell.onMediaTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let path = self.collectionView.indexPath(for: cell) else { return }
                self.collectionView(self.collectionView, didSelectItemAt: path)
            }
            // The comment count opens the same post at its thread. Resolved
            // through the CELL's index path rather than through this closure's
            // captured one: rows are recycled and the list re-renders under
            // them, so the index that was true at configure time is not
            // necessarily true when the finger arrives.
            cell.onCommentsTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let path = self.collectionView.indexPath(for: cell) else { return }
                self.open(at: path, showingComments: true)
            }
            // ⚠️ Paging a MIXED collection changes what should be playing, and
            // nothing else would ask.
            //
            // Autoplay is reconciled when the visible SET changes — a scroll, a
            // surface appearing. A carousel moving inside a stationary row
            // changes neither, so a clip on page two would keep playing behind
            // page three, and a clip on page three would never start.
            cell.onMediaPageChanged = { [weak self] _ in
                self?.updateAutoplay()
            }
            // Hold to pause, the same gesture the post screen carries. Captured
            // by POST rather than by cell for the reason the handlers below
            // state: the row that received the touch can have been recycled by
            // the time the finger lifts, and the clip that must resume is the
            // one belonging to the post, not to whatever the cell shows now.
            cell.onMediaHoldChanged = { [weak self] held in
                self?.playback?.setHeld(held, for: post.id)
            }
            // The band's identity and its "...", if the post carries an author.
            // Captured by AUTHOR and by POST for the same reason the caption's
            // handler is captured by post: the row that asked can have moved by
            // the time the answer is applied.
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
            Self.applyHeroConcealment(isFlying, to: cell)
            return cell
        case .grid:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath
            ) as! PostGridTileCell
            cell.cornerRadius = tileCornerRadius
            cell.configure(with: post, imagePipeline: imagePipeline)
            // Autoplay is gated on the cover, so the arrival of a cover is a
            // reason to re-run the gate. Without this a tile whose cover lands
            // while the grid is stationary fails the gate once and is never
            // asked again.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            cell.isHidden = isFlying
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !showsSkeleton, posts.indices.contains(flatIndex(for: indexPath)) else { return }
        collectionView.deselectItem(at: indexPath, animated: false)
        // The flight leaves from where the cell IS. Nothing moves first:
        // the grid stays visible behind the expanding card, so any offset
        // change here — animated or not — is a jump under the viewer's thumb
        // at the exact moment they are watching that spot.
        //
        // The reveal is remembered and applied once the post has covered the
        // grid (`applyPendingReveal`), where it costs nothing to look at and
        // is finished long before the dismissal flies home to it.
        open(at: indexPath, showingComments: false)
    }

    /// Both ways into a post, so the flight is staged identically either way —
    /// the reveal is remembered here, and forgetting it on one route is how a
    /// dismissal lands on the wrong row.
    private func open(at indexPath: IndexPath, showingComments: Bool) {
        let index = flatIndex(for: indexPath)
        guard posts.indices.contains(index) else { return }
        pendingRevealPostID = posts[index].id
        // ⚠️ CLAIM THE POOL BEFORE THE FLIGHT IS STAGED.
        //
        // A hero can only fly what is already playing: the card asks this page
        // for a live surface while the flight is being built, and the answer is
        // nil for a tile that holds no player. Until the tap is known this tile
        // competed on distance like any other, so the one that MUST be playing
        // could be the one that was not — the flight then carried the thumbnail.
        //
        // Claimed and reconciled in the same breath, so the grant is at least
        // in flight by the time the card asks. It cannot always be finished —
        // a cold tile has to resolve a URL first — which is why the flight
        // keeps asking (see `ZoomFlight`'s live-media retry).
        playback?.focus(posts[index].id)
        updateAutoplay()
        if showingComments, let openComments = onItemCommentsTapped {
            openComments(index)
        } else {
            onItemTapped?(index)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Unthrottled, unlike the autoplay reconcile below: a hosted surface is
        // a separate view tracking a moving cell, and anything less than every
        // frame reads as the video sliding against its own tile.
        onGeometryChanged?()
        positionPagingFooter()
        if hostedTopInset != nil {
            // Content can land without a layout pass reaching the host —
            // re-derive the travel room here (value-guarded, so this is a
            // comparison per tick, not a write) and report for the header.
            applyBottomInset()
            onVerticalScroll?(verticalOffset)
        }
        // Autoplay reconciles DURING the scroll, so a brick starts playing as
        // it slides into view rather than after the scroll has stopped.
        // Throttled rather than run per callback: `scrollViewDidScroll` fires
        // at the display refresh rate, and reconciling at 120 Hz spends more
        // time diffing than the work is worth.
        throttledAutoplayReconcile(scrollView)

        guard !showsSkeleton, !posts.isEmpty else { return }
        let remaining = scrollView.contentSize.height
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        guard remaining < Self.prefetchDistance else { return }
        onNearEnd?()
    }

    /// Asks the host to warm what is on screen. Silent during a fling, and
    /// silent while the page is showing skeletons — there is nothing on screen
    /// then but the shape of what is coming.
    private func requestWarm(_ allowing: Bool) {
        guard allowing, !showsSkeleton, onWarmRequested != nil else { return }
        let visible = collectionView.indexPathsForVisibleItems
            .sorted()
            .map(flatIndex(for:))
            .filter(posts.indices.contains)
            .prefix(Self.warmWindow)
            .map { posts[$0] }
        guard !visible.isEmpty else { return }
        onWarmRequested?(visible)
    }

    /// ⚠️ A CEILING ON THE BURST, because "visible" is not always three cards.
    ///
    /// These rows SELF-SIZE, and until a cell has been measured the layout
    /// holds it at its estimate — so the first reconcile after a render reports
    /// a dozen items inside the viewport, and the trace showed exactly that:
    /// twelve posts asked for at once, each in its own task. Four is what fits
    /// on screen once the heights are real, plus room for the one arriving.
    private static let warmWindow = 4

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
        guard playback != nil, !showsSkeleton else { return }
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
        // Rows as well as tiles: a cell that left the viewport must give its
        // player back whatever the scroll is doing, or the pool starves.
        guard let playable = cell as? any GridPlaybackCell else { return }
        playback?.stop(cell: playable)
    }
}
