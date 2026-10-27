import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// For You's Friends row (#1271): the title and a row of faces, unseen first
/// with a ring — a section of For You's lead (`GridLeadStack`), above the
/// shelf of the people the viewer follows (`PostShelfSection`).
///
/// ```
///     Friends 3 ›
///   ◉ ◉ ◉ ○ ○ ○ ○          stories: unseen first, with a ring
/// ```
///
/// **The row holds its order while the screen is the viewer's.** A friend
/// whose posts were just watched loses their ring at once but keeps their
/// place; the row re-sorts (unseen first) only once the viewer has left —
/// another tab, or the app (`releaseStoryOrder`). A row that reshuffles as
/// the viewer comes back to it moves the face they just tapped out from under
/// their eyes.
///
/// **A tap opens, a long press previews, and nothing gives under a finger**
/// (2026-09-29): a tap is the row's own selection; a long press lifts the
/// friend's first post (`ForYouPostPreviewViewController`), and tapping the
/// preview opens it the way a tap would.
///
/// With no friends it is zero tall — no heading over nothing.
@MainActor
final class FriendsStoriesRow: UIView, GridLeadSection {
    /// Each animated face plays once on its first display in this row (#1358).
    let animationScope = AnimatedAvatarScope()
    /// The height the row needs at `width` with `friends` faces.
    static func height(forWidth width: CGFloat, friends: Int) -> CGFloat {
        guard friends > 0 else { return 0 }
        return SectionTitleView.Metrics.height + LeadRowMetrics.storySize(forWidth: width).height
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        Self.height(forWidth: width, friends: max(stories.count, placeholderCount))
    }

    // MARK: - Skeleton (#1756)

    /// How many skeleton faces stand in while the row loads: the friends it
    /// held LAST time (`SectionPresenceStore`), 0 when it had none or has
    /// never loaded — then no skeleton, and the row fades in with its data.
    /// Real friends take the bones' place.
    var placeholderCount = 0 {
        didSet {
            guard placeholderCount != oldValue else { return }
            let had = oldValue > 0 && stories.isEmpty
            setNeedsLayout()
            if had != showsPlaceholders { onHeightChange?() }
        }
    }
    /// Whether the bones show — the room is the skeleton's from the start,
    /// the bones only after the delay (`SkeletonGate`).
    var bonesVisible = true {
        didSet { placeholderViews.forEach { $0.alpha = bonesVisible ? 1 : 0 } }
    }
    private var showsPlaceholders: Bool { placeholderCount > 0 && stories.isEmpty }
    /// A face (in the row's tile) and its name, per skeleton friend.
    private var placeholderViews: [UIView] = []

    private func layoutPlaceholders(width: CGFloat) {
        guard showsPlaceholders, width > 0 else {
            placeholderViews.forEach { $0.removeFromSuperview() }
            placeholderViews = []
            return
        }
        let size = LeadRowMetrics.storySize(forWidth: width)
        // As many as the width shows (four whole, one peeking), never more
        // than the friends it held.
        let shown = min(placeholderCount, Int(LeadRowMetrics.storiesPerWidth.rounded(.up)))
        while placeholderViews.count < shown * 2 {
            let face = AvatarSkeletonView()
            face.shape = ForYouStoryCell.Metrics.faceShape
            let name = SkeletonBoneView()
            for view in [face, name] as [UIView] {
                view.alpha = bonesVisible ? 1 : 0
                addSubview(view)
                placeholderViews.append(view)
            }
        }
        while placeholderViews.count > shown * 2 { placeholderViews.removeLast().removeFromSuperview() }
        let inset = ForYouStoryCell.Metrics.ringWidth + ForYouStoryCell.Metrics.ringGap
        for index in 0..<shown {
            let x = LeadRowMetrics.sideMargin + CGFloat(index) * (size.width + LeadRowMetrics.itemGap)
            let top = SectionTitleView.Metrics.height
            let disc = CGRect(x: x, y: top, width: size.width, height: size.width)
            placeholderViews[index * 2].frame = disc.insetBy(dx: inset, dy: inset)
            // A first name's width, varied by a fixed rule — never at random.
            let nameWidth = size.width * [0.62, 0.48, 0.7, 0.55][index % 4]
            placeholderViews[index * 2 + 1].frame = CGRect(
                x: x + (size.width - nameWidth) / 2,
                y: disc.maxY + ForYouStoryCell.Metrics.nameGap + 4,
                width: nameWidth, height: ForYouStoryCell.Metrics.nameHeight - 8
            )
        }
    }

