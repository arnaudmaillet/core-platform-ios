import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit
import Upload
#if DEBUG
import DesignSystem
#endif

/// The authenticated app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
///
/// Tabs are set via the modern `UITabBarController.tabs` API. The trailing item
/// is the "+" (`CreateTabItem`), a `UISearchTab`, which the system detaches to
/// the trailing edge, producing the grouped bar
/// `| Explore  For You  Messages  Profile |  + |` natively. It opens a menu and
/// is never selected.
///
/// Profile is a root tab, carrying the viewer's own avatar as its icon
/// (`ProfileTabCoordinator`) — it is the canonical entry point, so it is the one
/// place the settings gear, the profile switcher and Log Out belong. It replaced
/// the avatar button that used to sit in the map's nav bar (the Explore tab,
/// then called Maps); the map header now carries the notifications bell, the
/// wallet and search. Its "+" left with #152 — making a post starts from the
/// bar's "+" (`CreateTabItem`).
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
    /// The Notifications entry point, as every root header wears it: the unread
    /// state and the tap live here once, and each header is handed a FRESH item
    /// bound to them (`NotificationsBell`) — a bar item lives in one bar, so the
    /// single item this used to be could only ever lead the map's.
    private lazy var notificationsBell = NotificationsBell { [weak self] in
        self?.pushNotifications()
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
    /// lens is active ("For You", "Work", "Focus"), and VoiceOver reads this
    /// overlay, not the tab under it — so the label is re-stated on every
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

    /// The bar's detached "+": a menu of ways to make a post, never a tab
    /// anyone stands on. See `CreateTabItem`.
    private lazy var createItem = CreateTabItem { [weak self] destination in
        self?.openCreate(destination)
    }

    /// Hold the "+" to go straight to the camera — the menu's Camera row
    /// without the menu. See `CreateHoldShortcut`.
    private lazy var createHold = CreateHoldShortcut(
        tab: createItem.tab, tabBarController: tabBarController
    ) { [weak self] in
        self?.createItem.open(.camera)
    }

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

        let profileTab = ProfileTabCoordinator(
            container: container, notificationsBell: notificationsBell, onLogout: onLogout
        )
        self.profileTab = profileTab
        let forYouTab = ForYouTabCoordinator(container: container, notificationsBell: notificationsBell)
        self.forYouTab = forYouTab
        // Bar order: the four places, then the "+". The "+" is not a place, so
        // it is not in `orderedTabs` and nothing can route to it. UIKit
        // separates it from the other four because it is a `UISearchTab` — see
        // `CreateTabItem` for why the type, not `.pinned`, is what detaches it.
        orderedTabs = [
            (.explore, ExploreTabCoordinator(
                container: container,
                notificationsButtonItem: notificationsBell.makeItem()
            )),
            (.forYou, forYouTab),
            (.messages, MessagesTabCoordinator(
                container: container, notificationsBell: notificationsBell
            )),
            (.profile, profileTab)
        ]
        for (_, tab) in orderedTabs {
            tab.start()
            addChild(tab)
        }
        popGestureEnablers = orderedTabs.map { NativePopGestureEnabler(taking: $0.1.navigationController) }
        tabBarController.tabs = orderedTabs.map { $0.1.tab } + [createItem.tab]
        tabBarController.delegate = self
        createHold.install()
        // ⚠️ **iOS 27 STOPPED DETACHING A SEARCH TAB BY ITS TYPE ALONE.** It now
        // gives the separate bubble — its "prominent" treatment — to the tab
        // named by `prominentTabIdentifier`, and when that is nil only to a
        // `UISearchTab` whose `automaticallyActivatesSearch` is on, which the
        // "+" is not (it opens a menu). Unnamed, the "+" was drawn inside the
        // other four's bubble. Named, it stands apart again — measured on an
        // iPhone 18 Pro under iOS 27; iOS 26 separates it by type, as before.
        //
        // ⚠️ **AN iOS 27 SDK API, AND CI STILL BUILDS WITH XCODE 26.** Its SDK
        // does not declare `prominentTabIdentifier`, so `#available` alone does
        // not compile there. Built with an iOS 27 SDK (Swift 6.4), the call is
        // typed; built without one, the same public setter is reached by name,
        // and still runs on an iOS 27 device.
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            tabBarController.prominentTabIdentifier = createItem.tab.identifier
        }
        #else
        let setter = NSSelectorFromString("setProminentTabIdentifier:")
        if tabBarController.responds(to: setter) {
            _ = tabBarController.perform(setter, with: createItem.tab.identifier)
        }
        #endif
        // The bar's menus: Profile's long-press switcher, For You's lens menu
        // and the "+". `UITab` carries no menu of its own — `UITab`, `UITabBar`,
        // `UITabBarItem` and the controller delegate were all checked against
        // the iOS 26 SDK and expose nothing — so each menu rides an invisible
        // button kept aligned over its item.
        tabBarController.onLayout = { [weak self] in
            self?.alignMenuOverlays()
            // The CONTROLLER lays out before the bar has placed its own buttons,
            // and then does not lay out again — measured: one call, reading a
            // zero frame. One hop to the next runloop turn catches the settled
            // geometry, and alignment ignores a zero frame rather than caching
            // it, so the early pass costs nothing.
            DispatchQueue.main.async { self?.alignMenuOverlays() }
        }

        loadAvatar()
        refreshUnreadBadge()

        #if DEBUG
        // `-hero-audit`: the hero machinery's live census — pools, transition
        // objects, stranded views — published to an accessibility probe, a
        // file sink, and the console. The channel every Hero UI suite reads.
        HeroTransitionAudit.installIfRequested(pools: container.debugPlaybackPools)
        AccessoryCollapseAudit.installIfRequested(tabBarController: tabBarController)
        PillDragAudit.installIfRequested(tabBarController: tabBarController)
        #endif

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing,
        // in bar order (0 = Explore … 3 = Profile; the "+" is not a tab and has
        // no index). Every index is a plain selection now — 1 used to trigger
        // the feed push instead, which it no longer does; use `-open-feed` for
        // the timeline.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            selectTab(AppTab.allCases[tabIndex])
        }
        // `-switch-tab N` selects a tab a few seconds AFTER launch, which is a
        // different thing from `-select-tab N` and the difference is
        // load-bearing: `-select-tab` fires before the shell is in a window, so
        // the tab's navigation bar lays out once, already showing. A real viewer
        // arrives by switching, and the Messages selector collapsed into a `•••`
        // on exactly that path while `-select-tab` showed it hosted perfectly.
        // Pair with `-header-audit-current`.
        if let index = arguments.firstIndex(of: "-switch-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), AppTab.allCases.indices.contains(tabIndex) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.selectTab(AppTab.allCases[tabIndex])
            }
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
        // `-open-search` pushes the global search screen onto the current tab —
        // the `AppRoute.search` path both header magnifiers take. The simulator
        // injects no taps, so this is the only way to reach that screen, and its
        // keyboard, headlessly. Pair with `-select-tab` to choose the origin.
        if arguments.contains("-open-search") {
            DispatchQueue.main.async { [weak self] in self?.container.router.route(to: .search) }
        }
        // `-open-create <camera|upload|text>` opens one of the "+" menu's
        // destinations on launch through the menu's own code path, minus the
        // menu. Deferred ~0.6s rather than a tick: a PRESENTATION from a
        // controller that is not in a window yet is refused outright.
        //
        // ⚠️ AND THEN GATED ON THAT STATE, because 0.6 s was only a guess at
        // it. On a slow boot the shell was still off-window (or the root swap
        // still running), UIKit refused the presentation, and `openCreate`'s
        // own `presentedViewController` guard turns away a second one — both
        // silently. The 0.6 s stays as the earliest moment, keeping the
        // composer's presentation off the launch's own turns; the hook then
        // waits for a shell in a window with nothing presented and no
        // transition running, and says GAVE UP if that never comes.
        if let index = arguments.firstIndex(of: "-open-create"), index + 1 < arguments.count,
           let destination = CreateTabItem.Destination(rawValue: arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                QAWait.until("-open-create \(destination.rawValue)", { [weak self] in
                    guard let self else { return true }
                    return tabBarController.viewIfLoaded?.window != nil
                        && tabBarController.presentedViewController == nil
                        && tabBarController.transitionCoordinator == nil
                }) { [weak self] in
                    self?.openCreate(destination)
                }
            }
        }
        // `-open-create-menu`: the "+" MENU itself, through the very path a
        // tap takes (`shouldSelectTab`), ~1.5s in — the menu is a `UIMenu`
        // no simulator tap can open, and `-presentation-budget` needs its
        // presentation turn on its own, without a composer behind it.
        if arguments.contains("-open-create-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                _ = self.tabBarController(self.tabBarController, shouldSelectTab: self.createItem.tab)
            }
        }
        // `-plus-hold-demo <full|short|hold|drift>` holds the "+" through
        // `CreateHoldShortcut`'s own press path — the recogniser's `.began`,
        // `.changed` and `.ended` inputs, minus the recogniser, which no
        // simulator script can hold down — so the disc, its ring, the arming
        // and the camera opening can be filmed. Each step waits on the
        // shortcut's state, never on a clock (the pauses are pacing, so a
        // recording shows each state at rest), and prints GAVE UP if the
        // state never comes. `[plus-hold]` lines go to stderr.
        if let index = arguments.firstIndex(of: "-plus-hold-demo") {
            let mode = index + 1 < arguments.count ? arguments[index + 1] : "full"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugPlusHoldDemo(mode: mode)
            }
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
                if arguments.contains("-header-bar-tree") { audit.dumpBarTree() }
                let finding = audit.audit(surface: "on-screen")
                for problem in finding.problems { print("[header-audit] on-screen: PROBLEM \(problem)") }
                if finding.isClean { print("[header-audit] on-screen: clean") }
            }
        }
        if arguments.contains("-tab-round-trip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.selectTab(.messages)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.selectTab(.explore)
                }
            }
        }
        // `-open-notifications` pushes the notifications feed on launch — the
        // bells' exact code path — so it's screenshottable without a tap
        // (the sim injects none). Deferred a tick, as above.
        if arguments.contains("-open-notifications") {
            DispatchQueue.main.async { [weak self] in self?.pushNotifications() }
        }
        // `-feed-repush-demo` pushes the feed twice (combine with
        // `-snap-auto-dismiss`, which pops it ~2.5s after each landing): the
        // second push must resume where the first left off — the retained-
        // timeline continuity the sim can't demonstrate by tapping.
        //
        // ⚠️ EACH STEP WAITS FOR THE ONE BEFORE IT, not for a clock. The second
        // push used to fire at a fixed 7 s, which only worked while the first
        // landing + the 2.5 s auto-dismiss + the pop all fit inside it: under
        // Slow Animations (or without `-snap-auto-dismiss`) it landed on a
        // feed still on top — a no-op push, and a "continuity" run that
        // re-pushed nothing. Now: push once the stack is at rest, wait for
        // the landing, wait for the pop, push again; GAVE UP at any step
        // that never comes. The 1 s before the first push is the opening beat.
        if arguments.contains("-feed-repush-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugPushFeedWhenResting("-feed-repush-demo first push") { [weak self] stack, feed in
                    QAWait.until(
                        "-feed-repush-demo pop of the first push (pair with -snap-auto-dismiss)",
                        timeout: 30, { [weak stack] in
                            guard let stack else { return true }
                            return stack.transitionCoordinator == nil
                                && !stack.viewControllers.contains(feed)
                        }
                    ) { [weak self] in
                        self?.debugPushFeedWhenResting("-feed-repush-demo second push") { _, _ in }
                    }
                }
            }
        }
        // `-feed-swipe-demo` pushes the feed, then drives the swipe-to-pop
        // twice: below the completion threshold (springs back), then past it
        // (pops home, bar returns) — the sim can't inject pans.
        //
        // ⚠️ The swipe used to fire at a fixed 3 s, 2 s after a push that
        // under Slow Animations had not landed yet — a swipe into a push in
        // flight. It now waits for the landing, then holds 1.5 s on the landed
        // feed (pacing, so a recording shows it at rest before the grab), and
        // swipes only if the feed is still on top at rest.
        if arguments.contains("-feed-swipe-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugPushFeedWhenResting("-feed-swipe-demo") { stack, feed in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak stack] in
                        guard let self, let stack,
                              stack.topViewController === feed,
                              stack.transitionCoordinator == nil else {
                            QAWait.fail("-feed-swipe-demo", "the feed was not on top at rest when the swipe was due")
                            return
                        }
                        feedFlow.debugScriptedSwipe()
                    }
                }
            }
        }
        #endif
    }

    /// Pushes Notifications onto the SELECTED tab's stack — the bell's action.
    ///
    /// It used to be the Maps stack, always, because the map was the only
    /// header with a bell. Every root header leads with one now, and a bell only
    /// ever stands on a tab ROOT with nothing presented over it, so the selected
    /// stack is by construction the one whose bell was pressed: back returns to
    /// the header the viewer tapped. Reading clears the badge server-side, and
    /// `refreshUnreadBadge` reconciles on the next tab switch. Shared with the
    /// `-open-notifications` debug hook, which therefore pushes onto whichever
    /// tab `-select-tab` chose.
    private func pushNotifications() {
        guard let navigationController = tabBarController.selectedViewController
            as? UINavigationController else { return }
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

    /// Mirrors the unread notifications count onto every bell (a `bell` ↔
    /// `bell.badge` image swap). Best-effort and idempotent — called on start,
    /// on every tab switch, and when a notifications-bearing surface (Profile /
    /// the pushed feed) is left.
    private func refreshUnreadBadge() {
        Task { [weak self] in
            guard let self else { return }
            let count = await container.notificationsFeature.unreadCount()
            notificationsBell.setUnread(count > 0)
        }
    }
}

