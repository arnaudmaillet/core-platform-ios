import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit
import CoreNavigation

/// The two rows that lead For You's list (2026-09-29):
///
/// ```
///     Friends 3 ›
///   ◉ ◉ ◉ ○ ○ ○ ○          stories: unseen first, with a ring
///     Following 5 ›
///   ┌──────┐ ┌──────┐ ┌───       media cards, the third peeking;
///   │ ▶    │ │ ▶    │ │ ▶         every card on screen plays,
///   │ Ana  │ │ Bo   │ │           and each wears its first two
///   │ two… │ │ two… │ │           lines over its foot
///   └──────┘ └──────┘ └───
///   ┌───────────────┐ ┌────       text posts below them, as the
///   │ ◉ Cy · two l… │ │ ◉ D        list's own cards, two lines —
///   └───────────────┘ └────       a row of their own
///     For you ›                   ← the whole mosaic, pushed
///   ─── Discover's list ─────────────────────────────
/// ```
///
/// **A tap opens, a long press previews, and nothing gives under a finger.**
/// No press feedback on a face, a card or a heading (the product call of
/// 2026-09-29: it fired on the touch-down that starts every scroll of the
/// row). A tap is the collection view's own selection, which a scroll never
/// makes; a long press lifts UIKit's native context-menu preview
/// (`ForYouPostPreviewViewController`), and tapping the preview opens the post
/// the way a tap would — see `willPerformPreviewActionForMenuWith`.
///
/// **The Friends row holds its order while the screen is the viewer's.** A
/// friend whose posts were just watched loses their ring at once but keeps
/// their place; the row re-sorts (unseen first) only once the viewer has left
/// — another tab, or the app (`releaseStoryOrder`). A row that reshuffles as
/// the viewer comes back to it moves the face they just tapped out from under
/// their eyes.
///
/// **Every row rests on an item's edge, the gesture picking the edge**
/// (2026-09-29): a swipe forward lands an item flush with the right margin,
/// the one before it cropped on the left and nothing on the right; a swipe
/// back lands one flush with the left margin, the next cropped on the right
/// and nothing on the left (`ForYouRowSnap`). Hence the sizes: a gap no
/// narrower than the margin, so the side a snap empties is empty, and items
/// sized from the width (`Metrics.itemWidth`) so the other side always crops
/// one — the faces included, which are no longer a fixed size.
///
/// Hosted as the list's LEADING HEADER (`ForYouGridPage.setLead`), not as
/// sections of its own: every index path, chunk plan, hero and reveal on the
/// list is counted in its sections, and a header that scrolls with them
/// changes none of that arithmetic.
///
/// **Following is a shelf of posts** (`PostShelfSection`, #1271): its title,
/// a row of media cards and a row of text cards. The rails host it under the
/// Friends row and forward its card API, so hosts and flights read the cards
/// here as before.
///
/// A row with nothing in it is not drawn at all — no heading over nothing,
/// the inbox's rule for its sections — and with both empty the header is zero
/// tall and the list starts at the top.
///
/// Each header is a way in — the app's one section title (`SectionTitleView`)
/// as a link: the whole bar pushes its screen, and the secondary number after
/// a row's title counts what is new in the row. The third, "For you", names
/// the list under the rows and pushes Discover's whole mosaic — the screen a
/// chunk's "View all" pushes (asked for, 2026-10-01: a chevron after it like
/// the rows'); it carries no count, since nothing in the list is counted as
/// new. It is drawn only under rows, since alone at the top of the screen it
/// would title the only thing there — the chunks' "View all" still reach the
/// mosaic then.
@MainActor
final class ForYouRailsView: UIView {
    enum Metrics {
        static var sideMargin: CGFloat { PostGridListLayout.sideMargin }
        /// Between two items of a row, in both rows — and NO LESS THAN THE
        /// SIDE MARGIN, which is what lets a snap hide a side entirely: an item
        /// flush with one margin leaves its neighbour `itemGap - sideMargin`
        /// points off that edge of the screen (`ForYouRowSnap`). Any tighter
        /// and a sliver of the item the snap put away stays on screen.
        static var itemGap: CGFloat { sideMargin }
        /// Cards per screen width, counted from the left margin: two whole,
        /// and a third peeking to say the row goes on.
        static let cardsPerWidth: CGFloat = 2.3
        /// Faces per screen width, the same way: four whole and a fifth
        /// cropped by the right edge — on every width, which is why the face
        /// is sized from the width rather than fixed (at this gap, no one size
        /// leaves a crop on 375, 402 and 440 alike).
        static let storiesPerWidth: CGFloat = 4.4
        /// Height over width: portrait, tall enough that two lines of caption
        /// sit over the picture without burying it.
        static let cardAspect: CGFloat = 4.0 / 3.0
        /// Between the two rows, and between the last row and "For you": the
        /// app's ONE section gap (`Spacing.section`, 2026-09-30), from a row's
        /// foot to the next title's line — the bar's own air counted in
        /// (`SectionTitleView.gapAbove`). The sound sheet and the pushed
        /// Following / Friends lists keep the same distance.
        static var rowGap: CGFloat { SectionTitleView.gapAbove() }
        /// Below "For you", before the list's first card: what
        /// `Spacing.sectionTitle` asks beyond the bar's own air — none at the
        /// default size — so "For you" stands over the list as far as
        /// "Friends" and "Following" over their rows.
        static var listGap: CGFloat { SectionTitleView.gapBelow() }