    /// The row came to hold friends, or none — its host re-sizes.
    var onHeightChange: (() -> Void)?
    /// A friend's face was tapped.
    var onStoryTapped: ((ForYouViewModel.FriendStory) -> Void)?
    /// The lift a committed long press opens from, while the window opens
    /// out of it (#1543, `TextRevealInstaller`).
    var previewLaunch: PreviewLaunch?
    /// The title was tapped: the host pushes the friends' list.
    var onTitleTapped: (() -> Void)? {
        didSet { header.onTap = onTitleTapped }
    }
    /// What a long press on a friend offers under the preview, after "Open"
    /// — the host's rows (View Profile, Unfollow), since this view can service
    /// none of them.
    var storyMenuElements: ((ForYouViewModel.FriendStory) -> [UIMenuElement])?

    private(set) var stories: [ForYouViewModel.FriendStory] = []
    /// The friends as the view model last ordered them — what the row shows
    /// once it is free to re-sort (`releaseStoryOrder`).
    private var latestStories: [ForYouViewModel.FriendStory] = []
    /// The order the viewer has been SHOWN, held while the screen is theirs —
    /// nil until the row is first drawn in a window, and again once released.
    private var heldStoryOrder: [ProfileID]?

    let header = SectionTitleView(content: .init(title: "Friends", isLink: true))
    let storiesView: UICollectionView
    let imagePipeline: ImagePipeline

    /// The Friends row's lookahead (#970), along its horizontal axis — a
    /// screen width ahead decoded, two and a half on disk. Outside the list's
    /// display window it plans nothing (`refreshLookaheadReach`).
    ///
    /// The faces carry their story's first pictures too: a tap opens the
    /// face's window onto its first post (#1356), and nothing else on this
    /// screen shows the friends' posts, so the page would open cold.
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

    /// The pool a lifted post's clip plays from (#1318); nil lifts the cover.
    var videoPlayback: VideoPlaybackController?

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        storiesView = RowGeometry.makeRow(itemSize: ForYouStoryCell.Metrics.size(discSide: 70))
        super.init(frame: .zero)
        storiesView.delegate = self
        addSubview(header)
        addSubview(storiesView)
        storiesView.register(ForYouStoryCell.self, forCellWithReuseIdentifier: ForYouStoryCell.reuseID)
        storySource = UICollectionViewDiffableDataSource(collectionView: storiesView) {
            [weak self] view, indexPath, id in
            let cell = view.dequeueReusableCell(
                withReuseIdentifier: ForYouStoryCell.reuseID, for: indexPath
            ) as! ForYouStoryCell
            guard let self, let story = stories.first(where: { $0.authorID == id }) else { return cell }
            cell.configure(with: story, imagePipeline: imagePipeline, animationScope: self.animationScope)
            cell.isDiscConcealed = id == concealedStory
            return cell
        }
        header.isHidden = true
        storiesView.isHidden = true
        header.accessibilityHint = "Shows your friends' posts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    /// Shows `friends` — in the order the viewer was shown, while it is held
    /// — and `newCount` after the title.
    func render(_ friends: [ForYouViewModel.FriendStory], newCount: Int) {
        let hadFriends = !stories.isEmpty || showsPlaceholders
        latestStories = friends
        let ordered = heldStoryOrder.map { Self.holding(friends, in: $0) } ?? friends
        let changed = ordered != stories
        stories = ordered
        header.content = .init(title: "Friends", newCount: newCount, isLink: true)
        if changed {
            applyStories(animated: window != nil)
            storyLookahead.setNeedsPlan()
        }
        holdStoryOrderIfShown()
        setNeedsLayout()
        if hadFriends != (!stories.isEmpty || showsPlaceholders) { onHeightChange?() }
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
        let hasStories = !stories.isEmpty
        header.isHidden = !hasStories && !showsPlaceholders
        storiesView.isHidden = !hasStories
        layoutPlaceholders(width: width)
        if showsPlaceholders {
            header.frame = CGRect(x: 0, y: 0, width: width, height: SectionTitleView.Metrics.height)
        }
        guard hasStories else { return }
        // The title spans the row edge to edge: it stands its own inset from
        // the surface (`SectionTitleView.Metrics.surfaceInset`).
        header.frame = CGRect(x: 0, y: 0, width: width, height: SectionTitleView.Metrics.height)
        let size = LeadRowMetrics.storySize(forWidth: width)
        RowGeometry.setItemSize(size, of: storiesView)
        storiesView.frame = CGRect(x: 0, y: SectionTitleView.Metrics.height, width: width, height: size.height)
    }

