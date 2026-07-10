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

    private(set) lazy var tab = UITab(
        title: "Feed",
        image: UIImage(systemName: "house"),
        identifier: AppTab.feed.rawValue
    ) { [navigationController] _ in navigationController }

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let feedViewController = container.feedFeature.makeFeedViewController()
        // The snap feed shows a transparent native bar (author identity in the
        // titleView), so compose is an ordinary bar item on the trailing edge.
        // White tint: the bar is transparent over full-bleed media.
        let compose = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { [weak self] _ in self?.presentCompose() }
        )
        compose.tintColor = .white
        feedViewController.navigationItem.rightBarButtonItem = compose
        navigationController.viewControllers = [feedViewController]

        #if DEBUG
        // `-present-compose` presents the compose sheet on launch, for
        // driving/screenshotting compose without tapping the overlay button.
        // Deferred: at start() the nav controller isn't in the window yet, so a
        // modal present would no-op.
        if ProcessInfo.processInfo.arguments.contains("-present-compose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.presentCompose()
            }
        }
        #endif
    }

    private func presentCompose() {
        let composeViewController = container.uploadFeature.makeComposeViewController()
        navigationController.present(composeViewController, animated: true)
    }
}