        /// The width of one item when `perWidth` of them — gaps included —
        /// fill `width` from the left margin: `perWidth.rounded(.down)` whole
        /// items, the rest of one cropped by the screen's right edge. The
        /// mirror holds at the far end, flush right with one cropped on the
        /// left, since the gaps and margins are the same on both sides.
        ///
        /// Whole points, so every item's edges — and every offset a snap
        /// computes from them — fall on the pixel grid.
        static func itemWidth(forWidth width: CGFloat, perWidth: CGFloat) -> CGFloat {
            ForYouRowSnap.itemWidth(forWidth: width, perWidth: perWidth, margin: sideMargin, gap: itemGap)
        }

        static func cardSize(forWidth width: CGFloat) -> CGSize {
            let cardWidth = itemWidth(forWidth: width, perWidth: cardsPerWidth)
            return CGSize(width: cardWidth, height: (cardWidth * cardAspect).rounded())
        }

        /// A story cell at `width`: the disc (face and ring), and the name
        /// under it no wider than the disc.
        static func storySize(forWidth width: CGFloat) -> CGSize {
            ForYouStoryCell.Metrics.size(discSide: itemWidth(forWidth: width, perWidth: storiesPerWidth))
        }
    }

    /// The height the rows need at `width` — what the host sizes its header to.
    ///
    /// - Parameter following: every card in the Following section.
    /// - Parameter textCards: how many of them are TEXT posts — the text
    ///   row's (`ForYouFollowingRows`); the rest are the media row's.
    static func height(
        forWidth width: CGFloat, friends: Int, following: Int, textCards: Int = 0
    ) -> CGFloat {
        var height: CGFloat = 0
        if friends > 0 {
            height += SectionTitleView.Metrics.height + Metrics.storySize(forWidth: width).height
        }
        if following > 0 {
            if friends > 0 { height += Metrics.rowGap }
            height += PostShelfSection.height(forWidth: width, media: following - textCards, text: textCards)
        }
        // "For you" under whatever rows there are; nothing at all without them.
        guard height > 0 else { return 0 }
        return height + Metrics.rowGap + SectionTitleView.Metrics.height + Metrics.listGap
    }

    var preferredHeight: CGFloat { preferredHeight(forWidth: bounds.width) }