// MARK: - Tab selection

extension MainTabCoordinator: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadBadge()
        syncTabBarVisibility()
        // Selection resizes the tab buttons (the selected one carries the
        // lens), so the overlays have to follow.
        alignMenuOverlays()
    }

    /// The "+" is never a place — see `CreateTabItem`. A tap on it lands HERE,
    /// on the real bubble, which is what keeps the bubble's glass press
    /// response; the selection is refused and the menu opens instead.
    /// VoiceOver and a hardware keyboard arrive by the same road.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab === createItem.tab else { return true }
        // A hold on the "+" that went on to show the camera disc is not a tap,
        // whatever the bar makes of the lift — see `CreateHoldShortcut`.
        if createHold.consumeSelection() { return false }
        // Place the anchor now rather than trust the last layout pass, and
        // never open the menu from an anchor outside a window: that raises.
        alignMenuOverlays()
        if !createItem.presentMenu(), tabBarController.presentedViewController == nil {
            tabBarController.present(createItem.makeFallbackSheet(), animated: true)
        }
        return false
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
        // ⚠️ Asks the screen whether it COVERS the bar; it used to test
        // conformance to `ZoomTransitionDestination` and treat that as the same
        // fact. It stopped being the same fact when the place page conformed so
        // its own dismissal could fly home to the map marker — an ordinary
        // pushed screen that shows the dock, which this reconciliation then
        // actively hid on every tab switch back onto it.
        let concealsBar = (stack.topViewController as? any ZoomTransitionDestination)?
            .concealsAppTabBar == true
        tabBarController.setTabBarHidden(concealsBar || hidesForPush, animated: false)
    }
}

