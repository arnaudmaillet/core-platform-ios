import UIKit

/// Process-level lifecycle only: launch, push registration, background tasks.
/// All UI lives behind the SceneDelegate → AppCoordinator chain.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG
        // ⚠️ UNBUFFERED STDOUT, so a run can be captured to a FILE.
        //
        // `print` is line-buffered on a terminal and block-buffered on anything
        // else, so `simctl launch --stdout=<file>` produces an empty file until
        // 4KB accumulates or the process exits — and a session being watched is
        // neither. The alternative, `--console-pty`, ties the app's life to the
        // watching process: when that one is killed the app dies with it, which
        // has now cost two capture sessions mid-investigation.
        //
        // Gated on the trace flags rather than on DEBUG alone: unbuffering
        // costs a write syscall per line, which is nothing next to a trace and
        // not nothing next to a tight loop that is not being traced.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("-log") }) {
            setvbuf(stdout, nil, _IONBF, 0)
        }
        #endif
        AppContainer.configureEmotes()
        // Before returning: a tap on a notification that launched the app is
        // delivered to the delegate this installs (#651).
        AppContainer.shared.pushNotifications.start()
        return true
    }

    // MARK: Push registration (#651)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppContainer.shared.pushNotifications.didRegister(deviceToken: deviceToken)
    }

    /// No token: no `aps-environment` entitlement (a free-team device build),
    /// or no network. Nothing to register; the next launch asks again.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[push] registration failed: \(error.localizedDescription)")
        #endif
    }

    // MARK: UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
