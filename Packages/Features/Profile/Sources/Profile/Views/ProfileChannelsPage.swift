import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// The Channels tab's page (#2232): the channels the profile owns, one row
/// each (`ProfileChannelCell`), "Create a Channel" first on the viewer's own.
///
/// ⚠️ **A page of the profile's pager, not a post grid.** The pager hosts
/// `PostGridPage`s (`HeroPagePager`), and its hero mechanics — one shared
/// offset under the floating header, the travel it must offer, the detents
/// a release snaps to, the pull handed to the header — are what every page
/// owes it whatever it holds. This page keeps those, written as For You's
/// page writes them (`ForYouGridPage`'s hosted header), and answers every
/// post-shaped requirement with nothing: it holds no post to open, play or
/// fly.
///
/// It draws `ProfileChannelsViewModel.rows`, told by the model when they
/// change; the posts the pager shows every page (`show(_:)`) are not its.
final class ProfileChannelsPage: UIView, PostGridPage {
    private let model: ProfileChannelsViewModel
    private let pipeline: ImagePipeline?
    let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, ProfileChannelsViewModel.RowID>!

    /// "Create a Channel" was tapped.
    var onCreate: (() -> Void)?

    init(model: ProfileChannelsViewModel, pipeline: ImagePipeline?) {
        self.model = model
        self.pipeline = pipeline
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.showsSeparators = false
        list.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list)
        )
        super.init(frame: .zero)
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(ProfileChannelCell.self, forCellWithReuseIdentifier: ProfileChannelCell.reuseIdentifier)
        collectionView.register(
            ProfileChannelCreateCell.self, forCellWithReuseIdentifier: ProfileChannelCreateCell.reuseIdentifier
        )
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, id in
            self?.cell(in: view, at: path, for: id) ?? UICollectionViewCell()
        }
    }

    private func cell(
        in view: UICollectionView, at path: IndexPath, for id: ProfileChannelsViewModel.RowID
    ) -> UICollectionViewCell {
        switch id {
        case .create:
            return view.dequeueReusableCell(withReuseIdentifier: ProfileChannelCreateCell.reuseIdentifier, for: path)
        case .channel(let channelID):
            let cell = view.dequeueReusableCell(withReuseIdentifier: ProfileChannelCell.reuseIdentifier, for: path)
            guard let cell = cell as? ProfileChannelCell, let row = model.channel(channelID) else { return cell }
            cell.configure(with: row, pending: model.pending.contains(channelID), pipeline: pipeline)
            // The model holds no cell: the closures may keep it.
            let owner = self.model
            cell.onAction = { owner.performAction(on: channelID) }
            cell.onCancelRequest = { owner.cancelRequest(on: channelID) }
            return cell
        }
    }

    // MARK: - Rows

    /// Draws the model's rows: new rows in, gone rows out, and the rows that
    /// stay reconfigured in place — a change of standing morphs its button
    /// rather than reloading the cell.
    func render() {
        let ids = model.rows.map(\.id)
        var snapshot = NSDiffableDataSourceSnapshot<Int, ProfileChannelsViewModel.RowID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let kept = dataSource.snapshot().itemIdentifiers.filter { ids.contains($0) }
        snapshot.reconfigureItems(kept)
        dataSource.apply(snapshot, animatingDifferences: false)
        applyBottomInset()
    }

    /// A row's write was refused: its button says so.
    func showFailure(for id: ConversationID) {
        guard let path = dataSource.indexPath(for: .channel(id)),
              let cell = collectionView.cellForItem(at: path) as? ProfileChannelCell else { return }
        cell.showFailure()
    }

    // MARK: - PostGridPage: content (none of it posts)

    /// The posts every page is shown: not this page's.
    func show(_ state: PostGridPageState) {}
    func setCorpusComplete(_ complete: Bool) {}
    var showsTileInfo = false
    var staking: PostCardStaking?
    var onPostTapped: ((GalleryPost, [GalleryPost], Bool) -> Void)?
    var onNearEnd: (() -> Void)?
    var onViewAllTapped: (() -> Void)?
    var onAuthorTapped: ((GalleryPost) -> Void)?
    var postMenuActions: ((PostGridAuthorMenuContext) -> [PostCardMenuAction])?
    var onRefresh: (() -> Void)?
    func refreshAuthorMenus() {}

    // MARK: - PostGridPage: hosted under the profile's header

    var onVerticalScroll: ((CGFloat) -> Void)?
    var onPullReleased: ((CGFloat) -> Void)?
    var snapDetents: [CGFloat] = []
    var catchDetents: [CGFloat] = []
    var scrollView: UIScrollView { collectionView }

    /// Non-nil once hosted: the header's height above the rows.
    private var hostedTopInset: CGFloat?
    private var hostedBottomInset: CGFloat = 0
    private var minimumScrollTravel: CGFloat = 0
    /// A snap decided at a release with no momentum, which the scroll view
    /// won't carry out alone.
    private var pendingSnap: CGFloat?

    /// The page's distance from its content top — what the header rides.
    var verticalOffset: CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    /// Puts the rows under the floating header, as For You's page does: the
    /// header's height on top, the chrome's at the foot, insets managed by
    /// hand, the travel kept where it was.
    func setHostedInsets(top: CGFloat, bottom: CGFloat) {
        guard hostedTopInset != top || hostedBottomInset != bottom else { return }
        let travelled = verticalOffset
        hostedTopInset = top
        hostedBottomInset = bottom
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = top
        collectionView.verticalScrollIndicatorInsets.top = top
        collectionView.contentOffset.y = travelled - top
        applyBottomInset()
    }

    func setMinimumScrollTravel(_ travel: CGFloat) {
        guard minimumScrollTravel != travel else { return }
        minimumScrollTravel = travel
        applyBottomInset()
    }

    /// A hosted page must be ABLE to travel the header's whole run, however
    /// few rows it has — a short tab with nowhere to put the viewer makes
    /// the header snap back on a tab switch (the profile's rule): the room
    /// is empty space under the last row.
    private func applyBottomInset() {
        var bottom = hostedBottomInset
        if hostedTopInset != nil {
            let needed = minimumScrollTravel
                + collectionView.bounds.height
                - collectionView.contentSize.height
                - collectionView.contentInset.top
            bottom = max(bottom, needed)
        }
        // Value-guarded: this runs per scroll tick, and a write mid-drag
        // disturbs the pan.
        guard abs(collectionView.contentInset.bottom - bottom) > 0.5 else { return }
        collectionView.contentInset.bottom = bottom
        collectionView.verticalScrollIndicatorInsets.bottom = hostedBottomInset
    }

    func setVerticalOffset(_ offset: CGFloat, animated: Bool) {
        collectionView.layoutIfNeeded()
        applyBottomInset()
        let inset = collectionView.adjustedContentInset.top
        let travel = collectionView.contentSize.height + inset + collectionView.contentInset.bottom
            - collectionView.bounds.height
        let target = offset < 0 ? offset : min(offset, max(0, travel))
        guard abs(verticalOffset - target) > 0.5 else { return }
        let point = CGPoint(x: 0, y: target - inset)
        if animated {
            collectionView.setContentOffset(point, animated: true)
        } else {
            collectionView.contentOffset = point
        }
    }

    /// No refresh control of its own to drop: the header draws the pull.
    func handPullToHost() {}
    func setChromeOcclusion(_ occlusion: UIEdgeInsets?) {}

    override func layoutSubviews() {
        super.layoutSubviews()
        applyBottomInset()
    }

    // MARK: - PostGridPage: titled groups (none)

    func setPinLineInset(_ inset: CGFloat?) {}
    var onPinnedSectionChanged: ((PostGridPinnedSection?) -> Void)?
    var pinnedSection: PostGridPinnedSection? { nil }
    func scrollToSection(_ index: Int) {}

    // MARK: - PostGridPage: playback, opening, closing (nothing to fly)

    func setPageActive(_ active: Bool) {}
    func applyPendingReveal() {}

    /// Never asked: no row here opens a post. Answered with an origin that
    /// has nothing to fly — the plain push.
    func heroOrigin(
        opening tapped: GalleryPost, stream: [GalleryPost], in host: UIView,
        textReveal: TextRevealOrigin?, opensComments: Bool,
        willStageDismissal: @escaping () -> Void, pinsBeforeClose: Bool,
        continuation: SnapFeedContinuation?
    ) -> SnapFeedHeroOrigin {
        SnapFeedHeroOrigin(
            post: tapped, stream: stream, hasHero: false, cover: nil, style: .tile,
            frame: { _ in nil }, isOnScreen: { false }, setConcealed: { _ in },
            opensComments: opensComments, willStageDismissal: willStageDismissal, continuation: continuation
        )
    }

    func closeWindow(
        for post: GalleryPost, alignsPageToSource: Bool,
        willStageDismissal: @escaping () -> Void, dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin? { nil }

    func openHoldingStill(from host: UIViewController, _ open: () -> Void) { open() }
    func endPlaybackHandoff() {}
}