// MARK: - Bar menus

extension MainTabCoordinator {
    /// Keeps every menu overlay exactly over its bar item: Profile's switcher,
    /// For You's lens menu and the "+".
    ///
    /// Runs on every layout pass, so it is cheap and idempotent: it re-adds
    /// nothing already added and writes the frame only when it moved.
    fileprivate func alignMenuOverlays() {
        align(profileMenuOverlay, over: profileTab?.tab)
        alignForYouMenuOverlay()
        align(createItem.overlay, over: createItem.tab)
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
        // The tab is renamed by the active lens, so the label follows it rather
        // than a constant.
        forYouMenuOverlay.accessibilityLabel = forYouTab?.tab.title
        if forYouMenuOverlay.menu == nil { forYouMenuOverlay.menu = forYouTab?.modeMenu }
        align(forYouMenuOverlay, over: forYouTab?.tab)
    }

    /// Puts an overlay exactly over the bar's button for `tab`.
    ///
    /// Runs on every layout pass, so it is cheap and idempotent: it re-adds
    /// nothing already added and writes the frame only when it moved.
    ///
    /// ⚠️ ASKS THE TAB WHERE IT IS, through `frame(in:)` — public, since `UITab`
    /// is a `UIPopoverPresentationControllerSourceItem`. It used to walk the bar
    /// for the view whose `accessibilityLabel` was the tab's title, and a tab
    /// button carries that label ONLY while the accessibility runtime is loaded:
    /// on a simulator an accessibility inspector has touched, yes; on an iPhone
    /// with VoiceOver off, no. Every overlay then went unplaced — measured on an
    /// iPhone SE simulator, not one `_UITabButton` labelled — and the "+" crashed
    /// opening its menu from an anchor outside any window.
    private func align(_ overlay: UIButton, over tab: UITab?) {
        guard let tab else { return }
        let bar = tabBarController.tabBar
        // No frame, or an empty one, means the bar has not placed its buttons
        // yet; leaving the overlay unplaced is right, and a later pass will
        // catch it.
        guard let frame = tab.frame(in: bar), !frame.isEmpty else { return }
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

    /// Opens one of the "+" menu's destinations.
    ///
    /// PRESENTED over the shell, not pushed onto the current tab: making a
    /// post belongs to no tab, and is finished or abandoned as a whole.
    fileprivate func openCreate(_ destination: CreateTabItem.Destination) {
        // A second presentation would be refused. The bar cannot be tapped
        // under one, so this only ever turns away the debug hook.
        guard tabBarController.presentedViewController == nil else { return }
        let screen: UIViewController = switch destination {
        case .camera: container.uploadFeature.makeCameraViewController()
        case .upload: container.uploadFeature.makeMediaUploadViewController()
        case .text: container.uploadFeature.makeTextPostViewController()
        }
        tabBarController.present(screen, animated: true)
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
        #if DEBUG
        // The zero the `[dock]` stamps are read against: how long after the tab
        // changed did the band actually arrive. Stamped HERE and not in
        // `didSelect(_:)` — that delegate callback answers a real tap only, and
        // every debug route into a tab goes through this method instead, so a
        // trace driven by `-switch-tab` had no zero at all.
        print(String(format: "[dock] %.3f selectTab %@",
                     ProcessInfo.processInfo.systemUptime, tab.rawValue))
        #endif
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


#if DEBUG
// MARK: - QA hooks: waiting on the stack, not on a clock

extension MainTabCoordinator {
    /// The selected tab's stack, when the shell is on screen with nothing
    /// presented over it and no push or pop running on it — the only state a
    /// scripted push can be trusted to land from.
    fileprivate var debugRestingStack: UINavigationController? {
        guard tabBarController.viewIfLoaded?.window != nil,
              tabBarController.presentedViewController == nil,
              let stack = tabBarController.selectedViewController as? UINavigationController,
              stack.transitionCoordinator == nil else { return nil }
        return stack
    }

    /// Drives `-plus-hold-demo`: see the hook in `start()`.
    fileprivate func debugPlusHoldDemo(mode: String) {
        let label = "-plus-hold-demo \(mode)"
        let hold = createHold
        QAWait.until("\(label): a resting shell with the + placed", { [weak self] in
            guard let self else { return true }
            return tabBarController.viewIfLoaded?.window != nil
                && tabBarController.presentedViewController == nil
                && tabBarController.transitionCoordinator == nil
                && hold.debugBubbleCentre != nil
        }) { [weak self] in
            // Pacing: a second of the bar at rest before the finger lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugRunPlusHold(mode: mode, label: label)
            }
        }
    }

    private func debugRunPlusHold(mode: String, label: String) {
        let hold = createHold
        // The shell's own controller, alive as long as the app: holding it
        // here keeps every step below free of `self`.
        let controller = tabBarController
        let presented = { controller.presentedViewController.map { "\(type(of: $0))" } ?? "nil" }
        hold.debugLog("\(label): press")
        hold.debugPress()
        switch mode {
        case "short":
            // Let go with the ring half full: the disc must shrink away and
            // nothing may open.
            QAWait.until("\(label): half a ring", { hold.debugProgress >= 0.5 }) {
                let disc = hold.debugDisc
                hold.debugLog(String(format: "\(label): release at %.2f", hold.debugProgress))
                hold.debugRelease()
                QAWait.until("\(label): the disc gone", { disc?.superview == nil }) {
                    hold.debugLog("\(label): disc gone, presented=\(presented())")
                }
            }
        case "drift":
            // Slide off with the ring under way: the disc goes at once, while
            // the finger is still down, and the lift then does nothing.
            QAWait.until("\(label): a ring under way", { hold.debugProgress >= 0.4 }) {
                hold.debugDrag(by: CGVector(dx: -90, dy: -30))
                QAWait.until("\(label): abandoned", { hold.debugPhase == .abandoned }) {
                    hold.debugLog("\(label): abandoned while held")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        hold.debugRelease()
                        hold.debugLog("\(label): released, presented=\(presented())")
                    }
                }
            }
        case "hold":
            // Stay armed, for a still of the full state.
            QAWait.until("\(label): armed", { hold.debugPhase == .armed }) {
                hold.debugLog("\(label): armed, holding")
            }
        default:
            // "full": fill, hold armed a beat, let go — the camera opens.
            QAWait.until("\(label): armed", { hold.debugPhase == .armed }) {
                hold.debugLog("\(label): armed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    hold.debugRelease()
                    QAWait.until("\(label): the camera presented", { controller.presentedViewController != nil }) {
                        hold.debugLog("\(label): presented \(presented())")
                    }
                }
            }
        }
    }

    /// Pushes the timeline (`openFeed`, the bar's own path) once the selected
    /// stack is at rest, then hands `landed` that stack and the feed once the
    /// push has FINISHED — the stack deeper than it was and no transition
    /// running. Each wait prints a `[qa] GAVE UP` line if it never comes, so
    /// a demo that did not push, or whose push never landed, says so.
    fileprivate func debugPushFeedWhenResting(
        _ label: String,
        landed: @escaping @MainActor (UINavigationController, UIViewController) -> Void
    ) {
        QAWait.until("\(label): a resting stack to push on", { [weak self] in
            guard let self else { return true }
            return debugRestingStack != nil
        }) { [weak self] in
            guard let self, let stack = debugRestingStack else { return }
            let depth = stack.viewControllers.count
            openFeed()
            QAWait.until("\(label): the push landing", { [weak stack] in
                guard let stack else { return true }
                return stack.transitionCoordinator == nil && stack.viewControllers.count > depth
            }) { [weak stack] in
                guard let stack, let feed = stack.topViewController else { return }
                landed(stack, feed)
            }
        }
    }
}
#endif
