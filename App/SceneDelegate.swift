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
        // Taps in a bar's area never reach the content under it; pans still
        // scroll it (#562).
        window.addGestureRecognizer(BarTapShield())
        // Endless decoration rests once nobody has touched the app for a
        // while, and wakes on the next touch (#580). `-idle-calm-off` keeps it
        // moving for QA that watches an animation without touching.
        var restsWhenIdle = true
        #if DEBUG
        restsWhenIdle = !ProcessInfo.processInfo.arguments.contains("-idle-calm-off")
        #endif
        if restsWhenIdle {
            IdleCalmMonitor.shared.install(on: window)
        }
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
        // Launched by a link (#524): a `wynn:` URL, or a universal link on
        // `wynn.cn`. The coordinator holds it until the shell is up.
        if let url = connectionOptions.urlContexts.first?.url {
            coordinator.open(url)
        } else if let url = connectionOptions.userActivities
            .first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?.webpageURL {
            coordinator.open(url)
        }

        let lock = AppLockCoordinator(scene: windowScene, mainWindow: window)
        appLock = lock
        lock.sceneDidConnect()

        #if DEBUG
        ScreenTimeCoordinator.applyDebugSeed()
        #endif
        screenTime = ScreenTimeCoordinator(scene: windowScene, mainWindow: window)
    }

    /// A `wynn:` link opened while the app runs.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        appCoordinator?.open(url)
    }

    /// A universal link on `wynn.cn` opened while the app runs.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        appCoordinator?.open(url)
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
