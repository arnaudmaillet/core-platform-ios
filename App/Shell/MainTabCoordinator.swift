import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit
#if DEBUG
import UploadInterface
#endif

/// The authenticated app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
///
/// Tabs are set via the modern `UITabBarController.tabs` API. The Search tab is
/// a `UISearchTab`, which the system detaches to the trailing edge, producing
/// the grouped bar `| Maps  For You  Messages  Profile |  Search |` natively.
///
/// Profile is a root tab, carrying the viewer's own avatar as its icon
/// (`ProfileTabCoordinator`) — it is the canonical entry point, so it is the one
/// place the settings gear, the profile switcher and Log Out belong. It replaced
/// the avatar button that used to sit in the Maps nav bar; the map header now
/// carries only the "+" and the notifications bell.
///
/// **Every bar button is now a tab.** Slot 1 used to be a vetoed Feed action
/// that pushed the timeline onto whatever tab you were on; it is now the For You
/// discovery grid (`ForYouTabCoordinator`), an ordinary root. The timeline did
/// not go away — a tile tap on that grid opens it seeded from the grid's own
/// order, and `AppRoute.feed` still pushes the open-ended one through
/// `FeedFlowCoordinator`. That coordinator is therefore still built and held
/// here even though nothing in the bar reaches it.
@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = ShellTabBarController()

    private let container: AppContainer
    private let onLogout: () -> Void
    /// The Notifications entry point: a plain bar item like the map's "+", tinted
    /// `.label` so it renders dark in the glass bubble (not system blue). The
    /// unread badge is a clean image swap — `bell` ↔ `bell.badge` (a red badge
    /// dot) — driven by `refreshUnreadBadge`, no custom view needed.
    private lazy var notificationsBarItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: Self.bellImage(unread: false),
            primaryAction: UIAction { [weak self] _ in self?.pushNotifications() }
        )
        item.tintColor = .label
        item.accessibilityLabel = "Notifications"
        return item
    }()

    /// The bell glyph for the current unread state. When unread, a palette
    /// `bell.badge` (bell in `.label`, badge in red) rendered `.alwaysOriginal`
    /// so the item's `.label` tint can't flatten the badge; otherwise a plain
    /// template `bell` that the tint draws dark. Both keep dynamic colors, so
    /// they adapt to light/dark on their own.
    private static func bellImage(unread: Bool) -> UIImage? {
        guard unread else { return UIImage(systemName: "bell") }
        let config = UIImage.SymbolConfiguration(paletteColors: [.label, .systemRed])
        return UIImage(systemName: "bell.badge", withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
    }
    private var feedFlow: FeedFlowCoordinator?
    /// The Profile root. Held so the viewer's avatar can be pushed onto its tab
    /// image as it loads, and again whenever the active profile changes.
    private var profileTab: ProfileTabCoordinator?
    /// Backs the Profile tab's long-press switcher menu.
    private lazy var profileSwitcher = container.profileFeature.makeProfileSwitcher()

    /// An invisible button laid over the Profile tab, carrying the switcher as
    /// its `menu`.
    ///
    /// **Why a control and not a `UIContextMenuInteraction`.** A context menu
    /// always LIFTS its source: it hides the original, floats a scaled copy and
    /// dims everything behind. On a tab that produced a second avatar hovering
    /// over the bar, clipped to whatever `visiblePath` allowed — an artifact
    /// with no place on fixed chrome, and one the interaction offers no way to
    /// switch off. Narrowing the path only makes the floating copy smaller.
    ///
    /// A `UIControl` presents the same `UIMenu` anchored to itself without any
    /// of that, which is exactly how the map avatar's `UIBarButtonItem.menu`
    /// behaved before Profile became a tab. Because this button is invisible and
    /// is a *different view* from the tab, UIKit never touches the real icon:
    /// not hidden, not snapshotted, not moved.
    ///
    /// Two properties, neither of them the default, are what make it long-press:
    /// `UIControl` ships with `isContextMenuInteractionEnabled == false`, so a
    /// `menu` alone is inert; and `showsMenuAsPrimaryAction` must stay FALSE, or
    /// the menu opens on tap and swallows tab selection.
    private lazy var profileMenuOverlay: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.isContextMenuInteractionEnabled = true
        button.showsMenuAsPrimaryAction = false
        button.accessibilityLabel = "Profile"
        button.accessibilityHint = "Double tap and hold to switch profile"
        // The overlay covers the real tab button, so a plain tap has to be
        // forwarded or it would be swallowed.
        button.addAction(UIAction { [weak self] _ in self?.selectTab(.profile) }, for: .primaryActionTriggered)
        return button
    }()
    /// The For You root. Held so its lens menu can be hung off a long press on
    /// the bar item, the way the Profile tab's switcher is.
    private var forYouTab: ForYouTabCoordinator?

    /// An invisible button laid over the For You tab, carrying the lens menu.
    ///
    /// Everything `profileMenuOverlay` documents applies here unchanged — a
    /// control rather than a `UIContextMenuInteraction` because the interaction
    /// LIFTS its source and would float a scaled copy of the tab icon over
    /// fixed chrome, `isContextMenuInteractionEnabled` on and
    /// `showsMenuAsPrimaryAction` off so the gesture is a long press and a
    /// plain tap still selects the tab.
    ///
    /// ⚠️ Its accessibility label is NOT fixed: this tab is renamed by whichever
    /// lens is active ("For You", "Work", "Focus"), and the button that finds it
    /// in the bar matches on that title — so the label is re-stated on every
    /// alignment pass rather than set once here.
    private lazy var forYouMenuOverlay: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.isContextMenuInteractionEnabled = true
        button.showsMenuAsPrimaryAction = false
        button.accessibilityHint = "Double tap and hold to choose what to see"
        button.addAction(UIAction { [weak self] _ in self?.selectTab(.forYou) }, for: .primaryActionTriggered)
        return button
    }()

    /// Tabs paired with their `AppTab`, in bar order — the lookup `selectTab`
    /// resolves against. Every bar button is in here now that the Feed action
    /// slot has become the For You root.
    private var orderedTabs: [(AppTab, any TabCoordinator)] = []
    /// One per tab stack: keeps the native edge-swipe pop working under the
    /// feed's custom transition delegates (see `NativePopGestureEnabler`).
    private var popGestureEnablers: [NativePopGestureEnabler] = []

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
        super.init()
    }

    func start() {
        // A switch broadcasts this; reload the avatar so the Profile tab's icon
        // reflects whoever is now active.
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeProfileChanged),
            name: .activeProfileDidChange, object: nil
        )
        // Warm the switcher up front. `makeMenu` is synchronous by design — it
        // reads the last `reload` — so without this the first long-press builds
        // its menu from an empty snapshot and offers only "Add Profile", with
        // the viewer's own profiles missing.
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
            self?.rebuildSwitcherMenu()
        }

        let feedFlow = FeedFlowCoordinator(container: container)
        feedFlow.start()
        addChild(feedFlow)
        self.feedFlow = feedFlow

        let profileTab = ProfileTabCoordinator(container: container, onLogout: onLogout)
        self.profileTab = profileTab
        let forYouTab = ForYouTabCoordinator(container: container)
        self.forYouTab = forYouTab
        // Ordered before Search deliberately: `UISearchTab` is pinned to the
        // trailing edge by the system, so this array reads as bar order rather
        // than relying on that.
        orderedTabs = [
            (.maps, MapsTabCoordinator(
                container: container,
                notificationsButtonItem: notificationsBarItem
            )),
            (.forYou, forYouTab),
            (.messages, MessagesTabCoordinator(container: container)),
            (.profile, profileTab),
            (.search, SearchTabCoordinator(container: container))
        ]
        for (_, tab) in orderedTabs {
            tab.start()
            addChild(tab)
        }
        popGestureEnablers = orderedTabs.map { NativePopGestureEnabler(taking: $0.1.navigationController) }
        tabBarController.tabs = orderedTabs.map { $0.1.tab }
        tabBarController.delegate = self
        // The Profile tab's long-press switcher. `UITab` carries no menu of its
        // own — `UITab`, `UITabBar`, `UITabBarItem` and the controller delegate
        // were all checked against the iOS 26 SDK and expose nothing — so the
        // menu rides an invisible button kept aligned over the tab.
        tabBarController.onLayout = { [weak self] in
            self?.alignProfileMenuOverlay()
            // The CONTROLLER lays out before the bar has placed its own buttons,
            // and then does not lay out again — measured: one call, reading a
            // zero frame. One hop to the next runloop turn catches the settled
            // geometry, and alignment ignores a zero frame rather than caching
            // it, so the early pass costs nothing.
            DispatchQueue.main.async { self?.alignProfileMenuOverlay() }
        }

        loadAvatar()
        refreshUnreadBadge()

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing,
        // in bar order (0 = Maps … 4 = Search). Every index is a plain
        // selection now — 1 used to trigger the feed push instead, which it no
        // longer does; use `-open-feed` for the timeline.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            selectTab(AppTab.allCases[tabIndex])
        }
        // `-open-feed` pushes the open-ended timeline — the `AppRoute.feed`
        // path, which no longer has a bar button behind it. Deferred a tick:
        // at `start()` the shell isn't the window root yet, so an immediate
        // push would animate off-window.
        if arguments.contains("-open-feed") {
            DispatchQueue.main.async { [weak self] in self?.openFeed() }
        }
        // `-open-my-profile` selects the Profile tab on launch. It used to push
        // the avatar's destination; the destination is now a root, so the intent
        // "show me my profile" is a selection. Deferred a tick: at `start()` the
        // shell isn't the window root yet.
        if arguments.contains("-open-my-profile") {
            DispatchQueue.main.async { [weak self] in self?.selectTab(.profile) }
        }
        // `-tab-round-trip` leaves the current tab and comes back ~1.5s apart.
        // Pair with any push that hides the bar (`-open-my-profile`,
        // `-open-conversation`): the round trip is the only way to reach
        // `syncTabBarVisibility` with a pushed screen on top, and the simulator
        // injects no taps. What it watches for is the bar reappearing over a
        // screen that had hidden it. NOTE the frame right after each switch is
        // mid-crossfade — content lags the bar — so judge the settled state.
        // `-nav-stress <cycles>` drives deep cyclical navigation and audits
        // what each round trip leaves behind — see `NavigationStressTest`. The
        // failure it hunts is a screen that looks correct and no longer answers
        // touches, which no screenshot can tell from a working one.
        if let position = arguments.firstIndex(of: "-nav-stress"),
           position + 1 < arguments.count, let cycles = Int(arguments[position + 1]) {
            let harness = NavigationStressTest(
                tabBarController: tabBarController,
                router: container.router,
                selectTab: { [weak self] tab in self?.selectTab(tab) }
            )
            // `-nav-stress <cycles> [tab]` — one tab by name, or every tab.
            let only = position + 2 < arguments.count
                ? AppTab(rawValue: arguments[position + 2]) : nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await harness.run(cycles: cycles, tabs: only.map { [$0] } ?? AppTab.allCases)
            }
        }
        // `-header-audit` visits every tab and checks the leading-group selector
        // layout on each: in the leading group, sized, hit-testable at every
        // segment, and — on a pushed surface — with the back button and the
        // interactive pop still intact. See `HeaderSelectorAudit`.
        if arguments.contains("-header-audit") {
            let audit = HeaderSelectorAudit(
                tabBarController: tabBarController,
                selectTab: { [weak self] tab in self?.selectTab(tab) }
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                await audit.run(tabs: AppTab.allCases)
            }
        }
        // `-header-audit-current` audits only what is on screen. The tab sweep
        // cannot reach a PUSHED host — a profile, or the relationships screen —
        // and those are the only ones where the back button and the interactive
        // pop are at stake. Pair it with `-open-profile` / `-profile-relationships`.
        if arguments.contains("-header-audit-current") {
            let audit = HeaderSelectorAudit(
                tabBarController: tabBarController,
                selectTab: { [weak self] tab in self?.selectTab(tab) }
            )
            Task { @MainActor in
                // POLLS. A single fixed delay reported "no selector on this bar"
                // for surfaces that were hosting it perfectly — the screen simply
                // had not finished loading yet, and a slower boot moved the whole
                // run past the deadline. Two conclusions were drawn from that
                // before the harness was suspected. Waits for a selector, then
                // audits; if none ever arrives, audits anyway and says so.
                // Waits for a STABLE frame, not merely a present one. Measuring
                // the first non-zero frame caught selectors mid-push and reported
                // 334x43 and 28x7 for the same screen whose settled host is
                // 278x36 — an "escapes the clamp" anomaly that was the harness
                // reading an animation.
                var previous = CGRect.null
                var stableFrames = 0
                for _ in 0..<80 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let frame = audit.selectorFrameOnScreen
                    if frame != .null, frame == previous {
                        stableFrames += 1
                        if stableFrames >= 2 { break }
                    } else {
                        stableFrames = 0
                    }
                    previous = frame
                }
                let finding = audit.audit(surface: "on-screen")
                for problem in finding.problems { print("[header-audit] on-screen: PROBLEM \(problem)") }
                if finding.isClean { print("[header-audit] on-screen: clean") }
            }
        }
        if arguments.contains("-tab-round-trip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.selectTab(.messages)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.selectTab(.maps)
                }
            }
        }
        // `-open-notifications` pushes the notifications feed on launch — the
        // map bell's exact code path — so it's screenshottable without a tap
        // (the sim injects none). Deferred a tick, as above.
        if arguments.contains("-open-notifications") {
            DispatchQueue.main.async { [weak self] in self?.pushNotifications() }
        }
        // `-present-compose` presents the compose sheet on launch, for
        // driving/screenshotting compose without tapping through the UI.
        // Presented over the shell: the feed's bar no longer carries a compose
        // item (its chrome is identical across both entry paths), so this is
        // the `.upload` route's presentation, not a feed affordance. Deferred
        // a tick: at `start()` the shell isn't the window root yet.
        if arguments.contains("-present-compose") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                tabBarController.present(container.uploadFeature.makeComposeViewController(), animated: true)
            }
        }
        // `-feed-repush-demo` pushes the feed twice (combine with
        // `-snap-auto-dismiss`, which pops it ~2.5s after each landing): the
        // second push must resume where the first left off — the retained-
        // timeline continuity the sim can't demonstrate by tapping.
        if arguments.contains("-feed-repush-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openFeed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in self?.openFeed() }
        }
        // `-feed-swipe-demo` pushes the feed, then drives the swipe-to-pop
        // twice: below the completion threshold (springs back), then past it
        // (pops home, bar returns) — the sim can't inject pans.
        if arguments.contains("-feed-swipe-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openFeed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.feedFlow?.debugScriptedSwipe()
            }
        }
        #endif
    }

    /// The Maps tab's navigation stack — where the profile (the avatar's
    /// destination) and notifications (the bell's) are pushed. Resolved from
    /// `orderedTabs` so it tracks the one `MapsTabCoordinator` the shell built.
    private var mapsNavigationController: UINavigationController? {
        orderedTabs.first(where: { $0.0 == .maps })?.1.navigationController
    }

    /// Pushes Notifications onto the Maps stack — the bell's action (the bell
    /// only shows on the Maps root). Rooted at the map so back returns there;
    /// reading clears the badge server-side, and `refreshUnreadBadge` reconciles
    /// on return. Shared with the `-open-notifications` debug hook.
    private func pushNotifications() {
        guard let navigationController = mapsNavigationController else { return }
        navigationController.pushViewController(
            container.notificationsFeature.makeNotificationsViewController(),
            animated: true
        )
    }

    @objc private func activeProfileChanged() {
        loadAvatar()
        // The menu is built on demand from the last `reload`, so refresh the
        // snapshot rather than the menu — there is no menu object to replace.
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
            self?.rebuildSwitcherMenu()
        }
    }

    private func presentAddProfilePlaceholder() {
        let alert = UIAlertController(
            title: "Add Profile",
            message: "Creating a new profile isn't available yet.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        tabBarController.present(alert, animated: true)
    }

    /// Resolves the viewer's avatar into the Profile tab's icon; the placeholder
    /// glyph stays if there is none (or it can't be fetched).
    ///
    /// The switcher menu that used to be rebuilt alongside this is gone with the
    /// avatar bar item. It was a long-press *shortcut*, not the only path: a
    /// profile built as the canonical entry point carries its own switcher in
    /// the header, which the Profile tab root now is.
    private func loadAvatar() {
        Task { [weak self] in
            guard let self else { return }
            let image = await container.profileFeature.viewerAvatarImage()
            profileTab?.setAvatar(image.map(Self.circularBarImage))
        }
    }

    /// Renders an avatar into a circular bar-sized image (`.alwaysOriginal` so
    /// the photo isn't tinted).
    private static func circularBarImage(_ image: UIImage) -> UIImage {
        let side: CGFloat = 30
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Mirrors the unread notifications count onto the bell (a `bell` ↔
    /// `bell.badge` image swap). Best-effort and idempotent — called on start,
    /// on every tab switch, and when a notifications-bearing surface (Profile /
    /// the pushed feed) is left.
    private func refreshUnreadBadge() {
        Task { [weak self] in
            guard let self else { return }
            let count = await container.notificationsFeature.unreadCount()
            notificationsBarItem.image = Self.bellImage(unread: count > 0)
        }
    }
}

// MARK: - Tab selection

extension MainTabCoordinator: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadBadge()
        syncTabBarVisibility()
        // Selection resizes the tab buttons (the selected one carries the
        // lens), so the overlay has to follow.
        alignProfileMenuOverlay()
    }

    /// The bar is managed by hand around full-bleed snap surfaces (the pushed
    /// timeline and the pin-opened feed both hide it), and manual state is
    /// global to the shell's one bar — so a tab switch must reconcile it with
    /// whatever the newly selected tab has on top: hidden over a snap
    /// surface, visible otherwise.
    private func syncTabBarVisibility() {
        guard let stack = tabBarController.selectedViewController as? UINavigationController else { return }
        // Two things hide the bar, and this has to honour BOTH. The snap
        // surfaces do it by hand, which is what this reconciliation was written
        // for. But `hidesBottomBarWhenPushed` hides it too — a pushed profile, a
        // chat thread, the compose picker, a relationship list — and those own
        // the bottom of the screen while they are up. Reading only the first
        // rule forced the bar back over them on the next tab switch: caught in a
        // mid-switch frame as the bar sliding in over a pushed profile, its
        // filter tray underneath.
        //
        // Mirrors UIKit's own rule rather than approximating it: the flag keeps
        // the bar hidden while ANY *pushed* controller on the stack asked for
        // it, not just whichever is on top — push a flagged screen, then an
        // unflagged one above it, and the bar stays down. `dropFirst` because a
        // stack ROOT is never pushed, so its flag says nothing about this.
        let hidesForPush = stack.viewControllers.dropFirst().contains { $0.hidesBottomBarWhenPushed }
        let isSnapSurface = stack.topViewController is any ZoomTransitionDestination
        tabBarController.setTabBarHidden(isSnapSurface || hidesForPush, animated: false)
    }
}

