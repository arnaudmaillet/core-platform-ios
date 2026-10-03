import Auth
import AuthInterface
import CoreModels
import CoreNavigation
import CoreRealtime
import DesignSystem
import MediaPlayback
import UIKit
import Upload
#if DEBUG
import ChatInterface
#endif

/// Root coordinator. Owns the window and the top-level state machine:
/// launching → shell. It is the single observer of
/// `AuthSessionProviding.stateUpdates()`; nothing else in the app touches the
/// window.
///
/// ⚠️ **THE SHELL NO LONGER WAITS FOR AN ACCOUNT** (guest mode, #438). The
/// first auth state builds it whatever that state is, and later states only
/// tell it who the viewer is now: a sign-out returns to guest browsing in the
/// same shell, and a sign-in — made from the sheet a guest opened — keeps
/// whatever screen they were on. The login screen is never the window's root.
final class AppCoordinator: Coordinator {

    var childCoordinators: [Coordinator] = []

    private let window: UIWindow
    private let container: AppContainer
    private var stateObservation: Task<Void, Never>?
    private var mainTabCoordinator: MainTabCoordinator?
    /// The sign-in flow a guest opened, presented over the shell; dismissed
    /// when the session lands.
    private weak var presentedSignIn: UIViewController?
    #if DEBUG
    /// Latches the launch-argument deep links to one application per process.
    private var hasAppliedLaunchArguments = false
    #endif

    init(window: UIWindow, container: AppContainer) {
        self.window = window
        self.container = container
    }