    /// The height these rows need at `width` — what the host sizes its header
    /// to.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        Self.height(
            forWidth: width, friends: stories.count, following: cards.count, textCards: shelf.rowCounts.text
        )
    }

    /// A story's avatar was tapped.
    var onStoryTapped: ((ForYouViewModel.FriendStory) -> Void)?
    /// A card was tapped: its index into `cards`.
    var onCardTapped: ((Int) -> Void)? {
        get { shelf.onCardTapped }
        set { shelf.onCardTapped = newValue }
    }
    var onFriendsHeaderTapped: (() -> Void)? {
        didSet { friendsHeader.onTap = onFriendsHeaderTapped }
    }
    var onFollowingHeaderTapped: (() -> Void)? {
        get { shelf.onTitleTapped }
        set { shelf.onTitleTapped = newValue }
    }
    /// "For you" was tapped: the host pushes Discover's whole mosaic.
    var onListHeaderTapped: (() -> Void)? {
        didSet { listHeader.onTap = onListHeaderTapped }
    }
    /// What a long press on a friend offers under the preview, after "Open"
    /// — the host's rows (View Profile, Unfollow), since this view can service
    /// none of them.
    var storyMenuElements: ((ForYouViewModel.FriendStory) -> [UIMenuElement])?
    /// The same for a card (View Profile, Unfollow, Report).
    var cardMenuElements: ((GalleryPost) -> [UIMenuElement])? {
        get { shelf.cardMenuElements }
        set { shelf.cardMenuElements = newValue }
    }
    /// A TEXT card's author band was tapped.
    var onCardAuthorTapped: ((GalleryPost) -> Void)? {
        get { shelf.onCardAuthorTapped }
        set { shelf.onCardAuthorTapped = newValue }
    }
    /// What a TEXT card's "..." offers.
    var cardAuthorMenuActions: ((_ post: GalleryPost, _ anchor: UIView) -> [PostCardMenuAction])? {
        get { shelf.cardAuthorMenuActions }
        set { shelf.cardAuthorMenuActions = newValue }
    }
    /// A TEXT card's repost was pressed (#801).
    var onCardRepostRequested: ((GalleryPost) -> Void)? {
        get { shelf.onCardRepostRequested }
        set { shelf.onCardRepostRequested = newValue }
    }

    func cardRepostHandler(for post: GalleryPost) -> (() -> Void)? { shelf.cardRepostHandler(for: post) }
    /// The rows changed which of them are drawn — the host re-sizes its header.
    var onHeightChange: (() -> Void)?
    /// Where a card's like reads the viewer's stake — For You's, shared with
    /// the list.
    var staking: PostCardStaking? {
        get { shelf.staking }
        set { shelf.staking = newValue }
    }

    func livePost(_ post: GalleryPost) -> GalleryPost { shelf.livePost(post) }
    func cardStake(for post: GalleryPost) -> Int { shelf.cardStake(for: post) }
    /// The part of the screen the viewer can see, in THIS view's space, for
    /// autoplay: a card under the navigation bar is not one they are looking
    /// at. Nil (no host yet) plays nothing.
    var visibleBand: (() -> CGRect?)?
    /// The shelf's claim on the pool changed on its OWN account — so the list
    /// under it must re-divide the budget now. See `claimedPlayers`.
    var onPlayerClaimChange: (() -> Void)?

    private(set) var stories: [ForYouViewModel.FriendStory] = []
    var cards: [GalleryPost] { shelf.cards }
    /// The friends as the view model last ordered them — what the row shows
    /// once it is free to re-sort (`releaseStoryOrder`).
    private var latestStories: [ForYouViewModel.FriendStory] = []
    /// The order the viewer has been SHOWN, held while the screen is theirs —
    /// nil until the row is first drawn in a window, and again once released.
    private var heldStoryOrder: [ProfileID]?

    private let friendsHeader = SectionTitleView(content: .init(title: "Friends", isLink: true))
    /// The posts of the people the viewer follows — a shelf (#1271).
    let shelf: PostShelfSection
    /// The list's own title, under the rows — and, like the rows', a way in:
    /// Discover's whole mosaic.
    private let listHeader = SectionTitleView(content: .init(title: "For you", isLink: true))

    /// What the card row and the list are called. For You's, by default; a
    /// hashtag's page names them "Recent" and "Top" (#629).
    var followingTitle: String {
        get { shelf.title }
        set { shelf.title = newValue }
    }
    var listTitle = "For you" {
        didSet { listHeader.content = .init(title: listTitle, isLink: true) }
    }
    private let storiesView: UICollectionView
    /// Also what a card's COPIES read the author's face from.
    let imagePipeline: ImagePipeline
    static var concurrentPlayers: Int { PostShelfSection.concurrentPlayers }
    /// How many players the rows hold as of their last reconcile — what the
    /// list under them subtracts from the pool's budget.
    var claimedPlayers: Int { shelf.claimedPlayers }

    /// The Friends row's lookahead (#970), along its horizontal axis — a
    /// screen width ahead decoded, two and a half on disk. Outside the list's
    /// display window it plans nothing (`refreshLookaheadReach`).
    ///
    /// The faces carry their story's first pictures too: a tap flies the face
    /// into its first post, and nothing else on this screen shows the
    /// friends' posts, so a flight asking the cache at the tap found it cold
    /// every time (`ForYouRowOrigins.storyPictures` rescues a late one
    /// mid-air; a picture there from the first frame is the transition as
    /// designed).
    private lazy var storyLookahead: ScrollLookahead = {
        let lookahead = ScrollLookahead(pipeline: imagePipeline, name: "foryou.friends", kind: .rail) { [weak self] path in
            self?.storyImages(at: path) ?? []
        }
        lookahead.attach(to: storiesView)
        return lookahead
    }()

    /// How many of a story's posts its face fetches ahead: a story opens on
    /// its first, and a close leaves from wherever the viewer paged to,
    /// which is rarely far.
    static let storyPicturesAhead = 2

    private func storyImages(at path: IndexPath) -> [ImageRequest] {
        guard let id = storySource.itemIdentifier(for: path),
              let story = stories.first(where: { $0.authorID == id }) else { return [] }
        let face: [ImageRequest] = story.avatarURL.map { [ImageRequest(url: $0)] } ?? []
        let pictures: [ImageRequest] = story.posts.prefix(Self.storyPicturesAhead).flatMap(\.lookaheadImages)
        return face + pictures
    }

    /// Whether the Friends row sits in the list's display window (a screen
    /// ahead of the viewport, half a screen behind): outside it, it plans
    /// nothing (#970).
    private func refreshLookaheadReach() {
        guard let window else { return }
        let reach = LookaheadWindow.display.rect(around: window.bounds, axis: .vertical, forward: true)
        storyLookahead.setInParentWindow(!isHidden && convert(bounds, to: window).intersects(reach))
    }

    private var storySource: UICollectionViewDiffableDataSource<Int, ProfileID>!

    /// The story whose disc a flight is carrying, hidden until it lands.
    private var concealedStory: ProfileID?
    private let snapper = RowSnapper()

    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController?) {
        self.imagePipeline = imagePipeline
        shelf = PostShelfSection(imagePipeline: imagePipeline, videoPlayback: videoPlayback)
        storiesView = RowGeometry.makeRow(itemSize: ForYouStoryCell.Metrics.size(discSide: 70))
        super.init(frame: .zero)
        storiesView.delegate = self
        addSubview(storiesView)
        addSubview(shelf)
        storiesView.register(ForYouStoryCell.self, forCellWithReuseIdentifier: ForYouStoryCell.reuseID)
        storySource = UICollectionViewDiffableDataSource(collectionView: storiesView) {
            [weak self] view, indexPath, id in
            let cell = view.dequeueReusableCell(
                withReuseIdentifier: ForYouStoryCell.reuseID, for: indexPath
            ) as! ForYouStoryCell
            guard let self, let story = stories.first(where: { $0.authorID == id }) else { return cell }
            cell.configure(with: story, imagePipeline: imagePipeline)
            cell.isDiscConcealed = id == concealedStory
            return cell
        }
        shelf.title = "Following"
        shelf.titleAccessibilityHint = "Shows posts from people you follow"
        // The shelf reads the band in ITS space; the host hands it in ours.
        shelf.visibleBand = { [weak self] in
            guard let self, let band = visibleBand?() else { return nil }
            return convert(band, to: shelf)
        }
        shelf.onPlayerClaimChange = { [weak self] in self?.onPlayerClaimChange?() }
        addSubview(friendsHeader)
        addSubview(listHeader)
        friendsHeader.isHidden = true
        listHeader.isHidden = true
        storiesView.isHidden = true
        shelf.isHidden = true
        friendsHeader.accessibilityHint = "Shows your friends' posts"
        listHeader.accessibilityHint = "Shows every post in Discover's mosaic"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    func render(_ rails: ForYouViewModel.Rails) {
        let oldHeight = preferredHeight
        latestStories = rails.friends
        // The friends in the order the viewer was shown, while it is held.
        let ordered = heldStoryOrder.map { Self.holding(rails.friends, in: $0) } ?? rails.friends
        let storiesChanged = ordered != stories
        stories = ordered
        friendsHeader.content = .init(title: "Friends", newCount: rails.friendsBadge, isLink: true)
        shelf.setCount(new: rails.followingBadge)
        if storiesChanged {
            applyStories(animated: window != nil)
            storyLookahead.setNeedsPlan()
        }
        if shelf.render(rails.following) {
            #if DEBUG
            // Which `-foryou-open-card` index opens which row's card.
            let text = cards.indices.filter { ForYouFollowingRows.Row(cards[$0]) == .text }
            let media = cards.indices.filter { !text.contains($0) }
            print("[qa] following rows: media=\(media) text=\(text)")
            #endif
        }
        holdStoryOrderIfShown()
        setNeedsLayout()
        if preferredHeight != oldHeight { onHeightChange?() }
    }

    /// Keyed by FRIEND, so a friend whose ring changed is the same item,
    /// reconfigured in place; animated while on screen, so a friend joining
    /// or leaving the row slides rather than the row being rebuilt.
    private func applyStories(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ProfileID>()
        snapshot.appendSections([0])
        snapshot.appendItems(stories.map(\.authorID))
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            storySource.snapshot().itemIdentifiers.contains($0)
        })
        storySource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: - The Friends row's held order

    /// `fresh`, with the friends the viewer has already been shown kept in
    /// the order they were shown.
    ///
    /// The slots those friends hold in `fresh` are refilled in `order`'s
    /// order; a friend who is new to the row keeps the slot the view model
    /// gave them, and one who left (an unfollow) simply goes. So a ring that
    /// clears moves nobody, and a follow-back still arrives where it belongs.
    static func holding(
        _ fresh: [ForYouViewModel.FriendStory], in order: [ProfileID]
    ) -> [ForYouViewModel.FriendStory] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var known = fresh
            .filter { rank[$0.authorID] != nil }
            .sorted { rank[$0.authorID, default: 0] < rank[$1.authorID, default: 0] }
            .makeIterator()
        return fresh.map { story in
            guard rank[story.authorID] != nil, let next = known.next() else { return story }
            return next
        }
    }

    /// Starts holding the order once the row has been drawn where the viewer
    /// can see it — before that, nobody has been shown anything to keep.
    private func holdStoryOrderIfShown() {
        guard window != nil, !stories.isEmpty else { return }
        heldStoryOrder = stories.map(\.authorID)
    }

    /// The viewer LEFT — another tab, or the app — so the row may take the
    /// view model's order again: friends with something unseen first. Applied
    /// at once and without animation, since nobody is watching it now.
    func releaseStoryOrder() {
        heldStoryOrder = nil
        if latestStories != stories {
            stories = latestStories
            applyStories(animated: false)
        }
        // Still in a window (the app went to the background under it): the
        // re-sorted row is what the viewer will be shown when they return,
        // so it is the order to hold from here. Out of one (a tab switch),
        // the hold resumes when the row is back on screen.
        holdStoryOrderIfShown()
    }


    override func didMoveToWindow() {
        super.didMoveToWindow()
        holdStoryOrderIfShown()
        // A stay on screen: a new owner, revoked when it leaves.
        storyLookahead.setOnScreen(window != nil)
        refreshLookaheadReach()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        // The titles span the row edge to edge: the title stands its own
        // inset from the surface (`SectionTitleView.Metrics.surfaceInset`).
        var y: CGFloat = 0
        let hasStories = !stories.isEmpty
        let hasCards = !cards.isEmpty
        friendsHeader.isHidden = !hasStories
        storiesView.isHidden = !hasStories
        shelf.isHidden = !hasCards
        if hasStories {
            friendsHeader.frame = CGRect(
                x: 0, y: y, width: width, height: SectionTitleView.Metrics.height
            )
            y += SectionTitleView.Metrics.height
            let size = Metrics.storySize(forWidth: width)
            RowGeometry.setItemSize(size, of: storiesView)
            storiesView.frame = CGRect(x: 0, y: y, width: width, height: size.height)
            y += size.height
        }
        if hasCards {
            if hasStories { y += Metrics.rowGap }
            let height = shelf.preferredHeight(forWidth: width)
            shelf.frame = CGRect(x: 0, y: y, width: width, height: height)
            shelf.layoutIfNeeded()
            y += height
        }
        listHeader.isHidden = !(hasStories || hasCards)
        if !listHeader.isHidden {
            y += Metrics.rowGap
            listHeader.frame = CGRect(
                x: 0, y: y, width: width, height: SectionTitleView.Metrics.height
            )
        }
    }

    // MARK: - Autoplay

    /// The screen is (or is no longer) the viewer's: covered by a post, a
    /// pushed screen, another tab. Nothing plays while it is not.
    func setAutoplayActive(_ active: Bool) {
        // Covered but alive: the rows drop to the minimum windows (#970).
        storyLookahead.setHidden(!active)
        shelf.setAutoplayActive(active)
    }

    /// Reconciles the shelf's players against what is on screen — see
    /// `PostShelfSection.updateAutoplay`.
    func updateAutoplay(allowingStarts: Bool = true, notifiesClaimChange: Bool = true) {
        // Called as the LIST scrolls too: the rows' reach follows it.
        refreshLookaheadReach()
        shelf.updateAutoplay(allowingStarts: allowingStarts, notifiesClaimChange: notifiesClaimChange)
    }

    func beginPlaybackHandoff(of id: PostID) { shelf.beginPlaybackHandoff(of: id) }
    func returnCardSurface(for id: PostID) -> VideoRenderView? { shelf.returnCardSurface(for: id) }
    func pauseReturnPlayback(for id: PostID) { shelf.pauseReturnPlayback(for: id) }
    func endPlaybackHandoff() { shelf.endPlaybackHandoff() }

    // MARK: - As a flight's source

    private func storyCell(for id: ProfileID) -> ForYouStoryCell? {
        guard let indexPath = storySource.indexPath(for: id) else { return nil }
        return storiesView.cellForItem(at: indexPath) as? ForYouStoryCell
    }

    /// The friend's face, in `space` — nil while it is not on screen, which a
    /// flight answers with a centred collapse rather than a trip to a rect
    /// nobody can see.
    func storyFrame(for id: ProfileID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = storyCell(for: id), RowGeometry.isInRow(cell, storiesView) else { return nil }
        return cell.discFrame(in: space, restingBelow: storiesView)
    }

    /// The face's diameter as the row draws it at its current width — the
    /// round a flight out of a face starts from. Sized from the width
    /// (`Metrics.storiesPerWidth`), so there is no constant to read.
    var storyFaceDiameter: CGFloat {
        let width = bounds.width > 0 ? bounds.width : 393
        return ForYouStoryCell.Metrics.faceDiameter(discSide: Metrics.storySize(forWidth: width).width)
    }

    /// The face's corner as the row draws it — what a flight out of a face
    /// leaves with and lands on. A face is NOT a disc
    /// (`ForYouStoryCell.Metrics.faceShape`), so this is not half the side.
    var storyFaceCornerRadius: CGFloat {
        ForYouStoryCell.Metrics.faceShape.cornerRadius(side: storyFaceDiameter)
    }

    func storyFace(for id: ProfileID) -> UIImage? {
        storyCell(for: id)?.renderedFace()
    }

    func isStoryOnScreen(_ id: ProfileID) -> Bool {
        storyCell(for: id).map { RowGeometry.isVisible($0, in: storiesView) } ?? false
    }

    func setStoryConcealed(_ concealed: Bool, for id: ProfileID) {
        if concealed { concealedStory = id } else if concealedStory == id { concealedStory = nil }
        storyCell(for: id)?.isDiscConcealed = concealed
    }

    func cardFrame(for id: PostID, in space: UICoordinateSpace) -> CGRect? { shelf.cardFrame(for: id, in: space) }

    /// See `RowGeometry.restingFrame`.
    static func restingFrame(
        of view: UIView, below ancestor: UIView, in space: UICoordinateSpace
    ) -> CGRect {
        RowGeometry.restingFrame(of: view, below: ancestor, in: space)
    }

    func cardCover(for id: PostID) -> UIImage? { shelf.cardCover(for: id) }
    func textCardCaptionEnd(for id: PostID) -> CGFloat? { shelf.textCardCaptionEnd(for: id) }
    func textCardCaptionTop(for id: PostID) -> CGFloat { shelf.textCardCaptionTop(for: id) }
    func textCardAuthorBand(for id: PostID) -> PostAuthorBandView.Model? { shelf.textCardAuthorBand(for: id) }
    func makeTextCardStandIn(for id: PostID) -> UIView? { shelf.makeTextCardStandIn(for: id) }
    func isCardOnScreen(_ id: PostID) -> Bool { shelf.isCardOnScreen(id) }
    func setCardConcealed(_ concealed: Bool, for id: PostID) { shelf.setCardConcealed(concealed, for: id) }

    /// Puts everything a flight hid back — for the moment the screen is the
    /// viewer's again, whoever finished the close.
    func clearConcealments() {
        if let concealedStory { setStoryConcealed(false, for: concealedStory) }
        shelf.clearConcealments()
    }

    func liveCardSurface(for id: PostID) -> VideoRenderView? { shelf.liveCardSurface(for: id) }
    func adoptLandingPlayback(_ view: UIView, for id: PostID) { shelf.adoptLandingPlayback(view, for: id) }
    func isLandingPlaybackReady(for id: PostID) -> Bool { shelf.isLandingPlaybackReady(for: id) }

    /// Scrolls the row so a face is wholly in view — before a close measures
    /// where it lands, since the rows can be scrolled under an open post.
    func bringStoryIntoView(_ id: ProfileID) {
        guard let indexPath = storySource.indexPath(for: id) else { return }
        RowGeometry.bringIntoView(indexPath, in: storiesView)
    }

    func bringCardIntoView(_ id: PostID) { shelf.bringCardIntoView(id) }

    // MARK: - Long press

    typealias MenuTarget = RowMenuTarget

    /// Opens what a menu was about, the way a tap on it would — nothing if it
    /// left the row while the menu was up.
    private func open(_ target: MenuTarget) {
        switch target {
        case .story(let id):
            guard let story = stories.first(where: { $0.authorID == id }) else { return }
            onStoryTapped?(story)
        case .card(let id):
            shelf.open(id)
        }
    }

    private func storyMenu(for story: ForYouViewModel.FriendStory) -> UIMenu {
        let id = story.authorID
        var children: [UIMenuElement] = []
        if !story.posts.isEmpty {
            children.append(RowGeometry.openAction { [weak self] in self?.open(.story(id)) })
        }
        children += storyMenuElements?(story) ?? []
        return UIMenu(children: children)
    }

    /// The FACE the lift is made of (round, without its name).
    private func targetedPreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let story = storiesView.cellForItem(at: indexPath) as? ForYouStoryCell,
              story.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let face = story.faceView
        parameters.visiblePath = ForYouStoryCell.Metrics.faceShape.path(in: face.bounds)
        return UITargetedPreview(view: face, parameters: parameters)
    }

    #if DEBUG
    /// The menu a long press on story `index` would show — its rows' titles.
    func debugStoryMenuTitles(at index: Int) -> [String] {
        guard stories.indices.contains(index) else { return [] }
        return storyMenu(for: stories[index]).children.map(\.title)
    }

    /// The same for card `index`.
    func debugCardMenuTitles(at index: Int) -> [String] {
        guard cards.indices.contains(index) else { return [] }
        return shelf.cardMenu(for: cards[index]).children.map(\.title)
    }

    func debugCardMenuConfiguration(at index: Int, point: CGPoint = .zero) -> UIContextMenuConfiguration? {
        shelf.debugCardMenuConfiguration(at: index, point: point)
    }

    func debugCardPlace(at index: Int) -> (row: UICollectionView, indexPath: IndexPath)? {
        shelf.debugCardPlace(at: index)
    }

    /// `media 2` / `text 0` — the row and item card `index` is, for a log.
    func debugCardPlaceName(at index: Int) -> String? {
        debugCardPlace(at: index).map { "\($0.row === shelf.textView ? "text" : "media") \($0.indexPath.item)" }
    }

    /// Card `index`'s frame in its row's content space, from its layout.
    func debugCardLayoutFrame(at index: Int) -> CGRect? {
        debugCardPlace(at: index).flatMap { $0.row.layoutAttributesForItem(at: $0.indexPath)?.frame }
    }

    /// MEDIA card `index`'s cell, when the row has realized it.
    func debugCardCell(at index: Int) -> ForYouFollowingCardCell? {
        guard cards.indices.contains(index) else { return nil }
        return shelf.mediaCardCell(for: cards[index].id)
    }

    /// TEXT card `index`'s cell — the list's own card — when realized.
    func debugTextCardCell(at index: Int) -> PostGridListRowCell? {
        guard cards.indices.contains(index) else { return nil }
        return shelf.textCardCell(for: cards[index].id)
    }

    /// The shelf's two rows — for a test scrolling one or converting a point
    /// into it.
    var debugMediaRow: UICollectionView { shelf.mediaView }
    var debugTextRow: UICollectionView { shelf.textView }

    /// Opens what a committed preview would — the commit's own path, minus
    /// UIKit's animator.
    func debugCommitPreview(_ configuration: UIContextMenuConfiguration) {
        guard let target = MenuTarget(configuration.identifier) else { return }
        open(target)
    }

    /// The friends' order as drawn.
    var debugStoryOrder: [ProfileID] { stories.map(\.authorID) }
    var debugShowsListHeader: Bool { !listHeader.isHidden }
    /// Friends, Following and "For you" — the app's one section title each.
    var debugHeaders: [SectionTitleView] { [friendsHeader, shelf.header, listHeader] }

    /// Taps story `index` through the row's own selection path.
    func debugTapStory(at index: Int) -> Bool {
        guard stories.indices.contains(index) else { return false }
        collectionView(storiesView, didSelectItemAt: IndexPath(item: index, section: 0))
        return true
    }

    /// Taps card `index` through the row's own selection path.
    func debugTapCard(at index: Int) -> Bool { shelf.debugTapCard(at: index) }

    /// Whether card `index` has a face to fly — what a scripted open waits on.
    func debugCardIsReady(at index: Int) -> Bool {
        guard cards.indices.contains(index) else { return false }
        let post = cards[index]
        guard post.kind != .text else { return true }
        return shelf.mediaCardCell(for: post.id)?.renderedCover != nil
    }

    /// The headers' OWN tap path (`SectionTitleView.debugTap`), not the
    /// host's closure: calling the closure is how #312's dead chevron passed.
    func debugTapFriendsHeader() { friendsHeader.debugTap() }
    func debugTapFollowingHeader() { shelf.debugTapTitle() }
    func debugTapListHeader() { listHeader.debugTap() }
    var debugFriendsBadge: String? { friendsHeader.debugCountText }
    var debugFollowingBadge: String? { shelf.debugCountText }
    #endif
}

