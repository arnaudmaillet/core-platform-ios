import DesignSystem
import UIKit

/// Puts `AppLockViewController` over the app when App Lock asks for it
/// (Settings → Security and Login → App Lock, #418), driven by the scene's
/// lifecycle:
///
/// - **launch**: locked straight away when App Lock is on;
/// - **background**: the lock covers the app at once, so the app switcher's
///   snapshot shows the lock, not the feed or a conversation;
/// - **foreground**: the cover stays if the viewer was away at least the
///   chosen delay, and comes off otherwise;
/// - **active**: the lock asks for Face ID / the passcode once on its own
///   (iOS refuses a prompt raised while the app is still in the background).
///
/// The cover is its own window above everything — alerts and sheets
/// included — so nothing the app presents can sit on top of it.
@MainActor
final class AppLockCoordinator {
    private let scene: UIWindowScene
    private let mainWindow: UIWindow
    private let authenticator: any DeviceAuthenticating
    private let now: () -> Date
    private var lockWindow: UIWindow?
    private var backgroundedAt: Date?

    init(
        scene: UIWindowScene,
        mainWindow: UIWindow,
        authenticator: any DeviceAuthenticating = DeviceAuthenticator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.scene = scene
        self.mainWindow = mainWindow
        self.authenticator = authenticator
        self.now = now
    }

    var isLocked: Bool { lockWindow != nil }

    func sceneDidConnect() {
        if AppLockPreference.shouldLock(isOn: AppLockPreference.isOn, backgroundedAt: nil, now: now(), delay: AppLockPreference.delay) {
            showLock()
        }
    }

    func sceneDidEnterBackground() {
        backgroundedAt = now()
        if AppLockPreference.isOn { showLock() }
    }

    func sceneWillEnterForeground() {
        let mustLock = AppLockPreference.shouldLock(
            isOn: AppLockPreference.isOn, backgroundedAt: backgroundedAt, now: now(), delay: AppLockPreference.delay
        )
        backgroundedAt = nil
        if !mustLock { hideLock() }
    }

    func sceneDidBecomeActive() {
        (lockWindow?.rootViewController as? AppLockViewController)?.promptIfNeeded()
    }

    private func showLock() {
        guard lockWindow == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = mainWindow.overrideUserInterfaceStyle
        window.rootViewController = AppLockViewController(authenticator: authenticator) { [weak self] in
            self?.hideLock()
        }
        window.makeKeyAndVisible()
        lockWindow = window
    }

    private func hideLock() {
        guard let window = lockWindow else { return }
        window.isHidden = true
        lockWindow = nil
        mainWindow.makeKey()
    }
}