    func start() {
        #if DEBUG
        // `-first-layout-trace`: names the animation block that captures a
        // screen's first layout (the "unfolds from the top-left" defect).
        // Installed before the first root so the launch swap is covered too.
        FirstLayoutTrace.installIfRequested()
        // `-presentation-budget`: times the run-loop turn that brings each
        // screen on and names the frames it spent it in (charter P2).
        PresentationBudget.installIfRequested()
        #endif
        window.rootViewController = LaunchViewController()
        window.makeKeyAndVisible()
        // The blur behind the status bar, on every screen and through every
        // transition: one band in the window, over everything the app draws —
        // see `StatusBarBlurView`. Root swaps replace the root's view only.
        StatusBarBlurView.install(in: window)
        #if DEBUG
        FirstLayoutTrace.selfTestIfRequested(in: window)
        // `-status-bar-blur-audit`: the band, every frame, and every blur
        // under it per screen.
        StatusBarBlurAudit.installIfRequested(in: window)
        #endif

        #if DEBUG
        // Dev convenience: `-mock-auto-login` signs into the mock BFF fixture
        // account, skipping the login form on every run/screenshot cycle. It
        // owns the whole startup sequence, because WHEN the observation starts
        // decides how many shells get built — see `startWithMockAutoLogin`.
        if ProcessInfo.processInfo.arguments.contains("-mock-auto-login") {
            startWithMockAutoLogin()
            return
        }
        // `-guest`: signs out first, so the run starts as a fresh install's
        // first launch would — browsing with no account.
        if ProcessInfo.processInfo.arguments.contains("-guest") {
            let sessionManager = container.sessionManager
            Task { [weak self] in
                await sessionManager.logout()
                self?.observeAuthState()
            }
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
        // Here, not in `start()`: under `-mock-auto-login` this runs after the
        // logout-then-login, which must not read as a change of viewer.
        container.observeViewerTransitions()
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
                _ = try? await composer.publish(
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
                    _ = try? await composer.publish(
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
        let isMember: Bool
        switch state {
        case .unauthenticated: isMember = false
        case .authenticated: isMember = true
        }
        guard let tabCoordinator = mainTabCoordinator else {
            showShell(isMember: isMember)
            if isMember { didSignIn() }
            return
        }
        tabCoordinator.viewerDidChange(isMember: isMember)
        if isMember { didSignIn() }
    }

    /// Builds the shell once, for whoever the first auth state says is here.
    private func showShell(isMember: Bool) {
        let sessionManager = container.sessionManager
        let tabCoordinator = MainTabCoordinator(
            container: container,
            isMember: isMember,
            onLogout: { Task { await sessionManager.logout() } },
            onSignIn: { [weak self] in self?.presentSignIn() }
        )
        tabCoordinator.start()
        // Routes resolve against this shell for the rest of the process.
        container.routeResolver.navigator = tabCoordinator
        mainTabCoordinator = tabCoordinator
        setRoot(tabCoordinator.rootViewController)
    }

    /// The sign-in flow, over whatever the guest is looking at. It is not the
    /// window's root any more, so it carries a close button.
    private func presentSignIn() {
        guard presentedSignIn == nil, let shell = mainTabCoordinator?.rootViewController else { return }
        var presenter = shell
        while let presented = presenter.presentedViewController { presenter = presented }
        let signIn = container.authFeature.makeSignInViewController { [weak self] in
            self?.presentedSignIn?.dismiss(animated: true)
        }
        presentedSignIn = signIn
        presenter.present(signIn, animated: true)
    }

    /// A session landed: put away the sign-in flow if a guest opened one, and
    /// start what only a member has.
    private func didSignIn() {
        presentedSignIn?.dismiss(animated: true)
        #if DEBUG
        // `-mock-likes-still`: no ticking like counts — so a refresh can
        // come back with exactly what it had (`-profile-stretch-sweep`'s
        // identical landing).
        if container.environment == .mock,
           !ProcessInfo.processInfo.arguments.contains("-mock-likes-still") {
            container.startMockRealtimeDemo()
        }
        #endif
        guard let tabCoordinator = mainTabCoordinator else { return }
        applyLaunchArguments(to: tabCoordinator)
    }

    private func applyLaunchArguments(to tabCoordinator: MainTabCoordinator) {
        #if DEBUG
        // Launch arguments describe how this PROCESS was started, so they
        // are applied once and never replayed — a mid-session logout→login
        // signs in again, and re-firing the original deep links would push
        // screens the user never asked for.
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
        // after a delay (default ~3s), so a profile ABOVE a pushed feed's
        // custom nav delegate is reachable without driving a cell tap (the
        // swipe-back-over-feed regression surface). The optional seconds
        // lets the route land after slower setups — e.g.
        // `-snap-comments-demo`'s engagement, for the engaged-outbound-push
        // handoff surface.
        //
        // ⚠️ `-select-tab 1` NO LONGER PUSHES A FEED. It indexes
        // `AppTab.allCases` (App/Shell/AppNavigating.swift), where 1 is the
        // For You TAB — it selects a root and pushes nothing. The default
        // 3 s used to be pegged to that push; now it is only a delay, and
        // a feed to land above has to be opened by something else (e.g.
        // a `-snap-*` / `-maps-open-*` hook), timed with the seconds knob.
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
        // `-open-foryou` selects the For You root tab on launch.
        //
        // Direct tab selection rather than a route, because there is no
        // `AppRoute` case for this tab — nothing in the app navigates TO
        // For You, it is where the viewer starts from. That leaves it the
        // one root tab a script could not reach, which is why its chrome
        // (the mode badges, the tab item the active mode renames) had no
        // way to be verified without a human tapping.
        if arguments.contains("-open-foryou") {
            tabCoordinator.selectTab(.forYou)
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
        //
        // ⚠️ "LOADED" IS NOW CHECKED, NOT ASSUMED. At a fixed 2 s a slow
        // boot or `-mock-latency` pushed the thread over a skeleton — the
        // cold path this flag exists to AVOID — and the run read as the
        // warm one. The 2 s stays as the earliest moment; the route then
        // waits for the inbox to be the active stack's root, on screen
        // with nothing pushed over it, with a list table showing rows —
        // and prints GAVE UP if it never is (pair with `-open-messages`
        // or `-select-tab 2`: from another tab there is no list to wait
        // for, and the push would not be the tap-a-row path anyway).
        if let index = arguments.firstIndex(of: "-open-conversation-settled"), index + 1 < arguments.count {
            let id = ConversationID(arguments[index + 1])
            let router = container.router
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak tabCoordinator] in
                QAWait.until("-open-conversation-settled \(id.rawValue): a loaded Messages list", {
                    guard let stack = tabCoordinator?.activeNavigationController,
                          let inbox = stack.viewControllers.first as? MessagesInboxCategorySelecting,
                          stack.topViewController === inbox,
                          stack.transitionCoordinator == nil,
                          let window = inbox.viewIfLoaded?.window else { return false }
                    // A list surface with rows actually on screen: its
                    // table is shown only once the skeleton is swapped
                    // for content, and the pager keeps its other pages
                    // off the window's bounds.
                    func hasVisibleRows(_ view: UIView) -> Bool {
                        if let table = view as? UITableView, !table.isHidden,
                           !table.visibleCells.isEmpty,
                           table.convert(table.bounds, to: window).intersects(window.bounds) {
                            return true
                        }
                        return view.subviews.contains { !$0.isHidden && hasVisibleRows($0) }
                    }
                    return hasVisibleRows(inbox.view)
                }) {
                    router.route(to: .conversation(id))
                }
            }
        }
        if let index = arguments.firstIndex(of: "-message-user"), index + 1 < arguments.count {
            container.router.route(to: .messageUser(ProfileID(arguments[index + 1]), stub: nil))
        }
        // `-auto-pop [seconds]` pops the active stack — pairs with
        // the `-open-*` args above to verify pop-side behavior (nav chrome,
        // tab bar restoration) since taps can't be injected in-sim.
        // ⚠️ The delay is a parameter because 2.5s is not always enough to
        // be ON the pushed screen long enough for it to DO anything. A
        // thread marks its conversation read once its messages have loaded;
        // popped half a second after being pushed it never gets that far,
        // and the list underneath looks unchanged for a reason that has
        // nothing to do with the code under test.
        if let index = arguments.firstIndex(of: "-auto-pop") {
            let delay = arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tabCoordinator] in
                tabCoordinator?.activeNavigationController?.popViewController(animated: true)
            }
        }
        #endif
    }

    private func setRoot(_ viewController: UIViewController) {
        guard window.rootViewController != nil, !(window.rootViewController is LaunchViewController) else {
            window.rootViewController = viewController
            return
        }
        // ⚠️ THE SWAP RUNS INSIDE `performWithoutAnimation`, for the reason
        // `UINavigationController.crossDissolve` states: a `UIView.transition`
        // block is an animation block, and the new root's first layout inside
        // it animates every subview from a zero frame — the whole shell
        // unfolding from the top-left corner behind the dissolve. The dissolve
        // is the container's transition and survives animations being disabled
        // for the block; the implicit frame animations do not. Laid out in the
        // same breath so nothing of the first pass is left for a later block.
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
            UIView.performWithoutAnimation {
                self.window.rootViewController = viewController
                self.window.layoutIfNeeded()
            }
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