// MARK: - Scrolling and taps

extension ProfileChannelsPage: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hostedTopInset != nil else { return }
        applyBottomInset()
        onVerticalScroll?(verticalOffset)
    }

    /// The snap is written into the deceleration's target, as For You's
    /// page does (#1273): one motion, not a second one after the stop.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        pendingSnap = nil
        guard !snapDetents.isEmpty else { return }
        let inset = scrollView.adjustedContentInset.top
        let target = targetContentOffset.pointee.y + inset
        guard let snapped = ScrollDetents.snapped(
            target: target, detents: snapDetents, from: verticalOffset, catching: catchDetents
        ), abs(snapped - target) > 0.5 else { return }
        targetContentOffset.pointee.y = snapped - inset
        if abs(velocity.y) < 0.01 { pendingSnap = snapped - inset }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onPullReleased?(max(0, -verticalOffset))
        if !decelerate, let pendingSnap {
            self.pendingSnap = nil
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: pendingSnap), animated: true)
        }
    }

    /// A tap on a row: the channel's thread; on "Create a Channel", the sheet.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .create?: onCreate?()
        case .channel(let id)?: model.open(id)
        case nil: break
        }
    }
}

#if DEBUG
extension ProfileChannelsPage {
    /// The row cells on screen, top to bottom — what a test reads.
    var debugRowIDs: [ProfileChannelsViewModel.RowID] { dataSource.snapshot().itemIdentifiers }

    /// The cell drawing `id`'s channel, once laid out.
    func debugCell(for id: ConversationID) -> ProfileChannelCell? {
        collectionView.layoutIfNeeded()
        guard let path = dataSource.indexPath(for: .channel(id)) else { return nil }
        return collectionView.cellForItem(at: path) as? ProfileChannelCell
    }

    /// A tap on a row, through the page's own selection path.
    func debugSelect(_ id: ProfileChannelsViewModel.RowID) {
        guard let path = dataSource.indexPath(for: id) else { return }
        collectionView(collectionView, didSelectItemAt: path)
    }
}
#endif
