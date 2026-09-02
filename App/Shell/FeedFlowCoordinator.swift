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

    /// Swipe-right-to-pop, the timeline counterpart of the pin feed's grab.
    /// One instance for the one retained feed; re-installed on the target
    /// stack at every push.
    private let slideDismissal = InteractiveSlideDismissal()

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
        // Accessing `view` loads it so the swipe-to-pop pan can attach (a
        // no-op after the first push); the delegate slot is taken per push
        // and handed back when the feed leaves this stack.
        slideDismissal.attach(to: feed, axes: [.horizontal, .vertical])
        slideDismissal.onFeedPopped = { [weak self] nav in self?.restoreTabBar(on: nav) }
        slideDismissal.install(on: navigationController)
        // Tab bar managed by hand, NOT hidesBottomBarWhenPushed: that flag's
        // bottom-bar choreography doesn't scrub with a custom interactive pop
        // (verified here too: the bar snapped in fully rendered at pop-begin,
        // over the feed's caption). Same cure as the pin path: hide with the
        // push, keep hidden through cancelled swipes, restore on the
        // completed pop (`restoreTabBar`) and on tab switches
        // (`MainTabCoordinator.syncTabBarVisibility`).
        navigationController.tabBarController?.setTabBarHidden(true, animated: true)
        navigationController.pushViewController(feed, animated: true)
    }

    /// Completed pops only (a cancelled swipe never gets here): bring the bar
    /// back — unless the pop revealed another full-bleed snap surface (the
    /// timeline was deep-linked above a pin-opened feed), whose own mechanic
    /// owns the bar, or the feed is already on its way onto another stack
    /// (the relocation path re-hides immediately; don't flash it in between).
    ///
    /// ⚠️ "Full-bleed snap surface" is asked as `concealsAppTabBar` and not as
    /// conformance to the zoom protocol. The two were the same answer until the
    /// place page conformed in order to fly its own dismissal home to the map
    /// while showing the bar exactly like any other pushed screen — at which
    /// point the old proxy started refusing the restore over a screen that
    /// never owned the bar in the first place.
    private func restoreTabBar(on navigationController: UINavigationController) {
        let top = navigationController.topViewController
        guard feedViewController.navigationController == nil,
              (top as? any ZoomTransitionDestination)?.concealsAppTabBar != true
        else { return }
        navigationController.tabBarController?.setTabBarHidden(false, animated: true)
    }

    private func makeFeedViewController() -> UIViewController {
        // No hidesBottomBarWhenPushed: the bar is managed by hand (see
        // `push(on:)`) so the interactive swipe-to-pop scrubs cleanly, exactly
        // like the pin path.
        container.feedFeature.makeFeedViewController()
    }

    #if DEBUG
    /// `-feed-swipe-demo` (see `MainTabCoordinator`): one swipe below the
    /// completion threshold (springs back), then one past it (pops) — the
    /// exact begin/update/release path a finger drives.
    func debugScriptedSwipe() {
        Task { @MainActor [slideDismissal] in
            await slideDismissal.debugPerformSwipe(peakProgress: 0.22)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await slideDismissal.debugPerformSwipe(peakProgress: 0.55)
        }
    }
    #endif
}