// MARK: - Profile tab long-press

extension MainTabCoordinator {
    /// Keeps the switcher overlay exactly over the Profile tab's button.
    ///
    /// Runs on every layout pass, so it is cheap and idempotent: it re-adds
    /// nothing already added and writes the frame only when it moved.
    fileprivate func alignProfileMenuOverlay() {
        align(profileMenuOverlay, over: profileTab?.tab.title)
        alignForYouMenuOverlay()
    }

    /// Keeps the lens-menu overlay over the For You tab, and installs the menu
    /// the first time the root exists to supply one.
    ///
    /// ⚠️ The menu is attached HERE rather than at `start()`, because the tab's
    /// root view controller is built when its stack is populated and the shell
    /// assembles the bar before that has happened. Attaching once and only once
    /// matters: the menu resolves its own rows at presentation, so re-fetching
    /// it on every layout pass would buy nothing and cost a build per frame.
    private func alignForYouMenuOverlay() {
        // The tab is renamed by the active lens, so both the lookup and the
        // label follow it rather than a constant.
        let title = forYouTab?.tab.title
        forYouMenuOverlay.accessibilityLabel = title
        if forYouMenuOverlay.menu == nil { forYouMenuOverlay.menu = forYouTab?.modeMenu }
        align(forYouMenuOverlay, over: title)
    }

