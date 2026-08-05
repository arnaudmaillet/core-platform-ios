import CoreNavigation
import DesignSystem
import FeedInterface
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

    /// The For You root. Held so its lens menu can be answered when the bar
    /// reports a long press over that tab.
    private var forYouTab: ForYouTabCoordinator?

    /// The bar's long-press menu.
    ///
    /// **A recognizer we own, not `UIContextMenuInteraction`.** The interaction
    /// works in a simulator and never fires on hardware: the real
    /// `UITabBarButton` absorbs the Haptic Touch press first, and the device
    /// log says so outright — "System gesture gate timed out". A recognizer
    /// declaring simultaneous recognition does not have to win that arbitration,
    /// it opts out of it. Confirmed on a device before this was built on.
    ///
    /// ⚠️ `cancelsTouchesInView` is TRUE, and it matters. A long press only
    /// cancels once it RECOGNISES, so an ordinary tap is untouched and still
    /// selects the tab — but without it the touch runs on to the button and the
    /// tab ALSO switches when the finger lifts, opening the menu over a screen
    /// that has already navigated somewhere else.
    private lazy var tabMenuPress: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleTabMenuPress))
        press.minimumPressDuration = 0.35
        press.cancelsTouchesInView = true
        press.delegate = self
        return press
    }()

    /// The tap that opened the menu, so the popover can point back at it.
    private var pressedTabFrame: CGRect = .zero

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
        Task { [weak self] in await self?.profileSwitcher?.reload() }

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
        // The long-press menus. `UITab` carries no menu of its own — every tab
        // header in the iOS 26.5 SDK was checked and none mentions one — so the
        // bar carries a single interaction and answers from the press location.
        //
        // Installed once here rather than per layout pass: an interaction
        // belongs to the view, and the view does not change. Nothing needs
        // keeping aligned any more, which is the whole point of the change.
        tabBarController.tabBar.addGestureRecognizer(tabMenuPress)

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
        Task { [weak self] in await self?.profileSwitcher?.reload() }
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

// MARK: - Long-press menus on the tab bar

extension MainTabCoordinator: UIGestureRecognizerDelegate {
    /// Declares away the exclusivity rather than trying to beat it.
    ///
    /// A `UITabBarButton` tracks its own touches and, on hardware, the system
    /// arbitrates that against everything else in the window — the device log
    /// for the old interaction read "System gesture gate timed out", which is
    /// that arbitration timing out rather than resolving. Saying "recognise
    /// alongside" stops it being a contest at all.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === tabMenuPress
    }

    @objc private func handleTabMenuPress(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        let bar = tabBarController.tabBar
        let location = press.location(in: bar)
        guard let (tab, button) = tabAndButton(at: location) else {
            trace("press at \(Int(location.x)),\(Int(location.y)) resolved to no menu tab")
            return
        }
        let sections = menuSections(for: tab)
        guard sections.contains(where: { !$0.items.isEmpty }) else {
            trace("\(tab) has no rows to show")
            return
        }
        trace("\(tab) menu at \(Int(location.x)),\(Int(location.y))")
        // The press has been recognised and the tab will not be selected, so
        // the feedback is the only thing telling the finger it worked.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pressedTabFrame = button.convert(button.bounds, to: bar)
        presentTabMenu(sections)
    }

    /// Presents the rows as a popover pointing down at the tab that was held.
    private func presentTabMenu(_ sections: [TabMenuSection]) {
        let menu = TabMenuViewController(sections: sections)
        menu.modalPresentationStyle = .popover
        menu.popoverPresentationController?.sourceView = tabBarController.tabBar
        menu.popoverPresentationController?.sourceRect = pressedTabFrame
        // Down, because the bar is at the bottom: the arrow points at the tab
        // and the list opens above it, where there is room.
        menu.popoverPresentationController?.permittedArrowDirections = .down
        menu.popoverPresentationController?.delegate = self
        menu.popoverPresentationController?.backgroundColor = .clear
        tabBarController.present(menu, animated: true)
    }

    private func menuSections(for tab: AppTab) -> [TabMenuSection] {
        switch tab {
        case .forYou:
            (forYouTab?.navigationController.viewControllers.first as? any ForYouModeMenuProviding)?
                .makeModeMenuSections() ?? []
        case .profile:
            profileSwitcher?.makeMenuSections(
                onSwitch: {},
                onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
            ) ?? []
        default: []
        }
    }
}

