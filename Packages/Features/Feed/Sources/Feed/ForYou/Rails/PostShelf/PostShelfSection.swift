import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// A SHELF OF POSTS (#1271): a titled section, a row of media cards and a row
/// of text cards, each row its own horizontal scroller.
///
/// ```
///     Title 5 ›
///   ┌──────┐ ┌──────┐ ┌───       media cards, the third peeking; every
///   │ ▶    │ │ ▶    │ │ ▶        card on screen plays, and each wears its
///   │ Ana  │ │ Bo   │ │          first lines over its foot
///   └──────┘ └──────┘ └───
///   ┌───────────────┐ ┌────      text posts below them, as the list's own
///   │ ◉ Cy · two l… │ │ ◉ D      cards, two lines — a row of their own
///   └───────────────┘ └────
/// ```
///
/// The title, its count and its chevron are the host's (`title`,
/// `setCount`): For You calls it its follows' section, the place page its
/// popular posts, a search its recent ones. The section draws and drives the
/// rest — the cards, their autoplay, their lookahead, their previews and the
/// hooks a flight out of a card reads.
///
/// **Two independent rows** under one heading (`PostShelfRows`):
/// scrolling one never moves the other. A media card is
/// `PostShelfMediaCardCell`; a text card is the list's own card
/// (`PostGridListRowCell`), its like a real stake. Every card is found by its
/// post (`cardRow(for:)`), so the flights, the previews and the
/// bring-into-view read either row the same way; only the media row plays.
///
/// A row with nothing in it is not drawn, and with no posts at all the
/// section is zero tall — no heading over nothing.
///
/// **A tap opens, a long press previews, and nothing gives under a finger**
/// (the product call of 2026-09-29): a tap is the row's own selection, which
/// a scroll never makes; a long press lifts UIKit's native preview, and
/// tapping the preview opens the post the way a tap would.
@MainActor
final class PostShelfSection: UIView {
    /// The height a shelf of `media` media posts and `text` text posts needs
    /// at `width`: its title and its rows, zero with nothing to show.
    static func height(forWidth width: CGFloat, media: Int, text: Int) -> CGFloat {
        guard media + text > 0 else { return 0 }
        return SectionTitleView.Metrics.height
            + PostShelfRows.height(forWidth: width, media: media, text: text)
    }