    /// Puts an overlay exactly over the bar button titled `title`.
    ///
    /// Runs on every layout pass, so it is cheap and idempotent: it re-adds
    /// nothing already added and writes the frame only when it moved.
    private func align(_ overlay: UIButton, over title: String?) {
        let bar = tabBarController.tabBar
        guard let title, let button = tabButton(labelled: title, in: bar) else { return }
        let frame = button.convert(button.bounds, to: bar)
        // A zero frame means the bar has not placed its buttons yet; leaving the
        // overlay unplaced is right, and a later pass will catch it.
        guard !frame.isEmpty else { return }
        if overlay.superview !== bar { bar.addSubview(overlay) }
        if overlay.frame != frame { overlay.frame = frame }
        // Keep it topmost: UIKit re-adds its own subviews during a layout pass
        // and would otherwise bury the overlay, which silently costs the
        // long-press with nothing on screen to explain why.
        bar.bringSubviewToFront(overlay)
    }

    /// Installs the switcher menu from the factory's current snapshot.
    fileprivate func rebuildSwitcherMenu() {
        profileMenuOverlay.menu = profileSwitcher?.makeMenu(
            onSwitch: {},
            onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
        )
    }

    /// The tab bar's button for the tab titled `title`.
    ///
    /// Breadth-first, and matched on `accessibilityLabel` rather than on the
    /// private button classes it walks past: a tab button is labelled with its
    /// own title, and breadth-first reaches the button before the label nested
    /// inside it — so this never has to name `_UITabButton`. A future iOS
    /// re-shuffling that hierarchy costs the menu, not a crash.
    private func tabButton(labelled title: String, in bar: UIView) -> UIView? {
        var queue = bar.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            // The overlays carry the same labels by design; skip them or one
            // would match itself and pin its own frame.
            if view === profileMenuOverlay || view === forYouMenuOverlay { continue }
            if view.accessibilityLabel == title { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

// MARK: - AppNavigating

extension MainTabCoordinator: AppNavigating {
    var activeNavigationController: UINavigationController? {
        // Resolve through the presented chain (profile sheet, snap feed, compose)
        // so a route fired from a presented surface lands *on* that surface,
        // not invisibly under it on the covered tab stack.
        var top: UIViewController = tabBarController
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if top === tabBarController {
            return tabBarController.selectedViewController as? UINavigationController
        }
        return top as? UINavigationController ?? top.navigationController
    }

    func selectTab(_ tab: AppTab) {
        guard let match = orderedTabs.first(where: { $0.0 == tab }) else { return }
        // Tab-owning routes mean "take me there": anything presented over the
        // shell would keep covering the destination, so dismiss it first.
        if tabBarController.presentedViewController != nil {
            tabBarController.dismiss(animated: true)
        }
        tabBarController.selectedTab = match.1.tab
        // Programmatic selection skips `didSelect` — reconcile the bar here.
        syncTabBarVisibility()
    }

    func openFeed() {
        // "Take me to the feed" — from a bar tap, a deep link, or a push
        // payload: anything presented over the shell would cover the pushed
        // timeline, so dismiss it first, then push onto the selected tab's
        // stack. No tab switch: back returns exactly to where the user was.
        if tabBarController.presentedViewController != nil {
            tabBarController.dismiss(animated: true)
        }
        guard let navigationController = tabBarController.selectedViewController as? UINavigationController else { return }
        feedFlow?.push(on: navigationController)
    }
}

