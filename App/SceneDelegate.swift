#if DEBUG
import CoreNavigation
import CoreNetworkingMocks
#endif
import DebugTools
import DesignSystem
import MediaCore
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var appCoordinator: AppCoordinator?
    /// Offline / Back online above every screen (#793).
    private var offlineIndicator: OfflineIndicator?
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
        LaunchTimeline.mark("scene.connect")

        // Before the first controller exists, so the launch screen's own lists
        // obey it too — an appearance default only reaches views created after
        // it is set.
        ScrollIndicatorStyle.hideAppWide()

        #if DEBUG
        // Shake for the debug dashboard (#2131, #2132; the mock network's
        // switch of #790 is one of its sections). `-debug-dashboard` opens it
        // at launch, for the simulator.
        let shakeWindow = DebugShakeWindow(windowScene: windowScene)
        DebugDashboardWiring.install(container: AppContainer.shared)
        shakeWindow.onShake = { [weak windowScene] in
            guard let windowScene else { return }
            DebugDashboardWiring.handleShake(in: windowScene)
        }
        if ProcessInfo.processInfo.arguments.contains("-debug-dashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak windowScene] in
                DebugDashboard.present(in: windowScene)
            }
        }
        let window: UIWindow = shakeWindow
        #else
        // An `AppWindow`: it carries the bar tap shield — taps in a bar's area
        // never reach the content under it; pans still scroll it (#562, #1145).
        let window = AppWindow(windowScene: windowScene)
        #endif
        // The brand's pink (#1169): every system control and every
        // `.tintColor` read follows it. The asset catalog's AccentColor carries
        // the same values for what the window does not reach.
        window.tintColor = Palette.tint
        // Endless decoration rests once nobody has touched the app for a
        // while, and wakes on the next touch (#580). `-idle-calm-off` keeps it
        // moving for QA that watches an animation without touching.
        var restsWhenIdle = true
        #if DEBUG
        restsWhenIdle = !DebugFlags.isOn("-idle-calm-off")
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

        // Offline / Back online, above every screen (#793).
        AppContainer.shared.startConnectivityMonitoring()
        AppContainer.shared.startSavedPostsSync()
        AppContainer.shared.startWalletServerSync()
        offlineIndicator = OfflineIndicator.install(on: window)

        let coordinator = AppCoordinator(window: window, container: AppContainer.shared)
        appCoordinator = coordinator
        coordinator.start()
        // Launched by a link (#524): a `wynn:` URL, or a universal link on
        // `core-platform.click`. The coordinator holds it until the shell is up.
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
        // A supervised teen's time is reported too, and a reached limit
        // shows a pause screen (#417).
        let shared = AppContainer.shared
        screenTime = ScreenTimeCoordinator(
            scene: windowScene, mainWindow: window,
            supervised: shared.supervisedScreenTime,
            limitSetter: { await shared.supervisedLimitSetter() }
        )
    }

    /// A `wynn:` link opened while the app runs.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        appCoordinator?.open(url)
    }

    /// A universal link on `core-platform.click` opened while the app runs.
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
