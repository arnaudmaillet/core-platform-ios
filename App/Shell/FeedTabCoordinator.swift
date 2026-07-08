import ChatInterface
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

    init(container: AppContainer) {
        self.container = container
    }

    func start() {
        let feedViewController = container.feedFeature.makeFeedViewController()
        switch container.feedPresentation {
        case .classic:
            feedViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .compose,
                primaryAction: UIAction { [weak self] _ in self?.presentCompose() }
            )
            feedViewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "paperplane"),
                primaryAction: UIAction { [weak self] _ in self?.showMessages() }
            )
        case .snap:
            // The snap feed is immersive (it hides the nav bar itself), so the
            // compose and messages actions live as overlay controls instead.
            installSnapOverlayControls(on: feedViewController)
        }
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

    /// Floating compose + messages buttons for the immersive snap feed, pinned
    /// top-trailing inside the safe area. They live on the feed VC's own view,
    /// so a pushed screen (profile, post detail) naturally covers them.
    private func installSnapOverlayControls(on feedViewController: UIViewController) {
        let messages = Self.overlayButton(symbol: "paperplane") { [weak self] in self?.showMessages() }
        let compose = Self.overlayButton(symbol: "square.and.pencil") { [weak self] in self?.presentCompose() }
        let stack = UIStackView(arrangedSubviews: [messages, compose])
        stack.axis = .horizontal
        stack.spacing = Spacing.md
        stack.constrain(in: feedViewController.view) { parent in
            stack.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
            stack.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.lg)
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

    private func showMessages() {
        let conversationList = container.chatFeature.makeConversationListViewController()
        navigationController.pushViewController(conversationList, animated: true)
    }
}