    /// The height this shelf needs at `width` — while it loads, its title
    /// over one row of skeleton cards (#1296).
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        if showsSkeleton { return Self.loadingHeight(forWidth: width) }
        let counts = rowCounts
        return Self.height(forWidth: width, media: counts.media, text: counts.text)
    }

    /// A loading shelf's height: its title and one media row.
    static func loadingHeight(forWidth width: CGFloat) -> CGFloat {
        SectionTitleView.Metrics.height + LeadRowMetrics.cardSize(forWidth: width).height
    }

    /// Each row's count, as drawn: its posts, under its limit.
    var rowCounts: (media: Int, text: Int) {
        let rows = shownRows
        return (rows.media.count, rows.text.count)
    }

    /// Each row's posts as drawn: the section's order, each row under its
    /// limit (`mediaLimit`, `textLimit`).
    private var shownRows: (media: [GalleryPost], text: [GalleryPost]) {
        let rows = PostShelfRows.partition(cards)
        return (
            mediaLimit.map { Array(rows.media.prefix(max(0, $0))) } ?? rows.media,
            textLimit.map { Array(rows.text.prefix(max(0, $0))) } ?? rows.text
        )
    }

    /// How many cards a row draws by default (the owner, 2026-10-16, #1296).
    nonisolated static let rowLimit = 10

    /// The most cards each row draws; nil for all of them (#1271).
    var mediaLimit: Int? = PostShelfSection.rowLimit { didSet { if mediaLimit != oldValue { rowsChanged() } } }
    var textLimit: Int? = PostShelfSection.rowLimit { didSet { if textLimit != oldValue { rowsChanged() } } }
    /// A chevron card ends EACH row (`ShelfViewAllCell`, the owner,
    /// 2026-10-16, #1296): the title's action — the shelf's "View all" —
    /// where a viewer who scrolled a row to its end arrives. No words: the
    /// chevron is the label. Drawn only while the title has an action.
    var showsViewAll = true { didSet { if showsViewAll != oldValue { rowsChanged() } } }

    /// The shelf is waiting for its posts (#1296): its title over a row of
    /// skeleton cards (`SkeletonBoneView`, the app's loading contract #1085)
    /// rather than nothing. Posts arriving take its place.
    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            let wasShowing = oldValue && cards.isEmpty
            setNeedsLayout()
            if wasShowing != showsSkeleton { onHeightChange?() }
        }
    }

    /// Whether the skeleton is what the shelf draws: loading, with nothing yet.
    private var showsSkeleton: Bool { isLoading && cards.isEmpty }
    private var skeletonCards: [SkeletonBoneView] = []

    /// The item a "View all" card stands for in a row's data source.
    static let viewAllID = PostID("post-shelf.view-all")

    private var drawsViewAll: Bool { showsViewAll && onTitleTapped != nil }

    /// A limit or the "View all" changed: the rows redraw, and the host
    /// re-sizes if a row's count moved.
    private func rowsChanged() {
        let counts = drawnCounts
        applyCards()
        setNeedsLayout()
        if rowCounts != counts { onHeightChange?() }
    }

    /// The rows' counts as last applied — what a change is measured from.
    private var drawnCounts: (media: Int, text: Int) = (0, 0)

    // MARK: - The model

    /// What a host says the shelf is (#1271): its title and count, its posts,
    /// and how much of them each row draws. Applied in one go (`apply`); the
    /// actions (the title's tap, a card's open) are wired once beside it.
    struct Model: Equatable {
        var title: String
        /// What is new in the shelf, after the title; zero for none.
        var newCount = 0
        var posts: [GalleryPost]
        var mediaLimit: Int? = PostShelfSection.rowLimit
        var textLimit: Int? = PostShelfSection.rowLimit
        var showsViewAll = true
        /// Still waiting for the posts: the title over skeleton cards.
        var isLoading = false
    }

    /// Shows `model`. Answers whether the posts changed.
    @discardableResult
    func apply(_ model: Model) -> Bool {
        if title != model.title { title = model.title }
        if newCount != model.newCount { setCount(new: model.newCount) }
        mediaLimit = model.mediaLimit
        textLimit = model.textLimit
        showsViewAll = model.showsViewAll
        let changed = render(model.posts)
        isLoading = model.isLoading
        return changed
    }

    /// The model the shelf shows now.
    var model: Model {
        Model(
            title: title, newCount: newCount, posts: cards,
            mediaLimit: mediaLimit, textLimit: textLimit, showsViewAll: showsViewAll, isLoading: isLoading
        )
    }

    // MARK: - The host's

    /// The section's title — the host's word for what it shows.
    var title = "" {
        didSet { applyHeader() }
    }
    /// The title's count: what is new in the shelf, or nothing.
    private(set) var newCount = 0
    func setCount(new count: Int) {
        newCount = count
        applyHeader()
    }
    /// The title was tapped: the host pushes the shelf's whole list.
    var onTitleTapped: (() -> Void)? {
        didSet {
            header.onTap = onTitleTapped
            if (oldValue == nil) != (onTitleTapped == nil), showsViewAll { applyCards() }
        }
    }
    /// What VoiceOver says the title does.
    var titleAccessibilityHint: String? {
        get { header.accessibilityHint }
        set { header.accessibilityHint = newValue }
    }

    /// A card was tapped, on a shelf with no hero context (`openCard`): its
    /// index into `cards`.
    var onCardTapped: ((Int) -> Void)?
    /// What a long press on a card offers under the preview, after "Open" —
    /// the host's rows (View Profile, Unfollow, Report).
    var cardMenuElements: ((GalleryPost) -> [UIMenuElement])?
    /// A TEXT card's author band was tapped — the host opens their profile,
    /// as the list's cards do.
    var onCardAuthorTapped: ((GalleryPost) -> Void)?
    /// What a TEXT card's "..." offers (Unfollow, Report) — the list's rows,
    /// from the same host; `anchor` is what a sheet raised from it points at.
    /// Nil, or nothing to offer, and the card draws no "...".
    var cardAuthorMenuActions: ((_ post: GalleryPost, _ anchor: UIView) -> [PostCardMenuAction])?
    /// A TEXT card's repost was pressed. Nothing publishes a repost yet, so
    /// nothing sets this — and, as on the list's cards, the control is not
    /// drawn until something does (#801).
    var onCardRepostRequested: ((GalleryPost) -> Void)?
    /// Where a card's like reads the viewer's stake. A media card's heart is
    /// a readout; a TEXT card's like is the list's own chip, and stakes
    /// (`PostCardStaking.bind`).
    var staking: PostCardStaking?
    /// The part of the screen the viewer can see, in THIS view's space, for
    /// autoplay: a card under the navigation bar is not one they are looking
    /// at. Nil (no host yet) plays nothing.
    var visibleBand: (() -> CGRect?)?
    /// The shelf's claim on the pool changed on its OWN account — it
    /// scrolled, a cover landed — so the list under it must re-divide the
    /// budget now. See `claimedPlayers`.
    var onPlayerClaimChange: (() -> Void)?

    /// What a text card's repost control does: nil, which hides it, while
    /// nothing handles a repost (#801).
    func cardRepostHandler(for post: GalleryPost) -> (() -> Void)? {
        guard onCardRepostRequested != nil else { return nil }
        return { [weak self] in self?.onCardRepostRequested?(post) }
    }

    /// `post` with its live like count (#896) — for a card's flight, its
    /// stand-ins and its resting overlay, which must draw the number the
    /// bound card draws, a like made in the feed included.
    func livePost(_ post: GalleryPost) -> GalleryPost {
        staking?.liveCopy(of: post) ?? post
    }

    /// What the viewer has staked on `post` — what a COPY of its card (a
    /// flight's furniture, a close's stand-in) draws its heart from.
    func cardStake(for post: GalleryPost) -> Int {
        staking?.viewerStake(on: post.id) ?? 0
    }

    // MARK: - State

    private(set) var cards: [GalleryPost] = []

    /// The saved pile a text card's save control reads and writes — the one
    /// the list's cards, the post page and the profile's Saved tab share.
    private let bookmarks = PostBookmarkStore.shared
    let header = SectionTitleView(content: .init(title: "", isLink: true))
    /// The media row — the cards that play.
    let mediaView: UICollectionView
    /// The text row, scrolling apart from the media row above it.
    let textView: UICollectionView
    /// Also what a card's COPIES read the author's face from — the flight's
    /// resting overlay, a window's stand-in.
    let imagePipeline: ImagePipeline
    /// The media row's own playback: EVERY card on screen plays, muted —
    /// "all the visible video cards", the product call of 2026-09-29. A card
    /// must be half on screen to count (`GridPlaybackVisibility`), and at 2.3
    /// cards per width no more than three can be — which is the row's budget.
    ///
    /// The pool is shared with the list below (six decoders,
    /// `VideoPlaybackController.capacity`): the list plays what the shelf's
    /// claim leaves it (`ForYouGridPage.playerReserve`, fed `claimedPlayers`).
    private let playback: GridVideoPlaybackCoordinator?
    static let concurrentPlayers = 3
    /// How many players the shelf holds as of its last reconcile — what the
    /// list under it subtracts from the pool's budget.
    private(set) var claimedPlayers = 0

    /// The media row's lookahead (#970): a screen width ahead decoded, two
    /// and a half on disk. Outside the list's display window it plans nothing
    /// (`refreshLookaheadReach`).
    private lazy var cardLookahead: ScrollLookahead = {
        let lookahead = ScrollLookahead(pipeline: imagePipeline, name: "post-shelf.media", kind: .rail) { [weak self] path in
            guard let self, let id = mediaSource.itemIdentifier(for: path),
                  let post = cards.first(where: { $0.id == id }) else { return [] }
            return post.lookaheadImages
        }
        lookahead.attach(to: mediaView)
        return lookahead
    }()

    private var mediaSource: UICollectionViewDiffableDataSource<Int, PostID>!
    private var textSource: UICollectionViewDiffableDataSource<Int, PostID>!

    /// The card a flight is carrying, hidden until it lands.
    private var concealedCard: PostID?
    private let snapper = RowSnapper()

    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController?) {
        self.imagePipeline = imagePipeline
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: Self.concurrentPlayers)
        }
        mediaView = RowGeometry.makeRow(itemSize: CGSize(width: 150, height: 200))
        textView = RowGeometry.makeRow(itemSize: CGSize(width: 316, height: 150))
        super.init(frame: .zero)
        addSubview(header)
        for row in [mediaView, textView] {
            row.delegate = self
            addSubview(row)
        }
        mediaView.register(PostShelfMediaCardCell.self, forCellWithReuseIdentifier: PostShelfMediaCardCell.reuseID)
        textView.register(PostGridListRowCell.self, forCellWithReuseIdentifier: PostGridListRowCell.reuseID)
        for row in [mediaView, textView] {
            row.register(ShelfViewAllCell.self, forCellWithReuseIdentifier: ShelfViewAllCell.reuseID)
        }
        textSource = UICollectionViewDiffableDataSource(collectionView: textView) {
            [weak self] view, indexPath, id in
            if id == Self.viewAllID {
                return view.dequeueReusableCell(withReuseIdentifier: ShelfViewAllCell.reuseID, for: indexPath)
            }
            let cell = view.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            guard let self, let post = cards.first(where: { $0.id == id }) else { return cell }
            configureTextCard(cell, with: post)
            return cell
        }
        mediaSource = UICollectionViewDiffableDataSource(collectionView: mediaView) {
            [weak self] view, indexPath, id in
            if id == Self.viewAllID {
                return view.dequeueReusableCell(withReuseIdentifier: ShelfViewAllCell.reuseID, for: indexPath)
            }
            let cell = view.dequeueReusableCell(
                withReuseIdentifier: PostShelfMediaCardCell.reuseID, for: indexPath
            ) as! PostShelfMediaCardCell
            guard let self, let post = cards.first(where: { $0.id == id }) else { return cell }
            cell.configure(with: post, imagePipeline: imagePipeline)
            // The heart closing the author line reads the viewer's stake.
            staking?.bindReadout(cell, to: post.id)
            // Autoplay is gated on the cover: its arrival re-opens the gate
            // for a card that came up faceless while the row sat still.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            cell.isHidden = id == concealedCard
            return cell
        }
        header.isHidden = true
        mediaView.isHidden = true
        textView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyHeader() {
        header.content = .init(title: title, newCount: newCount, isLink: true)
    }

    // MARK: - Content

    /// Shows `posts`, each in its row (`PostShelfRows`). Answers
    /// whether anything changed.
    @discardableResult
    func render(_ posts: [GalleryPost]) -> Bool {
        guard posts != cards else { return false }
        let counts = drawnCounts
        cards = posts
        applyCards()
        cardLookahead.setNeedsPlan()
        setNeedsLayout()
        // The height is the title and the rows: it moves only with a row's
        // count.
        if rowCounts != counts { onHeightChange?() }
        return true
    }

    /// The shelf's rows changed how many posts they hold — its host re-sizes.
    var onHeightChange: (() -> Void)?

    /// Each row its own posts, in the section's order, under its limit; the
    /// last row ends on "View all" when the shelf offers it.
    private func applyCards() {
        let rows = shownRows
        drawnCounts = (rows.media.count, rows.text.count)
        func snapshot(_ posts: [GalleryPost], endsOnViewAll: Bool) -> NSDiffableDataSourceSnapshot<Int, PostID> {
            var snapshot = NSDiffableDataSourceSnapshot<Int, PostID>()
            snapshot.appendSections([0])
            snapshot.appendItems(posts.map(\.id))
            if endsOnViewAll, !posts.isEmpty { snapshot.appendItems([Self.viewAllID]) }
            return snapshot
        }
        let animated = window != nil
        mediaSource.apply(
            snapshot(rows.media, endsOnViewAll: drawsViewAll), animatingDifferences: animated
        ) { [weak self] in
            self?.updateAutoplay()
        }
        textSource.apply(snapshot(rows.text, endsOnViewAll: drawsViewAll), animatingDifferences: animated)
    }

    /// A text card: the list's own card (`PostGridListRowCell`) held to the
    /// row's two lines, wired as the list wires its cards — the like stakes,
    /// the save writes the shared pile, the band opens the author and its
    /// "..." offers the host's rows, the comment count opens the post. A tap
    /// anywhere else is the row's own selection.
    private func configureTextCard(_ cell: PostGridListRowCell, with post: GalleryPost) {
        cell.configure(
            with: post, imagePipeline: imagePipeline, captionLines: PostShelfRows.textLines
        )
        // The like chip stakes — see `PostCardStaking`.
        staking?.bind(cell, to: post.id)
        // As on the list's cards: no handler, no repost control (#801).
        cell.onRepostTapped = cardRepostHandler(for: post)
        cell.isBookmarked = bookmarks.isSaved(post.id.rawValue)
        cell.onBookmarkTapped = { [weak self, weak cell] in
            guard let self, let cell else { return }
            MemberGates.perform(.save, from: cell) { [weak self, weak cell] in
                guard let self else { return }
                _ = bookmarks.toggle(post.id.rawValue)
                // The fill says it; the hand feels it (#803).
                Feedback.toggled()
                cell?.isBookmarked = bookmarks.isSaved(post.id.rawValue)
            }
        }
        // Captured by POST, never by index path — the list's rule: the row
        // can have changed by the time the finger arrives.
        cell.onCommentsTapped = { [weak self] in self?.open(post.id) }
        if post.authorID != nil {
            cell.onAuthorTapped = { [weak self] in self?.onCardAuthorTapped?(post) }
            cell.authorMenuActions = { [weak self, weak cell] in
                guard let self, let cell else { return [] }
                return cardAuthorMenuActions?(post, cell.authorMenuAnchor) ?? []
            }
        }
        cell.isHidden = post.id == concealedCard
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let counts = rowCounts
        layoutSkeleton(width: width)
        header.isHidden = cards.isEmpty && !showsSkeleton
        // Each row hides itself with nothing in it; the heading stays over
        // whichever row there is.
        mediaView.isHidden = counts.media == 0
        textView.isHidden = counts.text == 0
        if showsSkeleton {
            header.frame = CGRect(x: 0, y: 0, width: width, height: SectionTitleView.Metrics.height)
        }
        guard !cards.isEmpty else { return }
        // The title spans the row edge to edge: it stands its own inset from
        // the surface (`SectionTitleView.Metrics.surfaceInset`).
        header.frame = CGRect(x: 0, y: 0, width: width, height: SectionTitleView.Metrics.height)
        var y = SectionTitleView.Metrics.height
        if counts.media > 0 {
            let size = LeadRowMetrics.cardSize(forWidth: width)
            RowGeometry.setItemSize(size, of: mediaView)
            mediaView.frame = CGRect(x: 0, y: y, width: width, height: size.height)
            y += size.height
            if counts.text > 0 { y += PostShelfRows.rowGap }
        }
        if counts.text > 0 {
            let size = textCardSize(forWidth: width)
            RowGeometry.setItemSize(size, of: textView)
            textView.frame = CGRect(x: 0, y: y, width: width, height: size.height)
        }
    }

    /// The skeleton row while loading: as many card-shaped bones as the width
    /// shows (two whole and one peeking), at the media cards' size and gap —
    /// the shelf's own shape, so the posts arriving change nothing but the
    /// pictures.
    private func layoutSkeleton(width: CGFloat) {
        guard showsSkeleton, width > 0 else {
            skeletonCards.forEach { $0.removeFromSuperview() }
            skeletonCards = []
            return
        }
        let size = LeadRowMetrics.cardSize(forWidth: width)
        let count = Int(LeadRowMetrics.cardsPerWidth.rounded(.up))
        while skeletonCards.count < count {
            let bone = SkeletonBoneView(rounding: .fixed(PostShelfMediaCardCell.cornerRadius))
            addSubview(bone)
            skeletonCards.append(bone)
        }
        for (index, bone) in skeletonCards.enumerated() {
            let x = LeadRowMetrics.sideMargin + CGFloat(index) * (size.width + LeadRowMetrics.itemGap)
            bone.frame = CGRect(x: x, y: SectionTitleView.Metrics.height, width: size.width, height: size.height)
        }
    }

    /// A text card's size at `width` — measured once per width, since it is
    /// a real card laid out (`PostGridListRowCell.fixedTextCardHeight`).
    private func textCardSize(forWidth width: CGFloat) -> CGSize {
        if let cached = textCardSizeCache, cached.width == width { return cached.size }
        let size = PostShelfRows.textCardSize(forWidth: width)
        textCardSizeCache = (width, size)
        return size
    }

    private var textCardSizeCache: (width: CGFloat, size: CGSize)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A stay on screen: a new owner, revoked when it leaves.
        cardLookahead.setOnScreen(window != nil)
        refreshLookaheadReach()
    }

    /// Whether the shelf sits in the list's display window (a screen ahead of
    /// the viewport, half a screen behind): outside it, the row plans nothing
    /// (#970).
    private func refreshLookaheadReach() {
        guard let window else { return }
        let reach = LookaheadWindow.display.rect(around: window.bounds, axis: .vertical, forward: true)
        let shown = !isHidden && !(superview?.isHidden ?? false)
        cardLookahead.setInParentWindow(shown && convert(bounds, to: window).intersects(reach))
    }

    // MARK: - Autoplay

    private var isAutoplayActive = false

    /// The screen is (or is no longer) the viewer's: covered by a post, a
    /// pushed screen, another tab. Nothing plays while it is not.
    func setAutoplayActive(_ active: Bool) {
        isAutoplayActive = active
        // Covered but alive: the row drops to the minimum windows (#970).
        cardLookahead.setHidden(!active)
        playback?.setSurfaceVisible(active)
        if active { updateAutoplay() }
    }

    /// Reconciles the row's players against what is on screen. Cheap and
    /// idempotent; the host calls it as the LIST scrolls (the shelf moving in
    /// or out of the band) and the shelf calls it as ITS ROW scrolls.
    ///
    /// - Parameter notifiesClaimChange: false from the list's own reconcile,
    ///   which reads `claimedPlayers` straight after — telling it to reconcile
    ///   again from inside that reconcile would re-enter it.
    func updateAutoplay(allowingStarts: Bool = true, notifiesClaimChange: Bool = true) {
        // Called as the LIST scrolls too: the row's reach follows it.
        refreshLookaheadReach()
        let before = claimedPlayers
        claimedPlayers = reconcilePlayback(allowingStarts: allowingStarts)
        if notifiesClaimChange, claimedPlayers != before { onPlayerClaimChange?() }
    }

    /// The reconcile proper; answers how many players the shelf now holds.
    private func reconcilePlayback(allowingStarts: Bool) -> Int {
        guard let playback else { return 0 }
        guard isAutoplayActive, !mediaView.isHidden, let band = visibleBand?() else {
            playback.update(candidates: [], allowingStarts: allowingStarts)
            return 0
        }
        // The band, in the row's CONTENT space: the scroll view's bounds are
        // its content offset, so a card's frame compares directly.
        let viewport = mediaView.convert(band, from: self).intersection(mediaView.bounds)
        let tiles = mediaView.indexPathsForVisibleItems.compactMap {
            indexPath -> GridAutoplayRanking.Tile? in
            guard let id = mediaSource.itemIdentifier(for: indexPath),
                  id != concealedCard,
                  let post = cards.first(where: { $0.id == id }),
                  post.hasPlayableVideo, let url = post.videoURL,
                  let cell = mediaView.cellForItem(at: indexPath) as? PostShelfMediaCardCell,
                  hasCover(post, in: cell)
            else { return nil }
            return .init(id: id, url: url, cell: cell, mediaFrame: cell.frame, isPaused: false)
        }
        // Every card half on screen plays (a null band admits none); the
        // ranking only matters when the budget is short, and then the row is
        // ranked from its left edge, so the card nearest it keeps its player.
        let candidates = GridAutoplayRanking.candidates(from: tiles, in: viewport, reference: .minXEdge)
        playback.update(candidates: candidates, allowingStarts: allowingStarts)
        return GridAutoplayRanking.playersHeld(candidateCount: candidates.count, budget: Self.concurrentPlayers)
    }

    /// A card may play only once it has a face behind its surface — the
    /// list's own gate (`ForYouGridPage.hasCover`), for the same black-tile
    /// reason.
    private func hasCover(_ post: GalleryPost, in cell: PostShelfMediaCardCell) -> Bool {
        guard let thumbnail = post.thumbnailURL else { return true }
        if cell.renderedCover != nil { return true }
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        cell.applyCover(cached)
        return true
    }

    /// Opens the handoff for a card a flight is about to carry: the row's
    /// reconcile must neither restart nor stop its player while it is in the
    /// air.
    ///
    /// The card's own clip is parked as well, paused at its playhead, for a
    /// close that pages on and comes home here (#923, `returnCardSurface`).
    func beginPlaybackHandoff(of id: PostID) {
        landingCard = nil
        playback?.focus(id)
        updateAutoplay()
        playback?.beginHandoff(id, parkingReturn: true)
    }

    /// The card's own clip, resumed from where it was parked at the tap — the
    /// arriving picture of a close from another post (#923). Nil when nothing
    /// is parked, and the close lands on the card's still.
    func returnCardSurface(for id: PostID) -> VideoRenderView? {
        playback?.makeReturnSurface(for: id)
    }

    /// A close that resumed the card's return player was abandoned.
    func pauseReturnPlayback(for id: PostID) {
        playback?.pauseReturnPlayback(of: id)
    }

    func endPlaybackHandoff() {
        landingCard = nil
        playback?.endHandoff()
        playback?.focus(nil)
        updateAutoplay()
    }

    // MARK: - As a flight's source

    /// The row card `id` is in, and where in it — the media row or the text
    /// row.
    func cardRow(for id: PostID) -> (row: UICollectionView, indexPath: IndexPath)? {
        if let indexPath = mediaSource.indexPath(for: id) { return (mediaView, indexPath) }
        if let indexPath = textSource.indexPath(for: id) { return (textView, indexPath) }
        return nil
    }

    /// Card `id`'s cell, whichever row it is in.
    private func cardCell(for id: PostID) -> UICollectionViewCell? {
        cardRow(for: id).flatMap { $0.row.cellForItem(at: $0.indexPath) }
    }

    /// The post a row shows at `indexPath`.
    private func cardID(in row: UICollectionView, at indexPath: IndexPath) -> PostID? {
        if row === mediaView { return mediaSource.itemIdentifier(for: indexPath) }
        if row === textView { return textSource.itemIdentifier(for: indexPath) }
        return nil
    }

    /// A MEDIA card's cell — what plays, and what a flight carries.
    func mediaCardCell(for id: PostID) -> PostShelfMediaCardCell? {
        cardCell(for: id) as? PostShelfMediaCardCell
    }

    /// A TEXT card's cell — the list's own card.
    func textCardCell(for id: PostID) -> PostGridListRowCell? {
        cardCell(for: id) as? PostGridListRowCell
    }

    /// The card's rect in `space`, at rest — see `RowGeometry.restingFrame`.
    func cardFrame(for id: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let (row, indexPath) = cardRow(for: id), let cell = row.cellForItem(at: indexPath),
              RowGeometry.isInRow(cell, row) else { return nil }
        return RowGeometry.restingFrame(of: cell, below: row, in: space)
    }

    /// A media card's picture — nil for a text card, which has none.
    func cardCover(for id: PostID) -> UIImage? {
        mediaCardCell(for: id)?.renderedCover
    }

    // MARK: - A text card, for the window it opens through

    /// What the list's text rows hand their window (`ForYouGridPage`'s
    /// `textRowCaptionEnd` / `textRowCaptionTop` / `textRowAuthorBand`), for a
    /// text card — read off the realized card, nil (or zero) when it is not.
    func textCardCaptionEnd(for id: PostID) -> CGFloat? {
        textCardCell(for: id)?.revealCut
    }

    func textCardCaptionTop(for id: PostID) -> CGFloat {
        textCardCell(for: id)?.revealCaptionTop ?? 0
    }

    func textCardAuthorBand(for id: PostID) -> PostAuthorBandView.Model? {
        if let model = textCardCell(for: id)?.authorBandModel { return model }
        return cards.first { $0.id == id }.map { PostAuthorBandView.Model(post: $0) }
    }

    /// The card a window lands as — the list's own stand-in
    /// (`RevealDismissCardView`) at this card's size, caption held to the
    /// row's lines and its closing line drawing what the card draws, so the
    /// landing swaps it for the card without a word or a control changing.
    /// Nil while the card has no size to measure.
    func makeTextCardStandIn(for id: PostID) -> UIView? {
        guard let post = cards.first(where: { $0.id == id }).map(livePost) else { return nil }
        let cell = textCardCell(for: id)
        // The realized card's size, else the row's — every text card in the
        // row is the same size.
        let size = cell?.bounds.size
            ?? textSource.indexPath(for: id).flatMap { textView.layoutAttributesForItem(at: $0)?.size }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return RevealDismissCardView(
            post: post,
            width: size.width,
            imagePipeline: imagePipeline,
            showsAuthorMenu: showsAuthorMenu(for: post),
            actions: .init(
                repost: onCardRepostRequested != nil, bookmark: true, saved: bookmarks.isSaved(id.rawValue),
                stake: staking?.viewerStake(on: id)
            ),
            ageText: cell?.renderedAgeText,
            height: size.height,
            captionLines: PostShelfRows.textLines
        )
    }

    /// Whether a text card draws a "...", asked of the provider the card asks
    /// — the stand-in must match it, or the control pops in the last frame.
    private func showsAuthorMenu(for post: GalleryPost) -> Bool {
        guard post.authorID != nil, let cardAuthorMenuActions else { return false }
        return !cardAuthorMenuActions(post, UIView()).isEmpty
    }

    func isCardOnScreen(_ id: PostID) -> Bool {
        guard let (row, indexPath) = cardRow(for: id), let cell = row.cellForItem(at: indexPath)
        else { return false }
        return RowGeometry.isVisible(cell, in: row)
    }

    func setCardConcealed(_ concealed: Bool, for id: PostID) {
        if concealed { concealedCard = id } else if concealedCard == id { concealedCard = nil }
        cardCell(for: id)?.isHidden = concealed
        // A committed window close is landing: the card takes the clip its
        // window was playing (#1294).
        if !concealed, let playback, let cell = mediaCardCell(for: id) {
            let hasThumbnail = cards.first { $0.id == id }?.thumbnailURL != nil
            windowClips.land(
                id, over: cell.contentView,
                land: { playback.landReturnPlayback($0, for: id, cell: cell) },
                isReady: { [weak cell] in
                    playback.isReturnLandingReady(for: id, cell: cell, hasThumbnail: hasThumbnail)
                }
            )
        }
    }

    /// The parked clips a card window is playing, until it lands (#1294).
    let windowClips = WindowReturnClips()

    /// `standIn` playing card `id`'s parked clip, when there is one (#1294).
    func dressWithReturnClip(_ standIn: UIView?, for id: PostID) -> UIView? {
        windowClips.dress(standIn, for: id) { returnCardSurface(for: id) }
    }

    /// A card window's close is over: one that sprang back pauses the clip.
    func windowCloseDidEnd(_ committed: Bool, for id: PostID) {
        guard !committed else { return }
        windowClips.abandon(id) { pauseReturnPlayback(for: id) }
    }

    /// Puts the card a flight hid back.
    func clearConcealments() {
        if let concealedCard { setCardConcealed(false, for: concealedCard) }
    }

    /// A surface already showing the card's playback, for the flight to take
    /// off playing — the list's own `liveFlightSurface`, for the row.
    func liveCardSurface(for id: PostID) -> VideoRenderView? {
        guard let playback, let post = cards.first(where: { $0.id == id }),
              let url = post.videoURL else { return nil }
        if let made = playback.makeAttachedSurface(for: id, url: url) { return made }
        // Nothing to join: ask, rather than report the absence — the flight
        // asks again every frame, and a start kicked here is what the next ask
        // finds.
        if let cell = mediaCardCell(for: id) {
            playback.demandFlightPlayback(of: id, url: url, in: cell)
        }
        return nil
    }

    /// A close is landing on card `id` with the page's live `view`: the card
    /// takes that playback onto its OWN surface — the list's own landing
    /// (`ForYouGridPage.adoptLivePlayback`), for the row.
    ///
    /// ⚠️ THE THUMBNAIL FLASH AT THE END OF A CLOSE. Without this the flight
    /// card was removed over a card still showing what it rested on while the
    /// feed covered the row — its poster, or a frame from before the open —
    /// and its player only resumed once the screen had appeared and the row
    /// reconciled. Here the card's surface is primed with the page's current
    /// frame and takes the pool loan before the flight card goes, and
    /// `isLandingPlaybackReady` holds the flight card over it until it draws.
    ///
    /// Unconcealed FIRST: a surface outside a visible hierarchy is skipped by
    /// the renderer and would never report drawing. The flight card is still
    /// on top, at the same rect, so revealing the card under it shows nothing.
    func adoptLandingPlayback(_ view: UIView, for id: PostID) {
        guard let playback, let post = cards.first(where: { $0.id == id }),
              let url = post.videoURL, let cell = mediaCardCell(for: id)
        else { return }
        setCardConcealed(false, for: id)
        if VideoRenderFlags.usesSampleBufferLayer {
            // One playback, several surfaces: the card gets its own, primed on
            // attach, and the flight card's is released once it leaves the
            // window. Nothing is re-parented.
            if playback.adoptAttachedSurface(
                for: id, url: url, cell: cell, drawnBy: view as? VideoRenderView
            ) { landingCard = id }
            return
        }
        guard let view = view as? VideoRenderView else { return }
        playback.adoptLiveSurface(view, for: id, url: url, cell: cell)
        landingCard = id
    }

    /// The card a close's live surface was handed to, until the handoff ends
    /// — the one whose landing waits on its clip rather than on its cover.
    private var landingCard: PostID?

    /// Whether card `id` is showing what the landing needs it to: its clip
    /// drawing, for a card that took the flight's playback; its cover,
    /// otherwise — `ForYouGridPage.isLandingPlaybackReady`'s rule, for the
    /// row. The flight card's hold has a ceiling, so a card that never gets
    /// there costs a pause, not a stuck card.
    ///
    /// ⚠️ ONLY A CARD THAT ADOPTED waits on its clip. A close that flew no
    /// video left nothing playing here until the row reconciles on appearing,
    /// so asking the pool would hold every such landing for the hold's whole
    /// ceiling.
    func isLandingPlaybackReady(for id: PostID) -> Bool {
        guard let post = cards.first(where: { $0.id == id }) else { return true }
        let cell = mediaCardCell(for: id)
        if let playback, landingCard == id {
            return playback.isSurfaceRendering(for: id)
        }
        guard let cell, post.thumbnailURL != nil else { return true }
        return cell.renderedCover != nil
    }

    /// In ITS row — the media row or the text row; the other row stays where
    /// the viewer left it.
    func bringCardIntoView(_ id: PostID) {
        guard let (row, indexPath) = cardRow(for: id) else { return }
        RowGeometry.bringIntoView(indexPath, in: row)
    }

    // MARK: - Opening

    /// What a shelf's flight needs from its host, set once (#1271): the list
    /// the shelf leads (it stops playing for the flight and holds still for
    /// the close), the view the flight measures in, and the host's own
    /// arrangement for the landing.
    struct HeroContext {
        weak var page: ForYouGridPage?
        weak var host: UIView?
        /// For You's arrangement: the page is pinned only for the close, and
        /// handed back as it lands. A PUSHED host passes false — see
        /// `PostShelfOrigins.card`'s `thawsOnLanding` (#924).
        var thawsOnLanding = true
        /// How many posts from the tapped one on the opened feed is seeded
        /// with.
        var seedWindow = 40
        /// Runs once a close has staged — the host's log, say.
        var closeStaged: () -> Void = {}
    }

    /// A card being opened: the post, the feed it opens into, and the origin
    /// the SHELF built for the flight — a host never builds one by hand.
    struct Open {
        let post: GalleryPost
        let stream: [GalleryPost]
        let origin: SnapFeedHeroOrigin
    }

    var heroContext: HeroContext?
    /// Whether a card may open now (a transition under way, say, says no).
    var shouldOpen: (() -> Bool)?
    /// A card is opening: the handoff has begun, the list has stopped playing
    /// — the host presents `open.origin`.
    var onOpen: ((Open) -> Void)?

    /// Opens card `index` (into `cards`): the shelf's flight, handed to the
    /// host through `onOpen`. Without a hero context it is reported as a bare
    /// tap (`onCardTapped`).
    func openCard(at index: Int) {
        guard cards.indices.contains(index) else { return }
        guard let context = heroContext, let page = context.page, let host = context.host, onOpen != nil else {
            onCardTapped?(index)
            return
        }
        guard shouldOpen?() ?? true else { return }
        let tapped = cards[index]
        let stream = Array(cards[index...].prefix(context.seedWindow))
        // The card's player is the flight's from here; the list stops.
        beginPlaybackHandoff(of: tapped.id)
        page.setAutoplayActive(false)
        let origin = PostShelfOrigins.card(
            tapped, stream: stream, shelf: self, page: page, host: host,
            thawsOnLanding: context.thawsOnLanding, closeStaged: context.closeStaged
        )
        onOpen?(Open(post: tapped, stream: stream, origin: origin))
    }

    /// Opens card `id` the way a tap would — nothing if it left the shelf
    /// while a menu was up.
    func open(_ id: PostID) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        openCard(at: index)
    }

    // MARK: - The long press

    func cardMenu(for post: GalleryPost) -> UIMenu {
        let id = post.id
        let open = RowGeometry.openAction { [weak self] in self?.open(id) }
        return UIMenu(children: [open] + (cardMenuElements?(post) ?? []))
    }

    /// The card the lift is made of, on its own curve: the list's card for
    /// words — not the whole cell, whose rectangle would flash its square
    /// corners under the lift.
    private func targetedPreview(in row: UICollectionView, at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = row.cellForItem(at: indexPath), cell.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let card = cell.contentView
        let radius = cell is PostGridListRowCell
            ? PostGridListRowCell.cardCornerRadius
            : PostShelfMediaCardCell.cornerRadius
        parameters.visiblePath = UIBezierPath(roundedRect: card.bounds, cornerRadius: radius)
        return UITargetedPreview(view: card, parameters: parameters)
    }

    /// Whether `scrollView` is one of the shelf's rows.
    func owns(_ scrollView: UIScrollView) -> Bool {
        scrollView === mediaView || scrollView === textView
    }

    #if DEBUG
    /// Where card `index` (into `cards`) sits — its row and its index path
    /// there.
    func debugCardPlace(at index: Int) -> (row: UICollectionView, indexPath: IndexPath)? {
        guard cards.indices.contains(index) else { return nil }
        return cardRow(for: cards[index].id)
    }

    /// The long-press configuration for card `index`, through the row's own
    /// delegate path.
    func debugCardMenuConfiguration(at index: Int, point: CGPoint = .zero) -> UIContextMenuConfiguration? {
        guard let (row, indexPath) = debugCardPlace(at: index) else { return nil }
        return collectionView(row, contextMenuConfigurationForItemsAt: [indexPath], point: point)
    }

    /// `media 2` / `text 0` — the row and item card `index` is, for a log.
    func debugCardPlaceName(at index: Int) -> String? {
        debugCardPlace(at: index).map { "\($0.row === textView ? "text" : "media") \($0.indexPath.item)" }
    }

    /// Card `index`'s frame in its row's content space, from its layout.
    func debugCardLayoutFrame(at index: Int) -> CGRect? {
        debugCardPlace(at: index).flatMap { $0.row.layoutAttributesForItem(at: $0.indexPath)?.frame }
    }

    /// MEDIA card `index`'s cell, when the row has realized it.
    func debugCardCell(at index: Int) -> PostShelfMediaCardCell? {
        guard cards.indices.contains(index) else { return nil }
        return mediaCardCell(for: cards[index].id)
    }

    /// TEXT card `index`'s cell — the list's own card — when realized.
    func debugTextCardCell(at index: Int) -> PostGridListRowCell? {
        guard cards.indices.contains(index) else { return nil }
        return textCardCell(for: cards[index].id)
    }

    /// The menu a long press on card `index` would show — its rows' titles.
    func debugCardMenuTitles(at index: Int) -> [String] {
        guard cards.indices.contains(index) else { return [] }
        return cardMenu(for: cards[index]).children.map(\.title)
    }

    /// Whether card `index` has a face to fly — what a scripted open waits on.
    func debugCardIsReady(at index: Int) -> Bool {
        guard cards.indices.contains(index) else { return false }
        let post = cards[index]
        guard post.kind != .text else { return true }
        return mediaCardCell(for: post.id)?.renderedCover != nil
    }

    /// Opens what a committed preview would — the commit's own path, minus
    /// UIKit's animator.
    func debugCommitPreview(_ configuration: UIContextMenuConfiguration) {
        guard case .card(let id)? = RowMenuTarget(configuration.identifier) else { return }
        open(id)
    }

    /// Taps card `index` through the row's own selection path.
    func debugTapCard(at index: Int) -> Bool {
        guard let (row, indexPath) = debugCardPlace(at: index) else { return false }
        collectionView(row, didSelectItemAt: indexPath)
        return true
    }

    /// The title's OWN tap path (`SectionTitleView.debugTap`), not the host's
    /// closure: calling the closure is how #312's dead chevron passed.
    func debugTapTitle() { header.debugTap() }

    /// Taps the "View all" card through its row's selection path; false when
    /// no row ends on one.
    func debugTapViewAll() -> Bool {
        for (row, source) in [(mediaView, mediaSource!), (textView, textSource!)] {
            if let indexPath = source.indexPath(for: Self.viewAllID) {
                collectionView(row, didSelectItemAt: indexPath)
                return true
            }
        }
        return false
    }

    /// The posts each row holds as drawn, "View all" left out.
    var debugRowIDs: (media: [PostID], text: [PostID]) {
        (mediaSource.snapshot().itemIdentifiers.filter { $0 != Self.viewAllID },
         textSource.snapshot().itemIdentifiers.filter { $0 != Self.viewAllID })
    }
    var debugCountText: String? { header.debugCountText }
    #endif
}