    // MARK: - Lookahead

    /// The screen is (or is no longer) the viewer's: covered, the row drops to
    /// the minimum windows (#970).
    func setActive(_ active: Bool) {
        storyLookahead.setHidden(!active)
        if active { refreshLookaheadReach() }
    }

    /// The list scrolled: the row's reach follows it.
    func listDidScroll() { refreshLookaheadReach() }

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
    /// (`LeadRowMetrics.storiesPerWidth`), so there is no constant to read.
    var storyFaceDiameter: CGFloat {
        let width = bounds.width > 0 ? bounds.width : 393
        return ForYouStoryCell.Metrics.faceDiameter(discSide: LeadRowMetrics.storySize(forWidth: width).width)
    }

    /// The face's corner as the row draws it — what a flight out of a face
    /// leaves with and lands on. A face is NOT a disc
    /// (`ForYouStoryCell.Metrics.faceShape`), so this is not half the side.
    var storyFaceCornerRadius: CGFloat {
        ForYouStoryCell.Metrics.faceShape.cornerRadius(side: storyFaceDiameter)
    }

    /// The face a flight carries: the avatar's own picture, or — for a
    /// friend drawn as initials — the cell's render of them (#1356).
    func storyFace(for id: ProfileID) -> UIImage? {
        guard let cell = storyCell(for: id) else { return nil }
        return cell.shownPicture ?? cell.renderedFace()
    }

    func isStoryOnScreen(_ id: ProfileID) -> Bool {
        storyCell(for: id).map { RowGeometry.isVisible($0, in: storiesView) } ?? false
    }

    func setStoryConcealed(_ concealed: Bool, for id: ProfileID) {
        if concealed { concealedStory = id } else if concealedStory == id { concealedStory = nil }
        storyCell(for: id)?.isDiscConcealed = concealed
    }

    /// Puts the face a flight hid back.
    func clearConcealments() {
        if let concealedStory { setStoryConcealed(false, for: concealedStory) }
    }

    /// Scrolls the row so a face is wholly in view — before a close measures
    /// where it lands, since the row can be scrolled under an open post.
    func bringStoryIntoView(_ id: ProfileID) {
        guard let indexPath = storySource.indexPath(for: id) else { return }
        RowGeometry.bringIntoView(indexPath, in: storiesView)
    }

    // MARK: - Long press

    /// Opens a friend the way a tap would — nothing if they left the row
    /// while the menu was up.
    func open(_ id: ProfileID) {
        guard let story = stories.first(where: { $0.authorID == id }) else { return }
        onStoryTapped?(story)
    }