extension MainTabCoordinator: UIPopoverPresentationControllerDelegate {
    /// ⚠️ **`.none`, or iPhone turns this into a sheet.** A popover adapts to a
    /// full-screen presentation by default on compact widths, which is exactly
    /// the bottom-of-the-screen modal card the whole approach is avoiding —
    /// refusing the adaptation is what keeps the arrow pointing at the tab.
    func adaptivePresentationStyle(
        for controller: UIPresentationController, traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

extension MainTabCoordinator {
    /// Which tab a point in the bar belongs to, and the button it landed on.
    ///
    /// Only the two tabs that HAVE menus are considered; a press anywhere else
    /// returns nil, which is what lets the bar go on behaving like a tab bar.
    private func tabAndButton(at location: CGPoint) -> (AppTab, UIView)? {
        let bar = tabBarController.tabBar
        for tab in [AppTab.profile, .forYou] {
            guard let title = title(for: tab),
                  let button = tabButton(labelled: title, at: barIndex(of: tab), in: bar)
            else { continue }
            if button.convert(button.bounds, to: bar).contains(location) { return (tab, button) }
        }
        return nil
    }

    private func title(for tab: AppTab) -> String? {
        switch tab {
        // Renamed by whichever lens is active ("For You", "Work", "Focus"), so
        // the lookup follows the tab rather than a constant.
        case .forYou: forYouTab?.tab.title
        case .profile: profileTab?.tab.title
        default: nil
        }
    }

    /// Where a tab sits in the bar, left to right — the fallback the label
    /// lookup falls back TO. See `tabButton(labelled:at:in:)`.
    private func barIndex(of tab: AppTab) -> Int? {
        orderedTabs.firstIndex { $0.0 == tab }
    }

    /// Dev convenience: `-tabmenu-trace` reports which tab a press resolved to.
    ///
    /// ⚠️ This exists because the failure it describes is INVISIBLE. A press
    /// that resolved to no tab looks exactly like one that resolved to a tab
    /// with no menu, and both look like nothing happening — and the mechanism
    /// reads a private view hierarchy, which is precisely the kind of thing
    /// that differs between one iOS build and the next.
    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-tabmenu-trace") else { return }
        print("[tabmenu] \(message())")
        #endif
    }

    /// The tab bar's button for the tab titled `title`.
    ///
    /// Breadth-first, and matched on `accessibilityLabel` rather than on the
    /// private button classes it walks past: a tab button is labelled with its
    /// own title, and breadth-first reaches the button before the label nested
    /// inside it — so this never has to name `_UITabButton`.
    ///
    /// ⚠️ With a positional fallback, because the label is UIKit's and not
    /// ours: a build that suffixes, localises or relocates it costs the match,
    /// and the symptom is a long press that does nothing. "The nth button, left
    /// to right" is a weaker claim than the label but it is a claim about the
    /// bar's ARRANGEMENT, which is the part that stays true. Fallback rather
    /// than primary, because position is not identity.
    private func tabButton(labelled title: String, at index: Int?, in bar: UIView) -> UIView? {
        var candidates: [UIView] = []
        var queue = bar.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view.accessibilityLabel == title { return view }
            if view is UIControl, view.accessibilityLabel?.isEmpty == false {
                candidates.append(view)
            }
            queue.append(contentsOf: view.subviews)
        }
        guard let index, candidates.indices.contains(index) else { return nil }
        return candidates.sorted { $0.convert($0.bounds, to: bar).minX
            < $1.convert($1.bounds, to: bar).minX }[index]
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

