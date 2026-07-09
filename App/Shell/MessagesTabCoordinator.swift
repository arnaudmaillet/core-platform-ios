import ChatInterface
import CoreNavigation
import UIKit

/// Owns the Messages tab: the conversation list, promoted from a sub-screen of
/// the feed to a primary root tab. Reuses the existing Chat feature; threads
/// still open by pushing onto this tab's stack (or the current one, via routes).
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
        let conversationList = container.chatFeature.makeConversationListViewController()
        navigationController.viewControllers = [conversationList]
    }
}
