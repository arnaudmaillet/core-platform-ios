import DesignSystem
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var appCoordinator: AppCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Before the first controller exists, so the launch screen's own lists
        // obey it too — an appearance default only reaches views created after
        // it is set.
        ScrollIndicatorStyle.hideAppWide()

        let window = UIWindow(windowScene: windowScene)
        self.window = window

        let coordinator = AppCoordinator(window: window, container: AppContainer.shared)
        appCoordinator = coordinator
        coordinator.start()
    }
}