/// The Friends row's delegate; a shelf row handed here (a test driving the
/// rails) goes to the shelf, which is its own rows' delegate.
extension ForYouRailsView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard collectionView === storiesView else {
            shelf.collectionView(collectionView, didSelectItemAt: indexPath)
            return
        }
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = storySource.itemIdentifier(for: indexPath),
              let story = stories.first(where: { $0.authorID == id }) else { return }
        onStoryTapped?(story)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === storiesView else {
            if shelf.owns(scrollView) { shelf.scrollViewDidScroll(scrollView) }
            return
        }
        snapper.didScroll(scrollView)
        storyLookahead.scrollViewDidScroll()
    }

    /// A row came to rest: its fling is over, and its display window decodes.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === storiesView else {
            if shelf.owns(scrollView) { shelf.scrollViewDidEndDecelerating(scrollView) }
            return
        }
        storyLookahead.scrollViewDidEndScrolling()
    }

    // MARK: - Snapping

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === storiesView else {
            if shelf.owns(scrollView) { shelf.scrollViewWillBeginDragging(scrollView) }
            return
        }
        snapper.willBeginDragging(scrollView)
    }

    /// The row comes to rest on an item's edge, the side picked by the
    /// gesture's direction — see `RowSnapper`.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === storiesView else {
            if shelf.owns(scrollView) {
                shelf.scrollViewWillEndDragging(
                    scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset
                )
            }
            return
        }
        snapper.willEndDragging(
            storiesView, velocity: velocity, targetContentOffset: targetContentOffset, stepped: false
        )
    }

    /// Where `row` rests after a release — see `RowSnapper.snapTarget`.
    func snapTarget(
        in row: UICollectionView, projected: CGFloat, start: CGFloat, direction: ForYouRowSnap.Direction?
    ) -> CGFloat {
        guard row === storiesView else {
            return shelf.snapTarget(in: row, projected: projected, start: start, direction: direction)
        }
        return RowSnapper.snapTarget(
            in: row, projected: projected, start: start, direction: direction, stepped: false
        )
    }

    // MARK: - Long press: the native preview

    /// A long press on a face lifts the post it opens first, with the menu
    /// under it. A friend with nothing loaded lifts their face alone.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard collectionView === storiesView else {
            return shelf.collectionView(collectionView, contextMenuConfigurationForItemsAt: indexPaths, point: point)
        }
        guard let indexPath = indexPaths.first,
              let id = storySource.itemIdentifier(for: indexPath),
              let story = stories.first(where: { $0.authorID == id }) else { return nil }
        let width = max(0, bounds.width - Metrics.sideMargin * 2)
        let pipeline = imagePipeline
        return UIContextMenuConfiguration(
            identifier: MenuTarget.story(id).identifier,
            previewProvider: story.posts.first.map { post in
                { ForYouPostPreviewViewController(post: post, imagePipeline: pipeline, width: width) }
            },
            actionProvider: { [weak self] _ in self?.storyMenu(for: story) }
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        targetedPreview(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        targetedPreview(at: indexPath)
    }

    /// Tapping the lifted preview opens the friend's post — the same open as
    /// a tap on the face, through the same flight (`.dismiss`, then our hero:
    /// see `PostShelfSection`'s commit).
    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let target = MenuTarget(configuration.identifier) else { return }
        animator.preferredCommitStyle = .dismiss
        animator.addCompletion { [weak self] in
            DispatchQueue.main.async { self?.open(target) }
        }
    }
}
