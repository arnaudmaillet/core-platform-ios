import DesignSystem
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var appCoordinator: AppCoordinator?
    /// Settings → Security and Login → App Lock (#418).
    private var appLock: AppLockCoordinator?
    /// Settings → Your Activity → Time Management (#489).
    private var screenTime: ScreenTimeCoordinator?

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
        // Settings → App and Device → Display: light, dark or following iOS.
        // Applied before the first frame so the app never flashes the other
        // style.
        AppearancePreference.apply(to: [window])
        // The app's text size (the iPhone's, capped at XXXL, raised by Care
        // Mode) and Care Mode's bold text, in place before the first frame.
        CareModePreference.apply(to: [window])

        let coordinator = AppCoordinator(window: window, container: AppContainer.shared)
        appCoordinator = coordinator
        coordinator.start()

        let lock = AppLockCoordinator(scene: windowScene, mainWindow: window)
        appLock = lock
        lock.sceneDidConnect()

        #if DEBUG
        ScreenTimeCoordinator.applyDebugSeed()
        #endif
        screenTime = ScreenTimeCoordinator(scene: windowScene, mainWindow: window)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        screenTime?.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        appLock?.sceneDidEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        appLock?.sceneWillEnterForeground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        appLock?.sceneDidBecomeActive()
        screenTime?.sceneDidBecomeActive()
    }
}
