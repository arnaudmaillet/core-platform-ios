import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The two rows that lead For You's list (2026-09-29):
///
/// ```
///   Friends                                   (3) ›
///   ◉ ◉ ◉ ○ ○ ○ ○          stories: unseen first, with a ring
///   Following                                 (5) ›
///   ┌──────┐ ┌──────┐ ┌───       cards, the third peeking;
///   │ ▶    │ │      │ │           the lead one plays, and
///   │ Ana  │ │ Bo   │ │           each wears its first two
///   │ two… │ │ two… │ │           lines over its foot
///   └──────┘ └──────┘ └───
///   ─── Discover's list ─────────────────────────────
/// ```
///
/// Hosted as the list's LEADING HEADER (`ForYouGridPage.setLead`), not as
/// sections of its own: every index path, chunk plan, hero and reveal on the
/// list is counted in its sections, and a header that scrolls with them
/// changes none of that arithmetic.
///
/// A row with nothing in it is not drawn at all — no heading over nothing,
/// the inbox's rule for its sections — and with both empty the header is zero
/// tall and the list starts at the top.
///
/// Each header is a way in (`SectionLinkHeaderView`): the whole bar pushes its
/// screen, and its pill counts what is new in the row.
///
/// ⚠️ NOT `@MainActor` in so many words, and not for want of it: a `UIView`
/// subclass is main-actor by inference already, and the explicit attribute
/// turns the synchronous `ImagePipeline.cachedImage` read — which every grid
/// in this app makes on its cover gate — from a warning into an error.
final class ForYouRailsView: UIView {
    enum Metrics {
        static var sideMargin: CGFloat { PostGridListLayout.sideMargin }
        static let storySpacing: CGFloat = 6
        static let cardSpacing: CGFloat = 8
        /// Cards per screen width: two whole, and a third peeking to say the
        /// row goes on.
        static let cardsPerWidth: CGFloat = 2.3
        /// Height over width: portrait, tall enough that two lines of caption
        /// sit over the picture without burying it.
        static let cardAspect: CGFloat = 4.0 / 3.0
        /// Between the two rows, and below the second before the list.
        static let rowGap: CGFloat = 10
        static let listGap: CGFloat = 14

        static func cardSize(forWidth width: CGFloat) -> CGSize {
            let cardWidth = ((width - sideMargin * 2) / cardsPerWidth).rounded(.down)
            return CGSize(width: cardWidth, height: (cardWidth * cardAspect).rounded())
        }
    }

    /// The height the rows need at `width` — what the host sizes its header to.
    static func height(forWidth width: CGFloat, friends: Int, following: Int) -> CGFloat {
        var height: CGFloat = 0
        if friends > 0 {
            height += SectionLinkHeaderView.height + ForYouStoryCell.Metrics.size.height
        }
        if following > 0 {
            if friends > 0 { height += Metrics.rowGap }
            height += SectionLinkHeaderView.height + Metrics.cardSize(forWidth: width).height
        }
        return height > 0 ? height + Metrics.listGap : 0
    }

    var preferredHeight: CGFloat {
        Self.height(forWidth: bounds.width, friends: stories.count, following: cards.count)
    }

    /// A story's avatar was tapped.
    var onStoryTapped: ((ForYouViewModel.FriendStory) -> Void)?
    /// A card was tapped: its index into `cards`.
    var onCardTapped: ((Int) -> Void)?
    var onFriendsHeaderTapped: (() -> Void)?
    var onFollowingHeaderTapped: (() -> Void)?
    /// The rows changed which of them are drawn — the host re-sizes its header.
    var onHeightChange: (() -> Void)?
    /// The part of the screen the viewer can see, in THIS view's space, for
    /// autoplay: a card under the navigation bar is not one they are looking
    /// at. Nil (no host yet) plays nothing.
    var visibleBand: (() -> CGRect?)?

    private(set) var stories: [ForYouViewModel.FriendStory] = []
    private(set) var cards: [GalleryPost] = []

