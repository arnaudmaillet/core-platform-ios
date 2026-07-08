import Auth
import AuthInterface
import CoreModels
import CoreNavigation
import CoreRealtime
import DesignSystem
import MediaPlayback
import UIKit
import Upload

/// Root coordinator. Owns the window and the top-level state machine:
/// launching → auth → main. It is the single observer that turns
/// `AuthSessionProviding.stateUpdates()` into root view controller swaps;
/// nothing else in the app touches the window.
final class AppCoordinator: Coordinator {

    var childCoordinators: [Coordinator] = []

    private let window: UIWindow
    private let container: AppContainer
    private var stateObservation: Task<Void, Never>?
    private var mainTabCoordinator: MainTabCoordinator?

    init(window: UIWindow, container: AppContainer) {
        self.window = window
        self.container = container
    }

    func start() {
        window.rootViewController = LaunchViewController()
        window.makeKeyAndVisible()

        stateObservation = Task { [weak self] in
            guard let container = self?.container else { return }
            let realtimeClient = container.realtimeClient
            for await state in await container.sessionManager.stateUpdates() {
                self?.render(state)
                // Realtime lifecycle is driven here, in auth-state order, rather
                // than via detached Tasks in render() — otherwise a rapid
                // logout→login (e.g. auto-login) races start/stop and can leave
                // the client stopped.
                switch state {
                case .authenticated: await realtimeClient.start()
                case .unauthenticated: await realtimeClient.stop()
                }
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
            let composeVideoDemo = ProcessInfo.processInfo.arguments.contains("-mock-compose-video-demo")
            let composer = container.postComposer
            Task {
                await sessionManager.logout()
                try? await sessionManager.login(
                    username: credentials.username,
                    password: credentials.password
                )
                // Exercises the real upload+create+publish flow so the compose
                // wiring is verifiable without driving the picker UI.
                if composeDemo {
                    try? await Task.sleep(for: .seconds(2))
                    try? await composer.publish(
                        media: .image(PickedImage(Self.demoImage())),
                        caption: "Shipped M4: photo upload + compose 🚀"
                    )
                }
                // Same, for the video path: synthesize a source clip and run it
                // through export → upload → publish → optimistic local playback.
                if composeVideoDemo {
                    try? await Task.sleep(for: .seconds(2))
                    if let source = try? await PlaceholderVideoFetcher()
                        .playableURL(for: URL(string: "mock://video/demo?w=720&h=1280")!) {
                        try? await composer.publish(
                            media: .video(PickedVideo(sourceURL: source)),
                            caption: "My first video post 🎬"
                        )
                    }
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
            mainTabCoordinator = nil
            setRoot(container.authFeature.makeLoginViewController())
        case .authenticated:
            #if DEBUG
            if container.environment == .mock {
                container.startMockRealtimeDemo()
            }
            #endif
            let sessionManager = container.sessionManager
            let tabCoordinator = MainTabCoordinator(
                container: container,
                onLogout: { Task { await sessionManager.logout() } }
            )
            tabCoordinator.start()
            // Routes now resolve against this shell; the resolver holds it
            // weakly, so logout (which drops the coordinator) stops routing.
            container.routeResolver.navigator = tabCoordinator
            mainTabCoordinator = tabCoordinator
            setRoot(tabCoordinator.tabBarController)

            #if DEBUG
            // Dev convenience: `-open-profile <id>` fires a profile route once
            // the shell is up — the same code path universal links and taps use
            // — so cross-tab routing is testable without driving the UI.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-open-profile"), index + 1 < arguments.count {
                container.router.route(to: .profile(ProfileID(arguments[index + 1])))
            }
            if let index = arguments.firstIndex(of: "-open-post"), index + 1 < arguments.count {
                container.router.route(to: .post(PostID(arguments[index + 1])))
            }
            if let index = arguments.firstIndex(of: "-open-conversation"), index + 1 < arguments.count {
                container.router.route(to: .conversation(ConversationID(arguments[index + 1])))
            }
            if let index = arguments.firstIndex(of: "-message-user"), index + 1 < arguments.count {
                container.router.route(to: .messageUser(ProfileID(arguments[index + 1])))
            }
            #endif
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
