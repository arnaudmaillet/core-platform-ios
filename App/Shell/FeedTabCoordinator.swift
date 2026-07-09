import CoreNavigation
import DesignSystem
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
        // The snap feed is immersive (it hides the nav bar itself), so compose
        // lives as an overlay control. Messages moved to its own root tab.
        installSnapOverlayControls(on: feedViewController)
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

    /// Floating compose button for the immersive snap feed, pinned top-trailing
    /// inside the safe area. It lives on the feed VC's own view, so a pushed
    /// screen (profile, post detail) naturally covers it.
    private func installSnapOverlayControls(on feedViewController: UIViewController) {
        let compose = Self.overlayButton(symbol: "square.and.pencil") { [weak self] in self?.presentCompose() }
        compose.constrain(in: feedViewController.view) { parent in
            compose.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
            compose.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.lg)
        }
    }

    private static func overlayButton(symbol: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.baseForegroundColor = .white
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        // A soft shadow keeps the glyph legible over bright media.
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.5
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = .zero
        return button
    }

    private func presentCompose() {
        let composeViewController = container.uploadFeature.makeComposeViewController()
        navigationController.present(composeViewController, animated: true)
    }
}
