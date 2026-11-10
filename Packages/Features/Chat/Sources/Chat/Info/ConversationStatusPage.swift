import CoreModels
import DesignSystem
import FeedInterface
import PostGrid
import UIKit

/// The Posts page when no page factory was handed to Chat (#2237): a
/// composition without Feed's (a test, a preview) still lays the info
/// screen out, the page's status under the header and nothing else. The
/// app always hands Feed's own page (`FeedFeatureBuilding.makePostGridPage`).
///
/// It draws statuses only: it never holds a post, so it never opens one.
final class ConversationStatusPage: UIView, PostGridPage, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private let statusView = EmptyStateView()
    private var hostedTop: CGFloat = 0
    private var hostedBottom: CGFloat = 0
    private var minimumTravel: CGFloat = 0
    /// What `show` last drew. Tests.
    private(set) var shownStatus: PostGridPageStatus?

    var showsTileInfo = false
    var staking: PostCardStaking?
    var onPostTapped: ((GalleryPost, [GalleryPost], Bool) -> Void)?
    var onNearEnd: (() -> Void)?
    var onViewAllTapped: (() -> Void)?
    var onAuthorTapped: ((GalleryPost) -> Void)?
    var postMenuActions: ((PostGridAuthorMenuContext) -> [PostCardMenuAction])?
    var onRefresh: (() -> Void)?
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onPullReleased: ((CGFloat) -> Void)?
    var onPinnedSectionChanged: ((PostGridPinnedSection?) -> Void)?
    private(set) var pinnedSection: PostGridPinnedSection?
    var snapDetents: [CGFloat] = []
    var catchDetents: [CGFloat] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.pin(to: self)
        statusView.isHidden = true
        statusView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Spacing.xl),
            statusView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            statusView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    func show(_ state: PostGridPageState) {
        guard case .status(let status) = state else {
            shownStatus = nil
            statusView.isHidden = true
            return
        }
        shownStatus = status
        statusView.configure(
            symbolName: status.symbolName, title: status.title, subtitle: status.subtitle,
            actionTitle: status.actionTitle, actionHandler: status.actionTitle == nil ? nil : { [weak self] in self?.onRefresh?() }
        )
        statusView.isHidden = false
        setNeedsLayout()
    }

    func setCorpusComplete(_ complete: Bool) {}
    func refreshAuthorMenus() {}

    // MARK: - Hosted under a floating header

    var verticalOffset: CGFloat { scrollView.contentOffset.y + scrollView.contentInset.top }

    func setHostedInsets(top: CGFloat, bottom: CGFloat) {
        let travelled = verticalOffset
        hostedTop = top
        hostedBottom = bottom
        scrollView.contentInset.top = top
        scrollView.verticalScrollIndicatorInsets.top = top
        applyBottomInset()
        scrollView.contentOffset.y = travelled - top
    }

    func setMinimumScrollTravel(_ travel: CGFloat) {
        minimumTravel = travel
        applyBottomInset()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyBottomInset()
    }

    /// Room for the header's whole travel, whatever the status's height.
    private func applyBottomInset() {
        let content = scrollView.contentSize.height
        let needed: CGFloat = minimumTravel + scrollView.bounds.height - content - hostedTop
        let bottom = max(hostedBottom, needed)
        if abs(scrollView.contentInset.bottom - bottom) > 0.5 { scrollView.contentInset.bottom = bottom }
    }

    func setChromeOcclusion(_ occlusion: UIEdgeInsets?) {}
    func handPullToHost() {}

    func setVerticalOffset(_ offset: CGFloat, animated: Bool) {
        layoutIfNeeded()
        let inset = scrollView.contentInset
        let travel: CGFloat = scrollView.contentSize.height + inset.top + inset.bottom - scrollView.bounds.height
        let target = offset < 0 ? offset : min(offset, max(0, travel))
        scrollView.setContentOffset(CGPoint(x: 0, y: target - inset.top), animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onVerticalScroll?(verticalOffset)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let travelled = verticalOffset
        if travelled < 0 { onPullReleased?(-travelled) }
    }

    // MARK: - Titled groups: none

    func setPinLineInset(_ inset: CGFloat?) {}
    func scrollToSection(_ index: Int) {}

    // MARK: - Playback, opening and closing: nothing to open

    func setPageActive(_ active: Bool) {}
    func applyPendingReveal() {}

    func heroOrigin(
        opening tapped: GalleryPost, stream: [GalleryPost], in host: UIView,
        textReveal: TextRevealOrigin?, opensComments: Bool,
        willStageDismissal: @escaping () -> Void, pinsBeforeClose: Bool,
        continuation: SnapFeedContinuation?
    ) -> SnapFeedHeroOrigin {
        // `show` draws no post, so no post is ever tapped here.
        preconditionFailure("a status page holds no post to open")
    }

    func closeWindow(
        for post: GalleryPost, alignsPageToSource: Bool,
        willStageDismissal: @escaping () -> Void, dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin? { nil }

    func openHoldingStill(from host: UIViewController, _ open: () -> Void) { open() }
    func endPlaybackHandoff() {}
}