    private let friendsHeader = SectionLinkHeaderView(title: "Friends")
    private let followingHeader = SectionLinkHeaderView(title: "Following")
    private let storiesView: UICollectionView
    private let cardsView: UICollectionView
    private let imagePipeline: ImagePipeline
    /// The Following row's own playback — ONE card at a time, the row's lead.
    /// The list below keeps five: six is the pool's budget
    /// (`VideoPlaybackController.capacity`), and a seventh clip starves one of
    /// the six already playing.
    private let playback: GridVideoPlaybackCoordinator?
    static let concurrentPlayers = 1

    private var storySource: UICollectionViewDiffableDataSource<Int, ProfileID>!
    private var cardSource: UICollectionViewDiffableDataSource<Int, PostID>!

    /// The story whose disc a flight is carrying, hidden until it lands.
    private var concealedStory: ProfileID?
    /// The card a flight is carrying.
    private var concealedCard: PostID?

    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController?) {
        self.imagePipeline = imagePipeline
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: Self.concurrentPlayers)
        }
        storiesView = UICollectionView(frame: .zero, collectionViewLayout: Self.rowLayout(
            itemSize: ForYouStoryCell.Metrics.size, spacing: Metrics.storySpacing
        ))
        cardsView = UICollectionView(frame: .zero, collectionViewLayout: Self.rowLayout(
            itemSize: CGSize(width: 150, height: 200), spacing: Metrics.cardSpacing
        ))
        super.init(frame: .zero)
        for row in [storiesView, cardsView] {
            row.backgroundColor = .clear
            row.showsHorizontalScrollIndicator = false
            row.alwaysBounceHorizontal = true
            row.alwaysBounceVertical = false
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
            // Autoplay is gated on the cover: its arrival re-opens the gate
            // for a card that came up faceless while the row sat still.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            cell.isHidden = id == concealedCard
            return cell
        }
        friendsHeader.addAction(UIAction { [weak self] _ in self?.onFriendsHeaderTapped?() }, for: .primaryActionTriggered)
        followingHeader.addAction(UIAction { [weak self] _ in self?.onFollowingHeaderTapped?() }, for: .primaryActionTriggered)
        addSubview(friendsHeader)
        addSubview(followingHeader)
        friendsHeader.isHidden = true
        followingHeader.isHidden = true
        storiesView.isHidden = true
        cardsView.isHidden = true
        friendsHeader.accessibilityHint = "Shows your friends' posts"
        followingHeader.accessibilityHint = "Shows posts from people you follow"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func rowLayout(itemSize: CGSize, spacing: CGFloat) -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = itemSize
        layout.minimumLineSpacing = spacing
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 0, left: Metrics.sideMargin, bottom: 0, right: Metrics.sideMargin)
        return layout
    }

    // MARK: - Content

    func render(_ rails: ForYouViewModel.Rails) {
        let oldHeight = preferredHeight
        let storiesChanged = rails.friends != stories
        let cardsChanged = rails.following != cards
        stories = rails.friends
        cards = rails.following
        friendsHeader.setCount(rails.friendsBadge)
        followingHeader.setCount(rails.followingBadge)
        if storiesChanged { applyStories() }
        if cardsChanged { applyCards() }
        setNeedsLayout()
        if preferredHeight != oldHeight { onHeightChange?() }
    }

    /// Animated, so a ring clearing reads as the friend moving over to the
    /// others rather than as the row being rebuilt — keyed by FRIEND, so a
    /// friend whose ring changed is the same item, reconfigured in place.
    private func applyStories() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ProfileID>()
        snapshot.appendSections([0])
        snapshot.appendItems(stories.map(\.authorID))
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            storySource.snapshot().itemIdentifiers.contains($0)
        })
        storySource.apply(snapshot, animatingDifferences: window != nil)
    }

    private func applyCards() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, PostID>()
        snapshot.appendSections([0])
        snapshot.appendItems(cards.map(\.id))
        cardSource.apply(snapshot, animatingDifferences: window != nil) { [weak self] in
            self?.updateAutoplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let margin = Metrics.sideMargin
        var y: CGFloat = 0
        let hasStories = !stories.isEmpty
        let hasCards = !cards.isEmpty
        friendsHeader.isHidden = !hasStories
        storiesView.isHidden = !hasStories
        followingHeader.isHidden = !hasCards
        cardsView.isHidden = !hasCards
        if hasStories {
            friendsHeader.frame = CGRect(
                x: margin, y: y, width: width - margin * 2, height: SectionLinkHeaderView.height
            )
            y += SectionLinkHeaderView.height
            let height = ForYouStoryCell.Metrics.size.height
            storiesView.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        if hasCards {
            if hasStories { y += Metrics.rowGap }
            followingHeader.frame = CGRect(
                x: margin, y: y, width: width - margin * 2, height: SectionLinkHeaderView.height
            )
            y += SectionLinkHeaderView.height
            let size = Metrics.cardSize(forWidth: width)
            if let layout = cardsView.collectionViewLayout as? UICollectionViewFlowLayout,
               layout.itemSize != size {
                layout.itemSize = size
            }
            cardsView.frame = CGRect(x: 0, y: y, width: width, height: size.height)
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

    /// Reconciles the row's one player against what is on screen. Cheap and
    /// idempotent; the host calls it as the LIST scrolls (the row moving in or
    /// out of the band) and the row calls it as ITSELF scrolls.
    func updateAutoplay(allowingStarts: Bool = true) {
        guard let playback else { return }
        guard isAutoplayActive, !cardsView.isHidden, let band = visibleBand?() else {
            playback.update(candidates: [], allowingStarts: allowingStarts)
            return
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
            // The LEAD card wins: the row is read from its leading edge, so the
            // card nearest it is the one being looked at.
            return .init(id: id, url: url, cell: cell, distanceFromCentre: abs(frame.minX - viewport.minX))
        }
        playback.update(candidates: candidates, allowingStarts: allowingStarts)
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
        playback?.focus(id)
        updateAutoplay()
        playback?.beginHandoff(id)
    }

    func endPlaybackHandoff() {
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
        guard let cell = storyCell(for: id), isVisible(cell, in: storiesView) else { return nil }
        return cell.discFrame(in: space)
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

    func cardFrame(for id: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = cardCell(for: id), isVisible(cell, in: cardsView) else { return nil }
        return cell.convert(cell.bounds, to: space)
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
        guard !visible.contains(frame) else { return }
        row.scrollRectToVisible(frame.insetBy(dx: -Metrics.sideMargin, dy: 0), animated: false)
        row.layoutIfNeeded()
    }

    private func isVisible(_ cell: UICollectionViewCell, in row: UICollectionView) -> Bool {
        guard cell.window != nil, !row.isHidden else { return false }
        return row.bounds.intersects(cell.frame)
    }

    #if DEBUG
    /// Taps story `index` through the row's own selection path.
    func debugTapStory(at index: Int) -> Bool {
        guard stories.indices.contains(index) else { return false }
        collectionView(storiesView, didSelectItemAt: IndexPath(item: index, section: 0))
        return true
    }

    /// Taps card `index` through the row's own selection path.
    func debugTapCard(at index: Int) -> Bool {
        guard cards.indices.contains(index) else { return false }
        collectionView(cardsView, didSelectItemAt: IndexPath(item: index, section: 0))
        return true
    }

    /// Whether card `index` has a face to fly — what a scripted open waits on.
    func debugCardIsReady(at index: Int) -> Bool {
        guard cards.indices.contains(index) else { return false }
        let post = cards[index]
        guard post.kind != .text else { return true }
        return cardCell(for: post.id)?.renderedCover != nil
    }

    func debugTapFriendsHeader() { onFriendsHeaderTapped?() }
    func debugTapFollowingHeader() { onFollowingHeaderTapped?() }
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
        guard scrollView === cardsView else { return }
        // A horizontal row is short: reconciling on every tick costs a diff
        // of three cards, and a card that crosses the lead position should
        // start as it arrives, not when the finger lifts.
        updateAutoplay()
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
