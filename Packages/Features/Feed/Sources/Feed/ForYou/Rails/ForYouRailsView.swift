import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The two rows that lead For You's list (2026-09-29):
///
/// ```
///     Friends 3 ›
///   ◉ ◉ ◉ ○ ○ ○ ○          stories: unseen first, with a ring
///     Following 5 ›
///   ┌──────┐ ┌──────┐ ┌───       cards, the third peeking;
///   │ ▶    │ │ ▶    │ │ ▶         every card on screen plays,
///   │ Ana  │ │ Bo   │ │           and each wears its first two
///   │ two… │ │ two… │ │           lines over its foot
///   └──────┘ └──────┘ └───
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
/// **Both rows rest on an item's edge, the gesture picking the edge**
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
/// **Experimentally, the Following row is two lanes** — media cards over
/// text cards twice as wide, one scroller (`ForYouFollowingLanes`,
/// `-foryou-following-two-lanes`); every card is still found by its post, so
/// the flights, the previews and the playback read it the same way.
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
            let whole = perWidth.rounded(.down)
            return max(0, ((width - sideMargin - whole * itemGap) / perWidth).rounded(.down))
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
    /// - Parameter lanes: the Following row's media and text counts when it is
    ///   drawn as two lanes (`ForYouFollowingLanes`); nil, the single lane.
    static func height(
        forWidth width: CGFloat, friends: Int, following: Int,
        lanes: (media: Int, text: Int)? = nil
    ) -> CGFloat {
        var height: CGFloat = 0
        if friends > 0 {
            height += SectionTitleView.Metrics.height + Metrics.storySize(forWidth: width).height
        }
        if following > 0 {
            if friends > 0 { height += Metrics.rowGap }
            height += SectionTitleView.Metrics.height + followingRowHeight(forWidth: width, lanes: lanes)
        }
        // "For you" under whatever rows there are; nothing at all without them.
        guard height > 0 else { return 0 }
        return height + Metrics.rowGap + SectionTitleView.Metrics.height + Metrics.listGap
    }

    /// The Following row's own height: one card's, or the two lanes'.
    private static func followingRowHeight(forWidth width: CGFloat, lanes: (media: Int, text: Int)?) -> CGFloat {
        guard let lanes else { return Metrics.cardSize(forWidth: width).height }
        return ForYouFollowingLanes.geometry(
            forWidth: width, mediaCount: lanes.media, textCount: lanes.text
        ).height
    }

    var preferredHeight: CGFloat { preferredHeight(forWidth: bounds.width) }

    /// The height these rows need at `width` — what the host sizes its header
    /// to.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        Self.height(forWidth: width, friends: stories.count, following: cards.count, lanes: laneCounts)
    }

    /// Whether the Following row is drawn as two lanes, media over text
    /// (`ForYouFollowingLanes`, `-foryou-following-two-lanes`). Fixed at
    /// creation: it picks the row's layout.
    let usesFollowingLanes: Bool

    /// The row's two lanes' layout, when it has them.
    private var lanesLayout: ForYouFollowingLanesLayout? {
        cardsView.collectionViewLayout as? ForYouFollowingLanesLayout
    }

    /// Each lane's count, when the row has lanes.
    private var laneCounts: (media: Int, text: Int)? {
        guard usesFollowingLanes else { return nil }
        let text = cards.filter { ForYouFollowingLanes.Lane($0) == .text }.count
        return (cards.count - text, text)
    }

    /// A story's avatar was tapped.
    var onStoryTapped: ((ForYouViewModel.FriendStory) -> Void)?
    /// A card was tapped: its index into `cards`.
    var onCardTapped: ((Int) -> Void)?
    var onFriendsHeaderTapped: (() -> Void)? {
        didSet { friendsHeader.onTap = onFriendsHeaderTapped }
    }
    var onFollowingHeaderTapped: (() -> Void)? {
        didSet { followingHeader.onTap = onFollowingHeaderTapped }
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
    var cardMenuElements: ((GalleryPost) -> [UIMenuElement])?
    /// The rows changed which of them are drawn — the host re-sizes its header.
    var onHeightChange: (() -> Void)?
    /// Where a card's like reads the viewer's stake — For You's, shared with
    /// the list. The cards' hearts are readouts: nothing here spends.
    var staking: PostCardStaking?

    /// What the viewer has staked on `post` — what a COPY of its card (a
    /// flight's furniture, a close's stand-in) draws its heart from.
    func cardStake(for post: GalleryPost) -> Int {
        staking?.viewerStake(on: post.id) ?? 0
    }
    /// The part of the screen the viewer can see, in THIS view's space, for
    /// autoplay: a card under the navigation bar is not one they are looking
    /// at. Nil (no host yet) plays nothing.
    var visibleBand: (() -> CGRect?)?
    /// The row's claim on the pool changed on its OWN account — it scrolled, a
    /// cover landed — so the list under it must re-divide the budget now, not
    /// at its next scroll tick. See `claimedPlayers`.
    var onPlayerClaimChange: (() -> Void)?

    private(set) var stories: [ForYouViewModel.FriendStory] = []
    private(set) var cards: [GalleryPost] = []
    /// The friends as the view model last ordered them — what the row shows
    /// once it is free to re-sort (`releaseStoryOrder`).
    private var latestStories: [ForYouViewModel.FriendStory] = []
    /// The order the viewer has been SHOWN, held while the screen is theirs —
    /// nil until the row is first drawn in a window, and again once released.
    private var heldStoryOrder: [ProfileID]?

    private let friendsHeader = SectionTitleView(content: .init(title: "Friends", isLink: true))
    private let followingHeader = SectionTitleView(content: .init(title: "Following", isLink: true))
    /// The list's own title, under the rows — and, like the rows', a way in:
    /// Discover's whole mosaic.
    private let listHeader = SectionTitleView(content: .init(title: "For you", isLink: true))
    private let storiesView: UICollectionView
    private let cardsView: UICollectionView
    /// Also what a card's COPIES read the author's face from — the flight's
    /// resting overlay, a window's stand-in — so they draw the picture the
    /// card in the row already has (`ForYouCardCaptionOverlay`).
    let imagePipeline: ImagePipeline
    /// The Following row's own playback: EVERY card on screen plays, muted —
    /// "all the visible video cards", the product call of 2026-09-29 (it used
    /// to be the lead card alone). A card must be half on screen to count
    /// (`GridPlaybackVisibility`), and at 2.3 cards per width no more than
    /// three can be — which is the row's budget.
    ///
    /// The pool is shared with the list below (six decoders,
    /// `VideoPlaybackController.capacity`): the list plays what the row's
    /// claim leaves it (`ForYouGridPage.playerReserve`, fed `claimedPlayers`).
    private let playback: GridVideoPlaybackCoordinator?
    static let concurrentPlayers = 3
    /// How many players the row holds as of its last reconcile — what the
    /// list under it subtracts from the pool's budget.
    private(set) var claimedPlayers = 0

    private var storySource: UICollectionViewDiffableDataSource<Int, ProfileID>!
    private var cardSource: UICollectionViewDiffableDataSource<Int, PostID>!

    /// The story whose disc a flight is carrying, hidden until it lands.
    private var concealedStory: ProfileID?
    /// The card a flight is carrying.
    private var concealedCard: PostID?

    /// The row under the finger and which way it last moved — what a release
    /// with no speed left snaps by (`ForYouRowSnap`). Nil between drags.
    private var drag: (row: UIScrollView, tracker: ForYouRowDragTracker)?

    /// - Parameter followingLanes: draws the Following row as two lanes, media
    ///   over text (`ForYouFollowingLanes`).
    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController?, followingLanes: Bool = false) {
        self.imagePipeline = imagePipeline
        usesFollowingLanes = followingLanes
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: Self.concurrentPlayers)
        }
        // Placeholder sizes: both rows' items are sized from the width, which
        // `layoutSubviews` knows and this does not.
        storiesView = UICollectionView(frame: .zero, collectionViewLayout: Self.rowLayout(
            itemSize: ForYouStoryCell.Metrics.size(discSide: 70)
        ))
        cardsView = UICollectionView(
            frame: .zero,
            collectionViewLayout: followingLanes
                ? ForYouFollowingLanesLayout()
                : Self.rowLayout(itemSize: CGSize(width: 150, height: 200))
        )
        super.init(frame: .zero)
        for row in [storiesView, cardsView] {
            row.backgroundColor = .clear
            row.showsHorizontalScrollIndicator = false
            row.alwaysBounceHorizontal = true
            row.alwaysBounceVertical = false
            // A row comes to rest on an item's edge (`scrollViewWillEndDragging`);
            // the quicker deceleration makes that one decided motion rather
            // than a long glide bent to its stop at the end.
            row.decelerationRate = .fast
            // The row sits inside the list's own scroll view, which already
            // accounts for the bars; its horizontal scroll has none to add.
            row.contentInsetAdjustmentBehavior = .never
            // No system band under the header: a row is a scroll view too, and
            // it would draw one — see `prefersClearTopEdge`.
            row.prefersClearTopEdge()
            row.delegate = self
            addSubview(row)
        }
        storiesView.register(ForYouStoryCell.self, forCellWithReuseIdentifier: ForYouStoryCell.reuseID)
        cardsView.register(ForYouFollowingCardCell.self, forCellWithReuseIdentifier: ForYouFollowingCardCell.reuseID)
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
        cardSource = UICollectionViewDiffableDataSource(collectionView: cardsView) {
            [weak self] view, indexPath, id in
            let cell = view.dequeueReusableCell(
                withReuseIdentifier: ForYouFollowingCardCell.reuseID, for: indexPath
            ) as! ForYouFollowingCardCell
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
        addSubview(friendsHeader)
        addSubview(followingHeader)
        addSubview(listHeader)
        friendsHeader.isHidden = true
        followingHeader.isHidden = true
        listHeader.isHidden = true
        storiesView.isHidden = true
        cardsView.isHidden = true
        friendsHeader.accessibilityHint = "Shows your friends' posts"
        followingHeader.accessibilityHint = "Shows posts from people you follow"
        listHeader.accessibilityHint = "Shows every post in Discover's mosaic"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func rowLayout(itemSize: CGSize) -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = itemSize
        layout.minimumLineSpacing = Metrics.itemGap
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 0, left: Metrics.sideMargin, bottom: 0, right: Metrics.sideMargin)
        return layout
    }

    // MARK: - Content

    func render(_ rails: ForYouViewModel.Rails) {
        let oldHeight = preferredHeight
        latestStories = rails.friends
        // The friends in the order the viewer was shown, while it is held.
        let ordered = heldStoryOrder.map { Self.holding(rails.friends, in: $0) } ?? rails.friends
        let storiesChanged = ordered != stories
        let cardsChanged = rails.following != cards
        stories = ordered
        cards = rails.following
        friendsHeader.content = .init(title: "Friends", newCount: rails.friendsBadge, isLink: true)
        followingHeader.content = .init(title: "Following", newCount: rails.followingBadge, isLink: true)
        if storiesChanged { applyStories(animated: window != nil) }
        if cardsChanged {
            applyCards()
            #if DEBUG
            if usesFollowingLanes {
                // Which `-foryou-open-card` index opens which lane's card.
                let text = cards.indices.filter { ForYouFollowingLanes.Lane(cards[$0]) == .text }
                let media = cards.indices.filter { !text.contains($0) }
                print("[qa] following lanes: media=\(media) text=\(text)")
            }
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
    }

    private func applyCards() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, PostID>()
        if usesFollowingLanes {
            // A section per lane, each in the row's order (`ForYouFollowingLanes`).
            let lanes = ForYouFollowingLanes.partition(cards)
            snapshot.appendSections(ForYouFollowingLanes.Lane.allCases.map(\.rawValue))
            snapshot.appendItems(lanes.media.map(\.id), toSection: ForYouFollowingLanes.Lane.media.rawValue)
            snapshot.appendItems(lanes.text.map(\.id), toSection: ForYouFollowingLanes.Lane.text.rawValue)
        } else {
            snapshot.appendSections([0])
            snapshot.appendItems(cards.map(\.id))
        }
        cardSource.apply(snapshot, animatingDifferences: window != nil) { [weak self] in
            self?.updateAutoplay()
        }
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
        followingHeader.isHidden = !hasCards
        cardsView.isHidden = !hasCards
        if hasStories {
            friendsHeader.frame = CGRect(
                x: 0, y: y, width: width, height: SectionTitleView.Metrics.height
            )
            y += SectionTitleView.Metrics.height
            let size = Metrics.storySize(forWidth: width)
            if let layout = storiesView.collectionViewLayout as? UICollectionViewFlowLayout,
               layout.itemSize != size {
                layout.itemSize = size
            }
            storiesView.frame = CGRect(x: 0, y: y, width: width, height: size.height)
            y += size.height
        }
        if hasCards {
            if hasStories { y += Metrics.rowGap }
            followingHeader.frame = CGRect(
                x: 0, y: y, width: width, height: SectionTitleView.Metrics.height
            )
            y += SectionTitleView.Metrics.height
            let size = Metrics.cardSize(forWidth: width)
            if let layout = cardsView.collectionViewLayout as? UICollectionViewFlowLayout,
               layout.itemSize != size {
                layout.itemSize = size
            }
            // Two lanes are as tall as both and the gap between them; their
            // layout sizes its cards from the row's width itself.
            let height = Self.followingRowHeight(forWidth: width, lanes: laneCounts)
            cardsView.frame = CGRect(x: 0, y: y, width: width, height: height)
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

    private var isAutoplayActive = false

    /// The screen is (or is no longer) the viewer's: covered by a post, a
    /// pushed screen, another tab. Nothing plays while it is not.
    func setAutoplayActive(_ active: Bool) {
        isAutoplayActive = active
        playback?.setSurfaceVisible(active)
        if active { updateAutoplay() }
    }

    /// Reconciles the row's players against what is on screen. Cheap and
    /// idempotent; the host calls it as the LIST scrolls (the row moving in or
    /// out of the band) and the row calls it as ITSELF scrolls.
    ///
    /// - Parameter notifiesClaimChange: false from the list's own reconcile,
    ///   which reads `claimedPlayers` straight after — telling it to reconcile
    ///   again from inside that reconcile would re-enter it.
    func updateAutoplay(allowingStarts: Bool = true, notifiesClaimChange: Bool = true) {
        let before = claimedPlayers
        claimedPlayers = reconcilePlayback(allowingStarts: allowingStarts)
        if notifiesClaimChange, claimedPlayers != before { onPlayerClaimChange?() }
    }

    /// The reconcile proper; answers how many players the row now holds.
    private func reconcilePlayback(allowingStarts: Bool) -> Int {
        guard let playback else { return 0 }
        guard isAutoplayActive, !cardsView.isHidden, let band = visibleBand?() else {
            playback.update(candidates: [], allowingStarts: allowingStarts)
            return 0
        }
        // The band, in the row's CONTENT space: the scroll view's bounds are
        // its content offset, so a card's frame compares directly.
        let viewport = cardsView.convert(band, from: self).intersection(cardsView.bounds)
        let candidates = cardsView.indexPathsForVisibleItems.compactMap {
            indexPath -> GridVideoPlaybackCoordinator.Candidate? in
            guard let id = cardSource.itemIdentifier(for: indexPath),
                  id != concealedCard,
                  let post = cards.first(where: { $0.id == id }),
                  post.hasPlayableVideo, let url = post.videoURL,
                  let cell = cardsView.cellForItem(at: indexPath) as? ForYouFollowingCardCell,
                  hasCover(post, in: cell)
            else { return nil }
            let frame = cell.frame
            guard !viewport.isNull, GridPlaybackVisibility.autoplays(frame, in: viewport) else { return nil }
            // Every card half on screen plays; the ranking only matters when
            // the budget is short, and then the row is read from its leading
            // edge, so the card nearest it keeps its player.
            return .init(id: id, url: url, cell: cell, distanceFromCentre: abs(frame.minX - viewport.minX))
        }
        playback.update(candidates: candidates, allowingStarts: allowingStarts)
        return min(candidates.count, Self.concurrentPlayers)
    }

    /// A card may play only once it has a face behind its surface — the
    /// list's own gate (`ForYouGridPage.hasCover`), for the same black-tile
    /// reason.
    private func hasCover(_ post: GalleryPost, in cell: ForYouFollowingCardCell) -> Bool {
        guard let thumbnail = post.thumbnailURL else { return true }
        if cell.renderedCover != nil { return true }
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        cell.applyCover(cached)
        return true
    }

    /// Opens the handoff for a card a flight is about to carry: the row's
    /// reconcile must neither restart nor stop its player while it is in the
    /// air.
    func beginPlaybackHandoff(of id: PostID) {
        landingCard = nil
        playback?.focus(id)
        updateAutoplay()
        playback?.beginHandoff(id)
    }

    func endPlaybackHandoff() {
        landingCard = nil
        playback?.endHandoff()
        playback?.focus(nil)
        updateAutoplay()
    }

    // MARK: - As a flight's source

    private func storyCell(for id: ProfileID) -> ForYouStoryCell? {
        guard let indexPath = storySource.indexPath(for: id) else { return nil }
        return storiesView.cellForItem(at: indexPath) as? ForYouStoryCell
    }

    private func cardCell(for id: PostID) -> ForYouFollowingCardCell? {
        guard let indexPath = cardSource.indexPath(for: id) else { return nil }
        return cardsView.cellForItem(at: indexPath) as? ForYouFollowingCardCell
    }

    /// The friend's face, in `space` — nil while it is not on screen, which a
    /// flight answers with a centred collapse rather than a trip to a rect
    /// nobody can see.
    func storyFrame(for id: ProfileID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = storyCell(for: id), isInRow(cell, storiesView) else { return nil }
        return cell.discFrame(in: space, restingBelow: storiesView)
    }

    /// The face's diameter as the row draws it at its current width — the
    /// round a flight out of a face starts from. Sized from the width
    /// (`Metrics.storiesPerWidth`), so there is no constant to read.
    var storyFaceDiameter: CGFloat {
        let width = bounds.width > 0 ? bounds.width : 393
        return ForYouStoryCell.Metrics.faceDiameter(discSide: Metrics.storySize(forWidth: width).width)
    }

    func storyFace(for id: ProfileID) -> UIImage? {
        storyCell(for: id)?.renderedFace()
    }

    func isStoryOnScreen(_ id: ProfileID) -> Bool {
        storyCell(for: id).map { isVisible($0, in: storiesView) } ?? false
    }

    func setStoryConcealed(_ concealed: Bool, for id: ProfileID) {
        if concealed { concealedStory = id } else if concealedStory == id { concealedStory = nil }
        storyCell(for: id)?.isDiscConcealed = concealed
    }

    /// The card's rect in `space`, at rest — see `restingFrame`.
    func cardFrame(for id: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = cardCell(for: id), isInRow(cell, cardsView) else { return nil }
        return Self.restingFrame(of: cell, below: cardsView, in: space)
    }

    /// `view`'s bounds in `space` as they are AT REST: every transform from
    /// `view` up to (not including) `ancestor` left out, `ancestor` and
    /// everything above it converted by UIKit as usual.
    ///
    /// ⚠️ WHERE A FLIGHT LANDS IS WHERE ITS SOURCE RESTS, not where it is
    /// drawn this instant. An item that scales under a press — the disc of a
    /// story, a card's content — reports its SCALED rect through
    /// `convert(_:to:)`, so a close measured while (or because) the press was
    /// still easing out flew to a rect a few points inside the item and off
    /// its centre. Filmed on both rows as "the window doesn't come back to
    /// the right coordinates". The rows' own scroll offsets are NOT
    /// transforms — they are the bounds origins subtracted below — so the row
    /// having scrolled is still honoured; only a transform is ignored.
    ///
    /// Assumes the default anchor point, which is `center`'s meaning.
    static func restingFrame(
        of view: UIView, below ancestor: UIView, in space: UICoordinateSpace
    ) -> CGRect {
        var rect = view.bounds
        var current = view
        while current !== ancestor, let parent = current.superview {
            // From `current`'s bounds space into `parent`'s, as the frame an
            // identity transform would give it: centred on `center`.
            let size = current.bounds.size
            rect = rect.offsetBy(
                dx: current.center.x - size.width / 2 - current.bounds.minX,
                dy: current.center.y - size.height / 2 - current.bounds.minY
            )
            current = parent
        }
        return current.convert(rect, to: space)
    }

    func cardCover(for id: PostID) -> UIImage? {
        cardCell(for: id)?.renderedCover
    }

    func isCardOnScreen(_ id: PostID) -> Bool {
        cardCell(for: id).map { isVisible($0, in: cardsView) } ?? false
    }

    func setCardConcealed(_ concealed: Bool, for id: PostID) {
        if concealed { concealedCard = id } else if concealedCard == id { concealedCard = nil }
        cardCell(for: id)?.isHidden = concealed
    }

    /// Puts everything a flight hid back — for the moment the screen is the
    /// viewer's again, whoever finished the close.
    func clearConcealments() {
        if let concealedStory { setStoryConcealed(false, for: concealedStory) }
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
        if let cell = cardCell(for: id) {
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
    /// reconciled: a beat of thumbnail between the flight's video and the
    /// card's. Here the card's surface is primed with the page's current
    /// frame and takes the pool loan before the flight card goes, and
    /// `isLandingPlaybackReady` holds the flight card over it until it draws.
    ///
    /// Unconcealed FIRST: a surface outside a visible hierarchy is skipped by
    /// the renderer and would never report drawing. The flight card is still
    /// on top, at the same rect, so revealing the card under it shows nothing.
    func adoptLandingPlayback(_ view: UIView, for id: PostID) {
        guard let playback, let post = cards.first(where: { $0.id == id }),
              let url = post.videoURL, let cell = cardCell(for: id)
        else { return }
        setCardConcealed(false, for: id)
        if VideoRenderFlags.usesSampleBufferLayer {
            // One playback, several surfaces: the card gets its own, primed on
            // attach, and the flight card's is released once it leaves the
            // window. Nothing is re-parented.
            if playback.adoptAttachedSurface(for: id, url: url, cell: cell) { landingCard = id }
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
    /// video (a photo page, a donation that did not happen) left nothing
    /// playing here until the row reconciles on appearing, so asking the pool
    /// would hold every such landing for the hold's whole ceiling.
    func isLandingPlaybackReady(for id: PostID) -> Bool {
        guard let post = cards.first(where: { $0.id == id }) else { return true }
        let cell = cardCell(for: id)
        if let playback, landingCard == id {
            return playback.isSurfaceRendering(for: id)
        }
        guard let cell, post.thumbnailURL != nil else { return true }
        return cell.renderedCover != nil
    }

    /// Scrolls the row so an item is wholly in view — before a close measures
    /// where it lands, since the rows can be scrolled under an open post.
    func bringStoryIntoView(_ id: ProfileID) {
        guard let indexPath = storySource.indexPath(for: id) else { return }
        bringIntoView(indexPath, in: storiesView)
    }

    func bringCardIntoView(_ id: PostID) {
        guard let indexPath = cardSource.indexPath(for: id) else { return }
        bringIntoView(indexPath, in: cardsView)
    }

    private func bringIntoView(_ indexPath: IndexPath, in row: UICollectionView) {
        row.layoutIfNeeded()
        guard let frame = row.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let visible = row.bounds.insetBy(dx: Metrics.sideMargin, dy: 0)
        // Horizontally: a lane's card is in view whatever its height.
        guard !(visible.minX <= frame.minX && frame.maxX <= visible.maxX) else { return }
        if row === cardsView, let lanesLayout {
            // Two lanes come to rest on a SPREAD (`ForYouFollowingLanes`), so
            // the card returns on the one that holds it — the grid a swipe
            // would have left it on, not a column flush with a margin.
            let offset = Self.lanesOffset(
                bringing: frame, into: row.bounds,
                extents: lanesLayout.geometry.snapExtents, offsets: Self.offsetRange(of: row)
            )
            row.setContentOffset(CGPoint(x: offset, y: row.contentOffset.y), animated: false)
        } else {
            row.scrollRectToVisible(frame.insetBy(dx: -Metrics.sideMargin, dy: 0), animated: false)
        }
        row.layoutIfNeeded()
    }

    /// The offset that brings `frame` wholly into a two-lane row seen through
    /// `bounds`: the spread holding it flush with the margin on the side it
    /// was cut by — its leading edge on the left margin when it lay to the
    /// left, its trailing edge on the right one when it lay to the right.
    static func lanesOffset(
        bringing frame: CGRect, into bounds: CGRect,
        extents: [ClosedRange<CGFloat>], offsets: ClosedRange<CGFloat>
    ) -> CGFloat {
        let margin = Metrics.sideMargin
        let extent = extents.first { $0.lowerBound <= frame.minX + 0.5 && frame.maxX - 0.5 <= $0.upperBound }
            ?? frame.minX...frame.maxX
        let offset = frame.minX < bounds.minX + margin
            ? extent.lowerBound - margin
            : extent.upperBound + margin - bounds.width
        return min(max(offset, offsets.lowerBound), offsets.upperBound)
    }

    /// On screen: in a window, and within its row's visible bounds.
    private func isVisible(_ cell: UICollectionViewCell, in row: UICollectionView) -> Bool {
        cell.window != nil && isInRow(cell, row)
    }

    /// Within its row's visible bounds — what a RECT is asked, window or not.
    ///
    /// ⚠️ NOT `isVisible`. A card-shaped close (`RowCardCloseLanding`) asks
    /// whether the row exists BEFORE the pop has put this screen back in the
    /// window — the swipe stages at its begin — and a window check there
    /// answered "no row", so the close fell to a plain slide
    /// (`geometry=false`, measured). The rect is re-asked in the transition's
    /// own space once the screen is back, as every list's is.
    private func isInRow(_ cell: UICollectionViewCell, _ row: UICollectionView) -> Bool {
        !row.isHidden && row.bounds.intersects(cell.frame)
    }

    // MARK: - Long press

    /// What a context menu is about — carried in its configuration's
    /// identifier, since the menu outlives the index path it was asked for.
    enum MenuTarget: Equatable {
        case story(ProfileID)
        case card(PostID)

        var identifier: NSString {
            switch self {
            case .story(let id): "story:\(id.rawValue)" as NSString
            case .card(let id): "card:\(id.rawValue)" as NSString
            }
        }

        init?(_ identifier: NSCopying) {
            guard let raw = identifier as? NSString as String? else { return nil }
            if raw.hasPrefix("story:") {
                self = .story(ProfileID(String(raw.dropFirst("story:".count))))
            } else if raw.hasPrefix("card:") {
                self = .card(PostID(String(raw.dropFirst("card:".count))))
            } else {
                return nil
            }
        }
    }

    /// Opens what a menu was about, the way a tap on it would — nothing if it
    /// left the row while the menu was up.
    private func open(_ target: MenuTarget) {
        switch target {
        case .story(let id):
            guard let story = stories.first(where: { $0.authorID == id }) else { return }
            onStoryTapped?(story)
        case .card(let id):
            guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
            onCardTapped?(index)
        }
    }

    private static func openAction(_ handler: @escaping () -> Void) -> UIAction {
        UIAction(title: "Open", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in
            handler()
        }
    }

    private func storyMenu(for story: ForYouViewModel.FriendStory) -> UIMenu {
        let id = story.authorID
        var children: [UIMenuElement] = []
        if !story.posts.isEmpty {
            children.append(Self.openAction { [weak self] in self?.open(.story(id)) })
        }
        children += storyMenuElements?(story) ?? []
        return UIMenu(children: children)
    }

    private func cardMenu(for post: GalleryPost) -> UIMenu {
        let id = post.id
        let open = Self.openAction { [weak self] in self?.open(.card(id)) }
        return UIMenu(children: [open] + (cardMenuElements?(post) ?? []))
    }

    /// The view the lift is made of, and its outline.
    private func targetedPreview(in row: UICollectionView, at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = row.cellForItem(at: indexPath), cell.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        if let story = cell as? ForYouStoryCell {
            let face = story.faceView
            parameters.visiblePath = UIBezierPath(ovalIn: face.bounds)
            return UITargetedPreview(view: face, parameters: parameters)
        }
        let card = cell.contentView
        parameters.visiblePath = UIBezierPath(
            roundedRect: card.bounds, cornerRadius: ForYouFollowingCardCell.cornerRadius
        )
        return UITargetedPreview(view: card, parameters: parameters)
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
        return cardMenu(for: cards[index]).children.map(\.title)
    }

    /// The long-press configuration for card `index`, through the row's own
    /// delegate path.
    func debugCardMenuConfiguration(at index: Int, point: CGPoint = .zero) -> UIContextMenuConfiguration? {
        guard let indexPath = debugCardIndexPath(at: index) else { return nil }
        return collectionView(cardsView, contextMenuConfigurationForItemsAt: [indexPath], point: point)
    }

    /// Where card `index` (into `cards`) sits in the row's collection — its
    /// lane's section, with lanes.
    func debugCardIndexPath(at index: Int) -> IndexPath? {
        guard cards.indices.contains(index) else { return nil }
        return cardSource.indexPath(for: cards[index].id)
    }

    /// Card `index`'s frame in the row's content space, from its layout.
    func debugCardLayoutFrame(at index: Int) -> CGRect? {
        debugCardIndexPath(at: index).flatMap { cardsView.layoutAttributesForItem(at: $0)?.frame }
    }

    /// The two lanes' geometry, when the row has lanes.
    var debugLanesGeometry: ForYouFollowingLanes.Geometry? { lanesLayout?.geometry }

    /// Card `index`'s cell, when the row has realized it.
    func debugCardCell(at index: Int) -> ForYouFollowingCardCell? {
        guard cards.indices.contains(index) else { return nil }
        return cardCell(for: cards[index].id)
    }

    /// The Following row itself — for a test converting a point into it.
    var debugCardsView: UICollectionView { cardsView }

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
    var debugHeaders: [SectionTitleView] { [friendsHeader, followingHeader, listHeader] }

    /// Taps story `index` through the row's own selection path.
    func debugTapStory(at index: Int) -> Bool {
        guard stories.indices.contains(index) else { return false }
        collectionView(storiesView, didSelectItemAt: IndexPath(item: index, section: 0))
        return true
    }

    /// Taps card `index` through the row's own selection path.
    func debugTapCard(at index: Int) -> Bool {
        guard let indexPath = debugCardIndexPath(at: index) else { return false }
        collectionView(cardsView, didSelectItemAt: indexPath)
        return true
    }

    /// Whether card `index` has a face to fly — what a scripted open waits on.
    func debugCardIsReady(at index: Int) -> Bool {
        guard cards.indices.contains(index) else { return false }
        let post = cards[index]
        guard post.kind != .text else { return true }
        return cardCell(for: post.id)?.renderedCover != nil
    }

    /// The headers' OWN tap path (`SectionTitleView.debugTap`), not the
    /// host's closure: calling the closure is how #312's dead chevron passed.
    func debugTapFriendsHeader() { friendsHeader.debugTap() }
    func debugTapFollowingHeader() { followingHeader.debugTap() }
    func debugTapListHeader() { listHeader.debugTap() }
    var debugFriendsBadge: String? { friendsHeader.debugCountText }
    var debugFollowingBadge: String? { followingHeader.debugCountText }
    #endif
}

extension ForYouRailsView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if collectionView === storiesView {
            guard let id = storySource.itemIdentifier(for: indexPath),
                  let story = stories.first(where: { $0.authorID == id }) else { return }
            onStoryTapped?(story)
        } else {
            guard let id = cardSource.itemIdentifier(for: indexPath),
                  let index = cards.firstIndex(where: { $0.id == id }) else { return }
            onCardTapped?(index)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let drag, drag.row === scrollView {
            self.drag?.tracker.track(scrollView.contentOffset.x)
        }
        guard scrollView === cardsView else { return }
        // A horizontal row is short: reconciling on every tick costs a diff
        // of three cards, and a card that comes half into view should start
        // as it arrives, not when the finger lifts.
        updateAutoplay()
    }

    // MARK: - Snapping

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === storiesView || scrollView === cardsView else { return }
        drag = (scrollView, ForYouRowDragTracker(offset: scrollView.contentOffset.x))
    }

    /// The row comes to rest on an item's edge, the side picked by the
    /// gesture's direction — see `ForYouRowSnap`.
    ///
    /// ⚠️ A RELEASE WITH NO SPEED IS ANIMATED BY HAND. Handed a new target
    /// with a zero velocity, UIScrollView jumps to it rather than gliding, so
    /// a slow drag lifted from a standstill would teleport the row. There the
    /// row is told to stay where it is and is then animated to the snap.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard let row = scrollView as? UICollectionView, row === storiesView || row === cardsView else { return }
        let lastMovement = drag?.row === row ? drag?.tracker.lastMovement : nil
        drag = nil
        let target = snapTarget(
            in: row,
            projected: targetContentOffset.pointee.x,
            direction: ForYouRowSnap.direction(velocity: velocity.x, lastMovement: lastMovement)
        )
        let offsets = Self.offsetRange(of: row)
        let current = row.contentOffset.x
        guard abs(velocity.x) < ForYouRowSnap.flickVelocity, offsets.contains(current) else {
            // Moving — or pulled past an end, where UIKit's own spring back is
            // the motion wanted: the deceleration is bent onto the snap.
            targetContentOffset.pointee.x = target
            return
        }
        targetContentOffset.pointee.x = current
        guard target != current else { return }
        DispatchQueue.main.async { [weak row] in
            guard let row, !row.isTracking else { return }
            row.setContentOffset(CGPoint(x: target, y: row.contentOffset.y), animated: true)
        }
    }

    /// Where `row` rests after a release — its items' extents, read from its
    /// layout, handed to `ForYouRowSnap`. Two lanes hand their spreads
    /// instead (`ForYouFollowingLanes.Geometry.snapExtents`).
    func snapTarget(
        in row: UICollectionView, projected: CGFloat, direction: ForYouRowSnap.Direction?
    ) -> CGFloat {
        let content = CGRect(origin: .zero, size: row.collectionViewLayout.collectionViewContentSize)
        let items = (row.collectionViewLayout as? ForYouFollowingLanesLayout)?.geometry.snapExtents
            ?? (row.collectionViewLayout.layoutAttributesForElements(in: content) ?? [])
            .filter { $0.representedElementCategory == .cell }
            .map { $0.frame.minX...$0.frame.maxX }
            .sorted { $0.lowerBound < $1.lowerBound }
        return ForYouRowSnap.target(
            projected: projected,
            direction: direction,
            items: items,
            viewport: row.bounds.width,
            margin: Metrics.sideMargin,
            offsets: Self.offsetRange(of: row)
        )
    }

    /// Every content offset `row` can rest at.
    private static func offsetRange(of row: UIScrollView) -> ClosedRange<CGFloat> {
        let low = -row.adjustedContentInset.left
        let high = row.contentSize.width + row.adjustedContentInset.right - row.bounds.width
        return low...max(low, high)
    }

    // MARK: - Long press: the native preview

    /// A long press lifts the post — a card's own, or the one a friend's face
    /// opens first — with the menu under it. Keyed by an identifier that says
    /// which row and which item, so the commit below finds it again even if
    /// the row changed while the menu was up.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        let width = max(0, bounds.width - Metrics.sideMargin * 2)
        let pipeline = imagePipeline
        if collectionView === storiesView {
            guard let id = storySource.itemIdentifier(for: indexPath),
                  let story = stories.first(where: { $0.authorID == id }) else { return nil }
            let first = story.posts.first
            return UIContextMenuConfiguration(
                identifier: MenuTarget.story(id).identifier,
                // A friend with nothing loaded lifts their face alone.
                previewProvider: first.map { post in
                    { ForYouPostPreviewViewController(post: post, imagePipeline: pipeline, width: width) }
                },
                actionProvider: { [weak self] _ in self?.storyMenu(for: story) }
            )
        }
        guard let id = cardSource.itemIdentifier(for: indexPath),
              let post = cards.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(
            identifier: MenuTarget.card(id).identifier,
            previewProvider: {
                ForYouPostPreviewViewController(post: post, imagePipeline: pipeline, width: width)
            },
            actionProvider: { [weak self] _ in self?.cardMenu(for: post) }
        )
    }

    /// Where the preview lifts from and settles back to: the FACE for a
    /// friend (round, without its name), the card for a card — not the whole
    /// cell, whose rectangle would flash its square corners under the lift.
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
    /// the item, through the same flight.
    ///
    /// ⚠️ `.dismiss`, THEN OUR HERO — not UIKit's `.pop`. The row's open is a
    /// flight OUT OF THE CARD (or the face): it conceals the source, hands the
    /// card's player to the page, and the close lands back on that same card.
    /// A `.pop` commit grows the preview into a destination UIKit presents
    /// itself, and none of that would hold: no source concealed, no player
    /// handed over, and a close flying home to a card the opening never left.
    /// So the preview settles back into its card first and the flight takes
    /// off from there — one extra beat, and the open and the close are the
    /// same pair of motions whichever way in the viewer used. The open waits
    /// one turn past the completion so UIKit has put the card back before the
    /// flight measures and hides it.
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

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // A card that left gives its player back now — the pool is shared.
        guard collectionView === cardsView, let card = cell as? ForYouFollowingCardCell else { return }
        playback?.stop(cell: card)
    }
}