    func storyMenu(for story: ForYouViewModel.FriendStory) -> UIMenu {
        let id = story.authorID
        var children: [UIMenuElement] = []
        if !story.posts.isEmpty {
            children.append(RowGeometry.openAction { [weak self] in self?.open(id) })
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
        // In the row's view, not in the clipping collection view the face
        // scrolls in: the highlight grows past the face (#1639, the shelf's
        // same fix).
        let centre = face.convert(CGPoint(x: face.bounds.midX, y: face.bounds.midY), to: self)
        return UITargetedPreview(view: face, parameters: parameters, target: UIPreviewTarget(container: self, center: centre))
    }

    #if DEBUG
    /// The menu a long press on story `index` would show — its rows' titles.
    func debugStoryMenuTitles(at index: Int) -> [String] {
        guard stories.indices.contains(index) else { return [] }
        return storyMenu(for: stories[index]).children.map(\.title)
    }

    /// The friends' order as drawn.
    var debugStoryOrder: [ProfileID] { stories.map(\.authorID) }

    /// Taps story `index` through the row's own selection path.
    func debugTapStory(at index: Int) -> Bool {
        guard stories.indices.contains(index) else { return false }
        collectionView(storiesView, didSelectItemAt: IndexPath(item: index, section: 0))
        return true
    }

    /// The title's OWN tap path (`SectionTitleView.debugTap`), not the host's
    /// closure: calling the closure is how #312's dead chevron passed.
    func debugTapTitle() { header.debugTap() }
    var debugCountText: String? { header.debugCountText }

    /// Opens what a committed preview would — the commit's own path, minus
    /// UIKit's animator.
    func debugCommitPreview(_ configuration: UIContextMenuConfiguration) {
        guard case .story(let id)? = RowMenuTarget(configuration.identifier) else { return }
        open(id)
    }
    #endif
}

extension FriendsStoriesRow: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = storySource.itemIdentifier(for: indexPath) else { return }
        open(id)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        snapper.didScroll(scrollView)
        storyLookahead.scrollViewDidScroll()
    }

    /// The row came to rest: its fling is over, and its display window decodes.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        storyLookahead.scrollViewDidEndScrolling()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        snapper.willBeginDragging(scrollView)
    }

    /// The row comes to rest on a face's edge — see `RowSnapper`.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        snapper.willEndDragging(
            storiesView, velocity: velocity, targetContentOffset: targetContentOffset, stepped: false
        )
    }

    /// Where the row rests after a release — see `RowSnapper.snapTarget`.
    func snapTarget(projected: CGFloat, start: CGFloat, direction: ForYouRowSnap.Direction?) -> CGFloat {
        RowSnapper.snapTarget(
            in: storiesView, projected: projected, start: start, direction: direction, stepped: false
        )
    }

    /// A long press on a face lifts the post it opens first, with the menu
    /// under it. A friend with nothing loaded lifts their face alone.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let id = storySource.itemIdentifier(for: indexPath),
              let story = stories.first(where: { $0.authorID == id }) else { return nil }
        let width = max(0, bounds.width - LeadRowMetrics.sideMargin * 2)
        let pipeline = imagePipeline
        let pool = videoPlayback
        return UIContextMenuConfiguration(
            identifier: RowMenuTarget.story(id).identifier,
            previewProvider: story.posts.first.map { post in
                {
                    ForYouPostPreviewViewController(
                        post: post, imagePipeline: pipeline, width: width, videoPlayback: pool
                    )
                }
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
        // A committed lift fades where it is, under its window (#1543).
        previewLaunch?.dismissalTarget() ?? targetedPreview(at: indexPath)
    }

    /// Tapping the lifted preview opens the friend's post — the same open as
    /// a tap on the face, through the same window, out of the lift itself
    /// (#1543): captured now (`PreviewLaunch`), it fades in place under the
    /// window opening from it (`TextRevealInstaller`).
    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard case .story(let id)? = RowMenuTarget(configuration.identifier) else { return }
        animator.preferredCommitStyle = .dismiss
        if let preview = animator.previewViewController as? ForYouPostPreviewViewController,
           let launch = PreviewLaunch(preview) {
            previewLaunch = launch
            DispatchQueue.main.async { [weak self] in self?.open(id) }
            return
        }
        animator.addCompletion { [weak self] in
            DispatchQueue.main.async { self?.open(id) }
        }
    }
}
