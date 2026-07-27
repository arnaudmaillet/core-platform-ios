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
    #if DEBUG
    /// Latches the launch-argument deep links to one application per process.
    private var hasAppliedLaunchArguments = false
    #endif

    init(window: UIWindow, container: AppContainer) {
        self.window = window
        self.container = container
    }

    func start() {
        window.rootViewController = LaunchViewController()
        window.makeKeyAndVisible()

        #if DEBUG
        // Dev convenience: `-mock-auto-login` signs into the mock BFF fixture
        // account, skipping the login form on every run/screenshot cycle. It
        // owns the whole startup sequence, because WHEN the observation starts
        // decides how many shells get built — see `startWithMockAutoLogin`.
        if ProcessInfo.processInfo.arguments.contains("-mock-auto-login") {
            startWithMockAutoLogin()
            return
        }
        #endif

        observeAuthState()
    }

    /// Subscribes to the auth-state stream and renders every state it carries.
    ///
    /// `stateUpdates()` yields the CURRENT state on subscribe and then each
    /// change, so the moment this is called is itself a decision about what gets
    /// rendered — not merely when.
    private func observeAuthState() {
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
    }

    #if DEBUG
    /// Signs into the mock BFF fixture account, then starts observing.
    ///
    /// **The order is the point.** Logout has to come first — a keychain session
    /// persisted from a previous run is always stale against the fresh
    /// in-process mock BFF — and observing before it produced
    /// `.authenticated` → `.unauthenticated` → `.authenticated`: the app built
    /// an ENTIRE tab shell for the stale session, tore it down, and built a
    /// second one. Two authenticated renders meant the launch-argument deep
    /// links below fired twice and pushed two identical screens, which made
    /// every transition recording unreadable (a pop revealed the duplicate
    /// underneath and read as the pop reverting).
    ///
    /// Subscribing after the login resolves collapses that to a single render:
    /// `stateUpdates()` replays the current state on subscribe, so nothing is
    /// missed by arriving late, and the launch screen stays up for the round
    /// trip instead of flashing the login form on the way past.
    private func startWithMockAutoLogin() {
        let sessionManager = container.sessionManager
        let credentials = container.environment.demoCredentials
        let composeDemo = ProcessInfo.processInfo.arguments.contains("-mock-compose-demo")
        let composeVideoDemo = ProcessInfo.processInfo.arguments.contains("-mock-compose-video-demo")
        let composer = container.postComposer
        Task { [weak self] in
            await sessionManager.logout()
            try? await sessionManager.login(
                username: credentials.username,
                password: credentials.password
            )
            self?.observeAuthState()
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
            // Launch arguments describe how this PROCESS was started, so they
            // are applied once and never replayed — a mid-session logout→login
            // builds a second shell, and re-firing the original deep links into
            // it would push screens the user never asked for.
            guard !hasAppliedLaunchArguments else { return }
            hasAppliedLaunchArguments = true

            // Dev convenience: `-open-profile <id>` fires a profile route once
            // the shell is up — the same code path universal links and taps use
            // — so cross-tab routing is testable without driving the UI.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-open-profile"), index + 1 < arguments.count {
                container.router.route(to: .profile(ProfileID(arguments[index + 1]), stub: nil))
            }
            // `-open-profile-delayed <id> [seconds]` fires the same route
            // after a delay (default ~3s — after `-select-tab 1` has pushed
            // the feed), so a profile ABOVE the feed's custom nav delegate
            // is reachable without driving a cell tap (the swipe-back-over-
            // feed regression surface). The optional seconds lets the route
            // land after slower setups — e.g. `-snap-comments-demo`'s
            // engagement, for the engaged-outbound-push handoff surface.
            if let index = arguments.firstIndex(of: "-open-profile-delayed"), index + 1 < arguments.count {
                let id = ProfileID(arguments[index + 1])
                let delay = (index + 2 < arguments.count ? Double(arguments[index + 2]) : nil) ?? 3.0
                let router = container.router
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    router.route(to: .profile(id, stub: nil))
                }
            }
            // `-open-profile-stubbed <id> <handle> <name>` fires the same route
            // WITH an identity stub — the feed-origin path — so the pre-seeded
            // navigation chrome is verifiable without driving a cell tap.
            if let index = arguments.firstIndex(of: "-open-profile-stubbed"), index + 3 < arguments.count {
                container.router.route(to: .profile(
                    ProfileID(arguments[index + 1]),
                    stub: ProfileIdentityStub(handle: arguments[index + 2], displayName: arguments[index + 3])
                ))
            }
            if let index = arguments.firstIndex(of: "-open-post"), index + 1 < arguments.count {
                container.router.route(to: .post(PostID(arguments[index + 1])))
            }
            if let index = arguments.firstIndex(of: "-open-comments"), index + 1 < arguments.count {
                container.router.route(to: .comments(PostID(arguments[index + 1])))
            }
            // `-open-messages [all|requests|suggestions]` selects the Messages
            // root tab on launch and pages the inbox to a category — swipes
            // can't be injected in-sim, so this is how the Requests and
            // Suggestions surfaces are reachable for verification.
            if let index = arguments.firstIndex(of: "-open-messages") {
                let category = (index + 1 < arguments.count ? MessagesCategory(rawValue: arguments[index + 1]) : nil) ?? .all
                container.router.route(to: .messages(category))
            }
            if let index = arguments.firstIndex(of: "-open-conversation"), index + 1 < arguments.count {
                container.router.route(to: .conversation(ConversationID(arguments[index + 1])))
            }
            // `-open-conversation-settled <id>` fires the same route ~2s in —
            // after the Messages list has loaded — reproducing the tap-a-row
            // path (warm identity directory, header present during the push),
            // where the immediate variant above is a cold deep link.
            if let index = arguments.firstIndex(of: "-open-conversation-settled"), index + 1 < arguments.count {
                let id = ConversationID(arguments[index + 1])
                let router = container.router
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    router.route(to: .conversation(id))
                }
            }
            if let index = arguments.firstIndex(of: "-message-user"), index + 1 < arguments.count {
                container.router.route(to: .messageUser(ProfileID(arguments[index + 1]), stub: nil))
            }
            // `-new-message` opens the compose picker on the Messages tab ~2s
            // in — after the inbox has loaded, so the Recent section actually
            // has rows (it reads the catalog, and an empty catalog looks like
            // an empty feature). Pair with `-new-message-query <text>`, read by
            // the picker itself, to land straight in the search state.
            if arguments.contains("-new-message") {
                container.router.route(to: .messages(.all))
                let router = container.router
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    router.route(to: .newMessage)
                }
            }
            // `-auto-pop` pops the active stack ~2.5s after launch — pairs with
            // the `-open-*` args above to verify pop-side behavior (nav chrome,
            // tab bar restoration) since taps can't be injected in-sim.
            if arguments.contains("-auto-pop") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak tabCoordinator] in
                    tabCoordinator?.activeNavigationController?.popViewController(animated: true)
                }
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
/// state emission (a local keychain read) — or, under `-mock-auto-login`, for
/// the fixture login round trip, which it covers rather than flashing the login
/// form on the way past.
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
