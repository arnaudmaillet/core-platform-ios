import ChatInterface
import CoreNavigation
import FeedInterface
import UIKit
import UploadInterface

/// Owns the Feed tab: the timeline plus the compose entry point.
@MainActor
final class FeedTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let feedViewController = container.feedFeature.makeFeedViewController()
        feedViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .compose,
            primaryAction: UIAction { [weak self] _ in self?.presentCompose() }
        )
        feedViewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "paperplane"),
            primaryAction: UIAction { [weak self] _ in self?.showMessages() }
        )
        navigationController.viewControllers = [feedViewController]
        // The feed VC sets its own title ("Timeline"), which UIKit proxies onto
        // the tab bar item; match it here so the tab reads consistently.
        navigationController.tabBarItem = UITabBarItem(
            title: "Timeline",
            image: UIImage(systemName: "house"),
            selectedImage: UIImage(systemName: "house.fill")
        )

        #if DEBUG
        // Dev convenience: `-open-messages` pushes the conversation list on
        // launch, for testing chat without tapping.
        if ProcessInfo.processInfo.arguments.contains("-open-messages") {
            showMessages()
        }
        #endif
    }

    private func presentCompose() {
        let composeViewController = container.uploadFeature.makeComposeViewController()
        navigationController.present(composeViewController, animated: true)
    }

    private func showMessages() {
        let conversationList = container.chatFeature.makeConversationListViewController()
        navigationController.pushViewController(conversationList, animated: true)
    }
}
