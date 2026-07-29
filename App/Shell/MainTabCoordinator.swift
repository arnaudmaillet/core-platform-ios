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
/// the grouped bar `| Maps  Feed  Messages  Profile |  Search |` natively.
///
/// Profile is a root tab, carrying the viewer's own avatar as its icon
/// (`ProfileTabCoordinator`) — it is the canonical entry point, so it is the one
/// place the settings gear, the profile switcher and Log Out belong. It replaced
/// the avatar button that used to sit in the Maps nav bar; the map header now
/// carries only the "+" and the notifications bell.
///
/// One bar button is not a tab: Feed. Selecting it is vetoed
/// (`shouldSelectTab`) and the timeline is *pushed* onto the current tab's stack
/// instead (see `FeedFlowCoordinator`) — back returns to where the user was, and
/// no tab switch occurs.
@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = UITabBarController()

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
    /// Tabs paired with their `AppTab`, in bar order — the lookup `selectTab`
    /// resolves against. Feed is absent: it contributes `feedActionTab` to the
    /// bar but owns no root stack.
    private var orderedTabs: [(AppTab, any TabCoordinator)] = []
    /// One per tab stack: keeps the native edge-swipe pop working under the
    /// feed's custom transition delegates (see `NativePopGestureEnabler`).
    private var popGestureEnablers: [NativePopGestureEnabler] = []

    /// The Feed bar button. The provider must vend *something* — and the
    /// system calls it eagerly when `tabs` is assigned, not on first selection
    /// — but selection is always vetoed in `shouldSelectTab`, so the
    /// placeholder is only ever *shown* if a programmatic path sets
    /// `selectedTab` to it: a bug, made visible (and recoverable via its
    /// button) rather than a black screen.
    private lazy var feedActionTab = UITab(
        title: "Feed",
        image: UIImage(systemName: "house"),
        identifier: AppTab.feed.rawValue
    ) { [weak self] _ in
        PlaceholderViewController(
            title: "Feed",
            systemImage: "house",
            message: "The Feed opens as a pushed screen.",
            actionTitle: "Open Feed",
            action: { self?.openFeed() }
        )
    }

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

        let feedFlow = FeedFlowCoordinator(container: container)
        feedFlow.start()
        addChild(feedFlow)
        self.feedFlow = feedFlow

        let profileTab = ProfileTabCoordinator(container: container, onLogout: onLogout)
        self.profileTab = profileTab
        // Ordered before Search deliberately: `UISearchTab` is pinned to the
        // trailing edge by the system, so this array reads as bar order rather
        // than relying on that.
        orderedTabs = [
            (.maps, MapsTabCoordinator(
                container: container,
                notificationsButtonItem: notificationsBarItem
            )),
            (.messages, MessagesTabCoordinator(container: container)),
            (.profile, profileTab),
            (.search, SearchTabCoordinator(container: container))
        ]
        for (_, tab) in orderedTabs {
            tab.start()
            addChild(tab)
        }
        popGestureEnablers = orderedTabs.map { NativePopGestureEnabler(taking: $0.1.navigationController) }
        // Feed rides the bar at its usual slot but is not in `orderedTabs`:
        // it has no root stack to select, only a push to trigger.
        var tabs = orderedTabs.map { $0.1.tab }
        tabs.insert(feedActionTab, at: 1)
        tabBarController.tabs = tabs
        tabBarController.delegate = self

        loadAvatar()
        refreshUnreadBadge()

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing,
        // in bar order (0 = Maps … 3 = Search). 1 (Feed) is not a selection:
        // it triggers the push, deferred a tick — at `start()` the shell isn't
        // the window root yet, so an immediate push would animate off-window.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            let tab = AppTab.allCases[tabIndex]
            if tab == .feed {
                DispatchQueue.main.async { [weak self] in self?.openFeed() }
            } else {
                selectTab(tab)
            }
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
    /// The Feed button is an action, not a place: veto its selection (the
    /// current tab stays selected, its stack stays put) and push the timeline
    /// onto that stack instead.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab.identifier == AppTab.feed.rawValue else { return true }
        openFeed()
        // Vetoed selections never reach `didSelect`; refresh the dot here so a
        // Feed tap keeps the same badge freshness a tab switch has.
        refreshUnreadBadge()
        return false
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadBadge()
        syncTabBarVisibility()
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
        // Feed is not a selectable tab; honor the intent as the push it now is.
        if tab == .feed {
            openFeed()
            return
        }
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

