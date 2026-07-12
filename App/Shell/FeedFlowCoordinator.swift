import CoreNavigation
import FeedInterface
import UIKit

/// Owns the timeline feed as a shell-level flow — not a tab root. The Feed
/// button in the bar is an action trigger (`MainTabCoordinator` vetoes its
/// selection): tapping it pushes the timeline onto the currently active tab's
/// stack, so back returns to wherever the user came from.
///
/// One `SnapFeedViewController` lives for the shell's lifetime and is reused
/// across pushes: scroll position, loaded pages, and the compose hand-off
/// channel survive pop/re-push — the continuity the retained tab root used to
/// provide. The cost is one off-screen collection view, the same as when the
/// feed was a background tab.
@MainActor
final class FeedFlowCoordinator: Coordinator {
    var childCoordinators: [Coordinator] = []

    private let container: AppContainer

    /// Built on first push, then retained. The shell installs NOTHING on the
    /// feed's navigation item: its chrome must stay identical to the
    /// pin-opened feed's (one construction truth — see `FeedFeatureBuilder`).
    private lazy var feedViewController: UIViewController = makeFeedViewController()

    init(container: AppContainer) {
        self.container = container
    }

    /// Nothing to build up front; the timeline is assembled on first push.
    func start() {}

    /// Pushes the retained timeline onto `navigationController`. Idempotent:
    /// already on top is a no-op; lower on the same stack pops back to it; on
    /// a *different* tab's stack (a deep link can fire while it sits pushed
    /// elsewhere) it is lifted off invisibly first — a view controller can
    /// only ever have one parent.
    func push(on navigationController: UINavigationController) {
        let feed = feedViewController
        if let currentStack = feed.navigationController {
            if currentStack === navigationController {
                if currentStack.topViewController !== feed {
                    currentStack.popToViewController(feed, animated: true)
                }
                return
            }
            currentStack.setViewControllers(
                currentStack.viewControllers.filter { $0 !== feed },
                animated: false
            )
        }
        navigationController.pushViewController(feed, animated: true)
    }

    private func makeFeedViewController() -> UIViewController {
        let feedViewController = container.feedFeature.makeFeedViewController()
        // Native bottom-bar choreography: the bar slides out with the push and
        // scrubs with the edge-swipe pop. (The pin-opened feed manages the bar
        // by hand instead — its custom interactive pop doesn't scrub this
        // flag; see MapsViewController. The two never share a pushed VC.)
        feedViewController.hidesBottomBarWhenPushed = true
        return feedViewController
    }
}
