import DesignSystem
import UIKit

/// The comments' Popular | Recent selector (#2007), in the left run where the
/// sort pill stood: `[‹] [Popular | Recent]`, `[✕] [Popular | Recent]`.
///
/// The For You sector's capsule (#1703), the same `PagedTabBar` in a bar's
/// container item (the bar contract, #1679), bound to one panel's pager: a
/// tap scrolls the streams to the tab, as a swipe would (the owner,
/// 2026-11-01), and a swipe of the streams moves the pill. One state with the
/// pager — the pill follows its every frame, and the pager is the one that
/// settles.
///
/// Owned by the screen that draws the bar (the vertical feed, the published
/// text post), and re-bound to whichever panel holds its comments.
@MainActor
final class CommentTabsSelector {
    /// The tabs, in the pager's order: Popular first, the default (the owner,
    /// 2026-11-01).
    static let titles = ["Popular", "Recent"]

    let tabBar = PagedTabBar(titles: CommentTabsSelector.titles, style: .navigationTitle)

    /// The panel whose streams the selector shows.
    private(set) weak var panel: PostDetailViewController?

    init() {
        tabBar.hosting = .platter
        tabBar.onScrub = { [weak self] progress in self?.panel?.streamPager.scrub(to: progress) }
        tabBar.onScrubEnd = { [weak self] velocity in
            self?.panel?.streamPager.settleAfterScrub(velocityInPages: velocity)
        }
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self, let panel else { return }
            panel.showStream(
                tabBar.selectedIndex == PostDetailViewController.popularPage ? .popular : .recent,
                animated: true
            )
        }, for: .valueChanged)
    }

    /// Follows `panel`'s pager from now on, starting on its visible tab.
    func bind(to panel: PostDetailViewController?) {
        if let bound = self.panel, bound !== panel { bound.onStreamProgress = nil }
        self.panel = panel
        guard let panel else { return }
        tabBar.select(panel.visibleStreamKind == .popular ? PostDetailViewController.popularPage : PostDetailViewController.recentPage)
        panel.onStreamProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
    }

    /// The capsule's width in the bar, before UIKit's item padding.
    var width: CGFloat { tabBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }
}
