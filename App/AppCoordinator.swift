import Auth
import AuthInterface
import CoreNavigation
import CoreNetworkingMocks
import CoreRealtime
import DesignSystem
import FeedInterface
import UIKit
import Upload
import UploadInterface

/// Root coordinator. Owns the window and the top-level state machine:
/// launching → auth → main. It is the single observer that turns
/// `AuthSessionProviding.stateUpdates()` into root view controller swaps;
/// nothing else in the app touches the window.
final class AppCoordinator: Coordinator {

    var childCoordinators: [Coordinator] = []

    private let window: UIWindow
    private let container: AppContainer
    private var stateObservation: Task<Void, Never>?

    init(window: UIWindow, container: AppContainer) {
        self.window = window
        self.container = container
    }

    func start() {
        window.rootViewController = LaunchViewController()
        window.makeKeyAndVisible()

        stateObservation = Task { [weak self] in
            guard let sessionManager = self?.container.sessionManager else { return }
            for await state in await sessionManager.stateUpdates() {
                self?.render(state)
            }
        }

        #if DEBUG
        // Dev convenience: `-mock-auto-login` signs into the mock BFF fixture
        // account, skipping the login form on every run/screenshot cycle.
        // Logout first: a keychain session persisted from a previous run is
        // always stale against the fresh in-process mock BFF.
        if ProcessInfo.processInfo.arguments.contains("-mock-auto-login") {
            let sessionManager = container.sessionManager
            let credentials = container.environment.demoCredentials
            let composeDemo = ProcessInfo.processInfo.arguments.contains("-mock-compose-demo")
            let composer = container.postComposer
            Task {
                await sessionManager.logout()
                try? await sessionManager.login(
                    username: credentials.username,
                    password: credentials.password
                )
                // Exercises the real upload+create+publish flow so the compose
                // wiring is verifiable without driving the photo picker UI.
                if composeDemo {
                    try? await Task.sleep(for: .seconds(2))
                    try? await composer.publish(
                        image: PickedImage(Self.demoImage()),
                        caption: "Shipped M4: photo upload + compose 🚀"
                    )
                }
            }
        }
        #endif
    }

    deinit {
        stateObservation?.cancel()
    }

    #if DEBUG
    /// A recognizable gradient stand-in for a picked photo (portrait 3:4).
    private static func demoImage() -> UIImage {
        let size = CGSize(width: 1080, height: 1440)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
    }
    #endif

    private func render(_ state: AuthState) {
        switch state {
        case .unauthenticated:
            let realtimeClient = container.realtimeClient
            Task { await realtimeClient.stop() }
            setRoot(container.authFeature.makeLoginViewController())
        case .authenticated:
            let realtimeClient = container.realtimeClient
            Task { await realtimeClient.start() }
            #if DEBUG
            if container.environment == .mock {
                container.startMockRealtimeDemo()
            }
            #endif
            let sessionManager = container.sessionManager
            let feedViewController = container.feedFeature.makeFeedViewController()
            let navigationController = UINavigationController(rootViewController: feedViewController)
            // Compose entry point (a tab bar's "+" until we build one).
            feedViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .compose,
                primaryAction: UIAction { [weak self, weak navigationController] _ in
                    guard let self, let navigationController else { return }
                    let composeVC = self.container.uploadFeature.makeComposeViewController()
                    navigationController.present(composeVC, animated: true)
                }
            )
            // Temporary home for logout until the profile tab exists.
            feedViewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Log Out",
                primaryAction: UIAction { _ in Task { await sessionManager.logout() } }
            )
            setRoot(navigationController)
        }
    }

    private func setRoot(_ viewController: UIViewController) {
        guard window.rootViewController != nil, !(window.rootViewController is LaunchViewController) else {
            window.rootViewController = viewController
            return
        }
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
            self.window.rootViewController = viewController
        }
    }
}

/// Shown only for the instant between scene connection and the first auth
/// state emission (a local keychain read).
private final class LaunchViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
    }
}
