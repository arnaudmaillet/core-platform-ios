import ChatInterface
import CoreNavigation
import UIKit

/// Owns the Messages tab: the paged inbox (All / Requests / Suggestions),
/// promoted from a sub-screen of the feed to a primary root tab. Threads open
/// by pushing onto this tab's stack (or the current one, via routes).
@MainActor
final class MessagesTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    private(set) lazy var tab = UITab(
        title: "Messages",
        image: UIImage(systemName: "message"),
        identifier: AppTab.messages.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        // The inbox reports every tab's badge summed; the bar item wears it.
        // Nothing here counts anything — see
        // `MessagesInboxViewController.onTotalNewCountChange` for why the sum
        // is published from where its parts already are.
        let inbox = container.chatFeature.makeInboxViewController { [weak self] total in
            self?.tab.badgeValue = total > 0 ? String(total) : nil
        }
        navigationController.viewControllers = [inbox]
    }
}