// MARK: - The rows' delegate

extension PostShelfSection: UICollectionViewDelegateFlowLayout {
    /// Every card at the row's size; the chevron card ending the row narrow
    /// (`ShelfViewAllCell.width`), as tall as the row.
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let size = (collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize ?? .zero
        guard cardID(in: collectionView, at: indexPath) == Self.viewAllID else { return size }
        return CGSize(width: ShelfViewAllCell.width, height: size.height)
    }

    /// ⚠️ THE GAP, STATED HERE TOO (#1296 follow-up). Once this delegate sizes
    /// the items, the layout stopped applying the row's `minimumLineSpacing`
    /// and the cards touched (measured: spacing 16, gap 0) — filmed on device.
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
        LeadRowMetrics.itemGap
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
        LeadRowMetrics.itemGap
    }
}

extension PostShelfSection: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = cardID(in: collectionView, at: indexPath) else { return }
        guard id != Self.viewAllID else {
            onTitleTapped?()
            return
        }
        open(id)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        snapper.didScroll(scrollView)
        guard scrollView === mediaView else { return }
        cardLookahead.scrollViewDidScroll()
        // Only the media row plays; the text row scrolls past nothing to
        // start. A horizontal row is short: reconciling on every tick costs a
        // diff of three cards, and a card that comes half into view should
        // start as it arrives, not when the finger lifts.
        updateAutoplay()
    }

    /// A row came to rest: its fling is over, and its display window decodes.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === mediaView { cardLookahead.scrollViewDidEndScrolling() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard owns(scrollView) else { return }
        snapper.willBeginDragging(scrollView)
    }

    /// The row comes to rest on an item's edge — the text row ONE card per
    /// gesture (`RowSnapper`).
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard let row = scrollView as? UICollectionView, owns(row) else { return }
        snapper.willEndDragging(
            row, velocity: velocity, targetContentOffset: targetContentOffset, stepped: row === textView
        )
    }

    /// Where `row` rests after a release.
    func snapTarget(
        in row: UICollectionView, projected: CGFloat, start: CGFloat, direction: ForYouRowSnap.Direction?
    ) -> CGFloat {
        RowSnapper.snapTarget(
            in: row, projected: projected, start: start, direction: direction, stepped: row === textView
        )
    }

    /// A long press lifts the card's post with the menu under it, keyed by an
    /// identifier that says which card, so the commit below finds it again
    /// even if the row changed while the menu was up.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let id = cardID(in: collectionView, at: indexPath),
              let post = cards.first(where: { $0.id == id }) else { return nil }
        let width = max(0, bounds.width - LeadRowMetrics.sideMargin * 2)
        let pipeline = imagePipeline
        return UIContextMenuConfiguration(
            identifier: RowMenuTarget.card(id).identifier,
            previewProvider: {
                ForYouPostPreviewViewController(post: post, imagePipeline: pipeline, width: width)
            },
            actionProvider: { [weak self] _ in self?.cardMenu(for: post) }
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        targetedPreview(in: collectionView, at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        targetedPreview(in: collectionView, at: indexPath)
    }

    /// Tapping the lifted preview opens the post — the same open as a tap on
    /// the card, through the same flight.
    ///
    /// ⚠️ `.dismiss`, THEN OUR HERO — not UIKit's `.pop`. The open is a flight
    /// OUT OF THE CARD: it conceals the source, hands the card's player to
    /// the page, and the close lands back on that same card. A `.pop` commit
    /// grows the preview into a destination UIKit presents itself, and none
    /// of that would hold. So the preview settles back into its card first
    /// and the flight takes off from there; the open waits one turn past the
    /// completion so UIKit has put the card back before the flight measures
    /// and hides it.
    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard case .card(let id)? = RowMenuTarget(configuration.identifier) else { return }
        animator.preferredCommitStyle = .dismiss
        animator.addCompletion { [weak self] in
            DispatchQueue.main.async { self?.open(id) }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // A card that left gives its player back now — the pool is shared.
        guard collectionView === mediaView, let card = cell as? PostShelfMediaCardCell else { return }
        playback?.stop(cell: card)
    }
}
