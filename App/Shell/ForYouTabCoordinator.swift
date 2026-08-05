import CoreNavigation
import FeedInterface
import UIKit

/// Owns the For You tab: the curated discovery grid as a root destination, on
/// its own navigation stack.
///
/// This took over the bar slot the Feed button used to hold. The difference is
/// the whole point of the change: that slot was an *action* — its selection was
/// vetoed and the timeline was pushed onto whatever tab you were on — whereas
/// this is an ordinary root tab with a stack of its own. The feed did not go
/// away; it moved behind a tile tap (see `ForYouViewController.openFeed`), and
/// the timeline remains reachable as a route through `FeedFlowCoordinator`.
///
/// Built once and retained for the session, like the Profile tab: a tab root
/// cannot be rebuilt on every visit without throwing away scroll position and
/// loaded pages on every tab switch.
@MainActor
final class ForYouTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    private(set) lazy var tab = UITab(
        title: "For You",
        image: UIImage(systemName: "sparkles"),
        identifier: AppTab.forYou.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let forYou = container.feedFeature.makeForYouViewController { [weak self] presentation in
            self?.apply(presentation)
        }
        navigationController.viewControllers = [forYou]
    }

    /// The lens menu this tab's root offers, for the shell to hang off a
    /// long press on the bar item.
    ///
    /// Read through the stack ROOT rather than held, because the root is the
    /// only thing that owns a lens — a thread or a post pushed on top of it
    /// does not, and asking `topViewController` would hand back nothing the
    /// moment the viewer navigated anywhere.
    var modeMenu: UIMenu? {
        (navigationController.viewControllers.first as? any ForYouModeMenuProviding)?.makeModeMenu()
    }

    /// The tab item follows the screen's content lens: its name, its glyph and
    /// how much is waiting under it.
    ///
    /// ⚠️ **The `UITab` is built lazily and its title/image are `var`s on the
    /// live object**, so this must not re-create it — `tabs` is assigned once
    /// in `MainTabCoordinator` and a replacement item would never reach the bar.
    /// Touching `tab` here is also what forces the lazy build if the shell has
    /// not asked for it yet, which is harmless: the provider closure only runs
    /// when the tab is selected.
    private func apply(_ presentation: ForYouTabPresentation) {
        tab.title = presentation.title
        tab.image = UIImage(systemName: presentation.symbol)
        tab.badgeValue = presentation.badgeCount > 0 ? String(presentation.badgeCount) : nil
    }
}
