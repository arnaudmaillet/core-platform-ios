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

    /// The For You root. Held so its lens menu can be answered when the bar
    /// reports a long press over that tab.
    private var forYouTab: ForYouTabCoordinator?

    /// The bar's own long-press menu, resolved by WHERE the press landed.
    ///
    /// **This replaced an invisible `UIButton` laid over each tab.** That
    /// worked in the simulator and not on hardware, and the reason is the one
    /// thing a simulator cannot reproduce: on a device the real
    /// `UITabBarButton` underneath takes the Haptic Touch press first, so the
    /// overlay's own interaction was never given the gesture. An overlay can
    /// only win that arbitration by being the thing UIKit hands the touch to,
    /// and over a live control it is not.
    ///
    /// Attaching to the BAR sidesteps the contest entirely: there is one
    /// interaction, it belongs to the view that owns the whole region, and
    /// which tab was pressed is answered from the location rather than from
    /// whose view got the touch.
    ///
    /// ⚠️ There is no native alternative. Every tab header in the iOS 26.5 SDK
    /// — `UITab`, `UITabGroup`, `UITabBar`, `UITabBarItem`, `UITabBarController`,
    /// `UITabAccessory`, `UITabSidebarItem` — contains the word "menu" exactly
    /// zero times. `tabBar(_:contextMenuConfigurationForTab:)` does not exist.
    private lazy var tabMenuInteraction = UIContextMenuInteraction(delegate: self)

    /// A PROBE, not the mechanism.
    ///
    /// The interaction above works in the simulator and not on hardware, and
    /// the one question that decides what to build next is whether a recognizer
    /// we own on this bar receives the press AT ALL on a device. If it fires,
    /// the exclusivity that is eating the interaction can be declared away and
    /// the remaining work is presentation. If it does not, no recognizer on the
    /// bar will do and the gesture has to live somewhere the tab buttons cannot
    /// intercept — the window, or the controller's own view.
    ///
    /// ⚠️ `cancelsTouchesInView` is FALSE here **only because a probe must not
    /// change what it is measuring.** The real implementation wants it TRUE: a
    /// long press that lets its touch through means the tab ALSO switches when
    /// the finger lifts, and the menu opens over a screen that has already
    /// navigated somewhere else. Left false, this probe is invisible — it
    /// observes and reports and nothing more.
    private lazy var tabPressProbe: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleTabPressProbe))
        press.minimumPressDuration = 0.35
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        // The whole point: the tab buttons' own handling stops being a contest
        // to win and becomes something to coexist with.
        press.delegate = self
        return press
    }()

    /// What the menu lifts instead of a tab.
    ///
    /// ⚠️ **A context menu ALWAYS lifts its source** — it hides the original,
    /// floats a scaled copy and dims everything behind. That is why the overlay
    /// existed: on a tab it produced a second avatar hovering over fixed
    /// chrome, and the interaction offers no way to switch it off. Attaching to
    /// the bar makes it worse, not better, because the source is now the whole
    /// bar.
    ///
    /// So the lift is given something with nothing in it. This view is clear
    /// and empty; it is moved over whichever tab was pressed and handed back as
    /// the preview, so the menu is anchored to the right place and what floats
    /// is invisible. That is exactly what the invisible button did — the same
    /// trick, owned by the bar rather than by a control that cannot win the
    /// gesture.
    private let menuLiftAnchor = UIView()

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
        tabBarController.tabBar.addInteraction(tabMenuInteraction)
        tabBarController.tabBar.addGestureRecognizer(tabPressProbe)
        menuLiftAnchor.backgroundColor = .clear
        menuLiftAnchor.isUserInteractionEnabled = false

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

// MARK: - Device probe

extension MainTabCoordinator: UIGestureRecognizerDelegate {
    /// Declares away the exclusivity rather than trying to beat it.
    ///
    /// A `UITabBarButton` tracks its own touches and, on hardware, the system's
    /// Haptic Touch pathway arbitrates that against everything else in the
    /// window. Saying "recognise alongside" is what stops that arbitration
    /// being a fight one side has to lose.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === tabPressProbe
    }

    /// Reports whether the press arrived, where, and which tab it resolved to.
    ///
    /// This is the whole probe. It presents nothing and consumes nothing — a
    /// line in the console is the entire deliverable, because the fact it
    /// establishes is the one thing no amount of reasoning here can settle.
    @objc private func handleTabPressProbe(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        let location = press.location(in: tabBarController.tabBar)
        let resolved = tabAndButton(at: location).map { "\($0.0)" } ?? "no menu tab"
        trace("PROBE long press began at \(Int(location.x)),\(Int(location.y)) → \(resolved)")
    }
}

// MARK: - Long-press menus on the tab bar

extension MainTabCoordinator: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let (tab, _) = tabAndButton(at: location) else {
            trace("no menu tab at \(Int(location.x)),\(Int(location.y))")
            return nil
        }
        // ⚠️ Built at PRESS time, not held. The switcher's rows come from its
        // last reload and the For You lens menu re-reads which lens is active —
        // a menu captured earlier would offer a stale list, which is exactly
        // what the old overlay's install-once-and-keep did.
        guard let menu = menu(for: tab) else {
            trace("\(tab) has no menu to show")
            return nil
        }
        trace("\(tab) menu at \(Int(location.x)),\(Int(location.y))")
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    /// What lifts: nothing, over the tab that was pressed.
    ///
    /// Both callbacks answer the same way — the lift and the drop back have to
    /// agree, or the menu opens over an invisible anchor and closes by floating
    /// the entire tab bar back into place.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        liftPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        liftPreview()
    }

    /// An empty view the size of the pressed tab, standing in for the tab
    /// itself so the lift has something to float that shows nothing.
    private func liftPreview() -> UITargetedPreview? {
        let bar = tabBarController.tabBar
        guard let (_, button) = tabAndButton(at: tabMenuInteraction.location(in: bar))
        else { return nil }
        if menuLiftAnchor.superview !== bar { bar.addSubview(menuLiftAnchor) }
        menuLiftAnchor.frame = button.convert(button.bounds, to: bar)
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: menuLiftAnchor, parameters: parameters)
    }

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

    private func menu(for tab: AppTab) -> UIMenu? {
        switch tab {
        case .forYou: forYouTab?.modeMenu
        case .profile: profileSwitcher?.makeMenu(
            onSwitch: {},
            onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
        )
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
            if view === menuLiftAnchor { continue }
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

