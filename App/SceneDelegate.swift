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

        let window = UIWindow(windowScene: windowScene)
        self.window = window

        #if DEBUG
        // `-native-zoom-spike`: replaces the app entirely with the issue #83
        // Step 1 evaluation of UIKit's system zoom transition. It owns the whole
        // window so it needs no login, no mock BFF and no grid.
        if ProcessInfo.processInfo.arguments.contains(NativeZoomSpike.launchArgument) {
            window.rootViewController = NativeZoomSpike.makeRoot()
            window.makeKeyAndVisible()
            return
        }
        #endif

        let coordinator = AppCoordinator(window: window, container: AppContainer.shared)
        appCoordinator = coordinator
        coordinator.start()
    }
}
