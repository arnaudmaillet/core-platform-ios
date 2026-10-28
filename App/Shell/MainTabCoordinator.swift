import ChatInterface
import CoreModels
import CoreNavigation
import FeedInterface
import MediaCore
import MediaPlayback
import NotificationsInterface
import ProfileInterface
import UIKit
import DesignSystem
import Upload

/// The app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. It exists for guests and members alike (guest
/// mode, #438): a sign-in or sign-out swaps the tabs that need an account
/// (`viewerDidChange(isMember:)`) and leaves every other stack where it is. Each tab owns its own navigation stack; this
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
    /// The window's appearance is watched once the dark tab bar first shows (#1697, `applyTabBarStyle`).
    fileprivate var isObservingWindowStyle = false
    /// The style `applyTabBarStyle` gave the bars: `.dark` over Shots,
    /// `.unspecified` (the app's) everywhere else.
    fileprivate var barStyle: UIUserInterfaceStyle = .unspecified

    /// Internal (not private) only for the +QA hooks.
    let container: AppContainer
    private let onLogout: () -> Void
    /// Presents the sign-in flow over the shell — what a guest's "Log in or
    /// sign up" calls. The app coordinator dismisses it when the session lands.
    private let onSignIn: () -> Void
    /// Whether the viewer has an account. Guests browse; the Profile and
    /// Messages tabs invite them to sign in instead.
    private(set) var isMember: Bool
    private var messagesTab: MessagesTabCoordinator?
    /// The Notifications entry point, as every root header wears it: the unread
    /// state and the tap live here once, and each header is handed a FRESH item
    /// bound to them (`NotificationsBell`) — a bar item lives in one bar, so the
    /// single item this used to be could only ever lead the map's.
    private lazy var notificationsBell: NotificationsBell = {
        let bell = NotificationsBell { [weak self] in
            // A member's only: a guest has no bell (#1146), and the drawer's
            // edge swipe is gated on its own (`NotificationsDrawer`).
            self?.notificationsDrawer.open()
        }
        // Baked for the shell's traits — the app's appearance, not iOS's
        // (#1501).
        // The WINDOW's traits — the app's appearance — not the tab bar
        // controller's, which the dark tab bar overrides over Shots (#1697):
        // the bell lives in the pages' bars, which keep the app's look.
        // …unless the bar the bell stands in is Shots' dark one (#1703: it
        // stayed black over that dark header).
        bell.traits = { [weak self] in self?.barTraits ?? .current }
        return bell
    }()
    /// Notifications, as a drawer BEHIND the shell: the whole tab bar
    /// controller slides right to reveal it. See `NotificationsDrawer`.
    ///
    /// Internal (not private) only for the +QA hooks.
    private(set) lazy var notificationsDrawer: NotificationsDrawer = {
        let drawer = NotificationsDrawer(
            tabBarController: tabBarController,
            list: container.notificationsFeature.makeNotificationsViewController()
        )
        drawer.onSetAsideChange = { [weak self] setAside in self?.forYouTab?.setSetAside(setAside) }
        return drawer
    }()
    /// What the window shows: the drawer container, holding the tab bar
    /// controller as its main screen.
    var rootViewController: UIViewController { notificationsDrawer.container }
    /// Internal (not private) only for the +QA hooks.
    private(set) var feedFlow: FeedFlowCoordinator?
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
    /// The For You root, rebuilt on a change of viewer.
    private var forYouTab: ForYouTabCoordinator?

    /// The bar's detached "+": a menu of ways to make a post, never a tab
    /// anyone stands on. See `CreateTabItem`.
    ///
    /// Internal (not private) only for the +QA hooks.
    private(set) lazy var createItem = CreateTabItem { [weak self] destination in
        self?.openCreate(destination)
    }

    /// Hold the "+" to go straight to the camera — the menu's Camera row
    /// without the menu. See `CreateHoldShortcut`.
    ///
    /// Internal (not private) only for the +QA hooks.
    private(set) lazy var createHold = CreateHoldShortcut(
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
    /// The bar's items wait for a redraw at launch and after every
    /// re-composition (#694, `refreshTabLabelsIfNeeded`).
    private var tabLabelsNeedRefresh = true

    init(container: AppContainer, isMember: Bool, onLogout: @escaping () -> Void, onSignIn: @escaping () -> Void) {
        self.container = container
        self.isMember = isMember
        self.onLogout = onLogout
        self.onSignIn = onSignIn
        super.init()
    }

    /// A sign-in or a sign-out, in the same shell. The tabs that need an
    /// account swap their whole stack; For You is rebuilt because its rows are
    /// the viewer's own graph; every other stack stays where it is, so a guest
    /// who signs in from a pushed screen is still on that screen.
    func viewerDidChange(isMember: Bool) {
        guard isMember != self.isMember else { return }
        self.isMember = isMember
        if !isMember {
            // The next viewer must never see this one's conversations.
            container.chatFeature.forgetViewer()
        }
        profileTab?.show(member: isMember)
        messagesTab?.show(member: isMember)
        // The bar itself changes shape with the viewer (#626), in place.
        applyBar(animated: true)
        forYouTab?.start()
        for (_, tab) in orderedTabs {
            (tab as? ExploreTabCoordinator)?.viewerDidChange()
        }
        profileMenuOverlay.isContextMenuInteractionEnabled = isMember
        sweepOrphanedAccessory()
        loadAvatar()
        refreshUnreadBadge()
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
            self?.rebuildSwitcherMenu()
        }
    }

    /// ⚠️ NO BAND OUTLIVES ITS SCREEN ACROSS A CHANGE OF VIEWER. A sign-out
    /// swaps the account's stacks and takes tabs out of the bar in one turn,
    /// and the screens going away hear of it late or detached: the Messages
    /// band stayed over the guest's bar for good (the owner's device,
    /// 2026-10-18). `SelectorAccessory` now removes itself from the
    /// controller it went into; this is the net under it — once the swapped
    /// stacks have laid out, and again after their transitions, a band whose
    /// screen is no longer on show is taken down.
    private func sweepOrphanedAccessory() {
        let controller = tabBarController
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            controller.view.layoutIfNeeded()
            SelectorAccessory.removeOrphan(from: controller)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in
            SelectorAccessory.removeOrphan(from: controller)
        }
    }

    func start() {
        container.onUseSound = { [weak self] sound in self?.openCamera(with: sound) }
        // A switch broadcasts this; reload the avatar so the Profile tab's icon
        // reflects whoever is now active.
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeProfileChanged),
            name: .activeProfileDidChange, object: nil
        )
        // ⚠️ Opening the drawer reads nothing (#1572): a row is read once
        // SEEN, and the list says so after the server has it — the bells
        // follow then, not when the drawer opens.
        NotificationCenter.default.addObserver(
            self, selector: #selector(notificationsReadDidChange),
            name: .notificationsReadDidChange, object: nil
        )
        // A stake's final failure is told (#1775).
        observeLikesGivenBack()
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
            container: container, notificationsBell: notificationsBell, onLogout: onLogout, onSignIn: onSignIn
        )
        self.profileTab = profileTab
        let forYouTab = ForYouTabCoordinator(container: container, notificationsBell: notificationsBell)
        self.forYouTab = forYouTab
        forYouTab.onTabBarStyleChange = { [weak self] in self?.applyTabBarStyle() }
        let messagesTab = MessagesTabCoordinator(
            container: container, notificationsBell: notificationsBell, onSignIn: onSignIn
        )
        self.messagesTab = messagesTab
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
            (.messages, messagesTab),
            (.profile, profileTab)
        ]
        for (_, tab) in orderedTabs {
            (tab as? any GlyphTab)?.onUnreadChange = { [weak self] in self?.refreshTabGlyphs() }
            if let accountTab = tab as? any AccountScopedTab {
                accountTab.show(member: isMember)
            } else {
                tab.start()
            }
            addChild(tab)
        }
        profileMenuOverlay.isContextMenuInteractionEnabled = isMember
        popGestureEnablers = orderedTabs.map { NativePopGestureEnabler(taking: $0.1.navigationController) }
        // The blur at the foot of the screen, mirroring the status band's:
        // one per stack, over its screens and under its bars and the tab bar
        // (#1002) — see `BottomEdgeBlurView`.
        for (_, tab) in orderedTabs { BottomEdgeBlurView.install(in: tab.navigationController) }
        applyBar(animated: false)
        // ⚠️ THE APP OPENS ON FOR YOU → SHOTS (the owner, 2026-10-27, #1765):
        // its first post is the launch screen, as TikTok's first video is. The
        // bar's order stays (Explore first); only the selection moves.
        // `-select-tab N` still overrides it, later in the launch.
        if let forYou = orderedTabs.first(where: { $0.0 == .forYou })?.1.tab {
            tabBarController.selectedTab = forYou
        }
        LaunchTimeline.mark("shell")
        tabBarController.delegate = self
        // The stake menu's way to the cartridge pack, from any screen.
        tabBarController.makeStakeShopScreen = { [unowned container] in container.makeStakeShopScreen() }
        // A `@handle` tapped in a comment, a caption or a bio (#524).
        tabBarController.openMention = { [weak self] handle, source in self?.openMention(handle, from: source) }
        tabBarController.openHashtag = { [weak container] tag in container?.router.route(to: .hashtag(tag)) }
        // ...and completes them while they are typed, in every composer.
        tabBarController.textCompletions = container.textCompletions
        // The gate every write asks before it runs, found up the chain.
        tabBarController.memberGate = container.memberGate
        // The badged bell and tabs are bitmaps baked for the window's traits
        // (#1178, #1501): a light/dark switch — iOS's or the app's own —
        // bakes them again, and so does an accent theme change (#1379).
        tabBarController.view.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, AccentThemeTrait.self]
        ) { [weak self] (_: UIView, _) in
            self?.notificationsBell.repaint()
            self?.refreshTabGlyphs()
        }
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
            DispatchQueue.main.async {
                self?.alignMenuOverlays()
                self?.refreshTabLabelsIfNeeded()
            }
        }
        // On screen, the bar's buttons exist: redraw them once (#694).
        tabBarController.onAppear = { [weak self] in
            DispatchQueue.main.async { self?.refreshTabLabelsIfNeeded() }
            // The window exists now: the pages take its appearance (#1697).
            self?.applyTabBarStyle()
        }

        loadAvatar()
        refreshUnreadBadge()

        #if DEBUG
        installQAHooks()
        #endif
    }

    @objc private func notificationsReadDidChange() {
        refreshUnreadBadge()
    }

    @objc private func activeProfileChanged() {
        loadAvatar()
        // ⚠️ A SWITCH IS ANOTHER VIEWER (#892). A sign-out rebuilds what holds
        // the viewer's own graph (`viewerDidChange(isMember:)`); a switch
        // between two profiles of one account never reaches that, so the
        // inbox, For You's rows, the map's people and the bell stayed the
        // previous profile's. The same rebuilds, minus the bar: the viewer is
        // still a member.
        if isMember {
            container.chatFeature.forgetViewer()
            // A fresh inbox stack (its search and suggestions too), primed for
            // the new profile.
            messagesTab?.show(member: true)
            forYouTab?.start()
            for (_, tab) in orderedTabs {
                (tab as? ExploreTabCoordinator)?.viewerDidChange()
            }
            refreshUnreadBadge()
        }
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
        guard isMember else {
            profileTab?.setAvatar(nil)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let image = await container.profileFeature.viewerAvatarImage()
            profileTab?.setAvatar(image.map(Self.circularBarImage))
        }
    }

    /// Renders an avatar into a circular bar-sized image — aspect-filled, not
    /// squeezed (#1339) — `.alwaysOriginal` so the photo isn't tinted.
    private static func circularBarImage(_ image: UIImage) -> UIImage {
        image.circularThumbnail(side: 30)
    }

    /// Mirrors the unread notifications count onto every bell (a `bell` ↔
    /// `bell.badge` image swap). Best-effort and idempotent — called on start,
    /// on every tab switch, and when a notifications-bearing surface (Profile /
    /// the pushed feed) is left.
    private func refreshUnreadBadge() {
        guard isMember else {
            notificationsBell.setUnread(false)
            container.pushNotifications.setBadge(0)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let count = await container.notificationsFeature.unreadCount()
            notificationsBell.setUnread(count > 0)
            // The app icon too: a push sets it, but a read sends no push, so
            // the count the bell reads is the one the icon wears (#651).
            container.pushNotifications.setBadge(count)
        }
    }
}

// MARK: - Tab selection

extension MainTabCoordinator: UITabBarControllerDelegate {
    /// The tab API's selection — a tap on a tab arrives HERE, not through
    /// `didSelect viewController` (#1697: the dark bar never came on a real
    /// tap, only through `selectTab`).
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        applyTabBarStyle()
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadBadge()
        syncTabBarVisibility()
        applyTabBarStyle()
        // Selection resizes the tab buttons (the selected one carries the
        // lens), so the overlays have to follow.
        alignMenuOverlays()
    }

    /// The bar for this viewer (#626) — a member's: Explore, For You,
    /// Messages, Profile and the "+"; a guest's: Explore, For You, Settings and
    /// a "Sign in" bubble. Nothing in it is a dead end.
    ///
    /// ⚠️ MESSAGES LEAVES THE BAR, it is not greyed out. A disabled tab stood
    /// in a guest's bar doing nothing on tap (and iOS 27 would not even redraw
    /// it on sign-in, #547). A route to Messages still asks a guest to sign up
    /// (`AppRoute.gatedAction`) and lands in the inbox after.
    ///
    /// ⚠️ THE SAME TAB OBJECTS, re-composed with `setTabs` — never rebuilt. The
    /// Profile tab is re-dressed as Settings by its coordinator, and the "+"
    /// is the SAME `UISearchTab` re-dressed as "Sign in": the prominent
    /// identifier, the hold shortcut and the menu anchor are keyed on it.
    ///
    /// A viewer standing on a tab that leaves (a member on Messages who logs
    /// out) lands on Explore — set before the bar changes, so the bar never
    /// holds a selection it no longer has.
    /// The tab bar dark over the For You tab's Shots — the full-screen posts
    /// (#1697, #1703) — the app's own over Feed and every other tab — an appearance,
    /// never an alpha (`native-chrome-uikit-only`).
    ///
    /// ⚠️ ON THE TAB BAR CONTROLLER: iOS 26's floating bar takes its traits
    /// from it and ignores the `tabBar`'s own override (measured: no change).
    /// Its pages are given the app's appearance back — the window's — so a
    /// text page, a pushed profile or a sheet the feed presents stays as the
    /// app draws it.
    /// The traits the bars' baked glyphs are drawn for — the tab icons and
    /// the badged bell: the window's (the app's appearance), darkened over
    /// Shots. ⚠️ Not read off `tabBar.traitCollection`: it
    /// had not taken the controller's dark override when the glyphs were
    /// baked, and the For You and Messages icons stayed black on the dark
    /// bar (#1703).
    private var barTraits: UITraitCollection {
        let base = tabBarController.view.window?.traitCollection ?? tabBarController.view.traitCollection
        guard barStyle != .unspecified else { return base }
        let style = barStyle
        return base.modifyingTraits { $0.userInterfaceStyle = style }
    }

    private func applyTabBarStyle() {
        let forYou = tabBarController.selectedTab?.identifier == AppTab.forYou.rawValue
            && forYouTab?.wantsDarkTabBar ?? true
        // Dark over Shots (#1697, #1703): the bar sits over the media as the
        // post's own chrome does; the app's own everywhere else.
        let style: UIUserInterfaceStyle = forYou ? .dark : .unspecified
        let window = tabBarController.view.window
        let pages: UIUserInterfaceStyle = style == .unspecified
            ? .unspecified
            : (window?.traitCollection.userInterfaceStyle ?? .unspecified)
        // Through the TABS (`UITab.viewController`): with the tab API,
        // `viewControllers` does not list them.
        let tabPages = tabBarController.tabs.compactMap(\.viewController) + (tabBarController.viewControllers ?? [])
        for page in tabPages where page.overrideUserInterfaceStyle != pages {
            page.overrideUserInterfaceStyle = pages
        }
        if tabBarController.overrideUserInterfaceStyle != style {
            tabBarController.overrideUserInterfaceStyle = style
        }
        if barStyle != style {
            barStyle = style
            refreshTabGlyphs()
            notificationsBell.repaint()
        }
        // The app's appearance can change under a dark bar (iOS's switch, the
        // app's theme): the pages follow the window, not the bar.
        if style != .unspecified, let window, !isObservingWindowStyle {
            isObservingWindowStyle = true
            window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindow, _) in
                self?.applyTabBarStyle()
            }
        }
    }

    private func applyBar(animated: Bool) {
        createItem.showSignIn(!isMember)
        createHold.isEnabled = isMember
        // A guest's tab is Settings, with no switcher behind a long press: the
        // overlay that carries Profile's menu goes, so the tab is the bar's own
        // button — one element for VoiceOver, not a duplicate laid over it.
        profileMenuOverlay.isHidden = !isMember
        let wanted = orderedTabs
            .filter { isMember || $0.0 != .messages }
            .map(\.1.tab) + [createItem.tab]
        if let selected = tabBarController.selectedTab, !wanted.contains(where: { $0 === selected }),
           let explore = orderedTabs.first(where: { $0.0 == .explore })?.1.tab {
            tabBarController.selectedTab = explore
        }
        applyTabBarStyle()
        let current = tabBarController.tabs
        guard current.count != wanted.count || zip(current, wanted).contains(where: { $0 !== $1 }) else { return }
        tabBarController.setTabs(wanted, animated: animated)
        refreshTabGlyphs()
        // The re-composed bar draws its items afresh — without their labels
        // (#694): redraw each once it has placed them.
        tabLabelsNeedRefresh = true
        DispatchQueue.main.async { [weak self] in self?.refreshTabLabelsIfNeeded() }
        // The bar changed under VoiceOver's cursor: ask it to re-read.
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// Every glyph tab's two faces (#1191, #1197): the OUTLINE as its image,
    /// the FILL as its selected image — the bar's own lens reveals the fill
    /// wherever it passes, as WhatsApp's does, and draws the selection's
    /// transition itself. Each with its badge variant when the tab has
    /// something unread (the bar draws no count), and the unread said to
    /// VoiceOver as the tab's value (#1196). Run on an unread or
    /// appearance change only, never on a selection: the bar owns that.
    ///
    /// ⚠️ `selectedImage` IS SET BY NAME. `UITab.selectedImage` (iOS 26.1)
    /// failed to compile on CI's Xcode 26 SDK even behind `#available`, so it
    /// is reached through KVC, guarded by `responds(to:)`; a system without it
    /// shows the outline in both states.
    func refreshTabGlyphs() {
        for (_, coordinator) in orderedTabs {
            guard let glyphTab = coordinator as? any GlyphTab else { continue }
            let tab = glyphTab.tab
            // Baked for the BAR's traits (#1501): the app's appearance, or the
            // dark Shots gives the bar (#1697).
            let traits = barTraits
            tab.image = glyphTab.glyph.image(selected: false, badged: glyphTab.hasUnread, traits: traits)
            // The badge said aloud (#1196): an image tells VoiceOver nothing.
            tab.accessibilityValue = glyphTab.hasUnread ? glyphTab.glyph.unreadAccessibilityValue : nil
            if tab.responds(to: NSSelectorFromString("setSelectedImage:")) {
                tab.setValue(
                    glyphTab.glyph.image(selected: true, badged: glyphTab.hasUnread, traits: traits), forKey: "selectedImage"
                )
            }
        }
    }

    /// ⚠️ iOS 27 DRAWS A TAB'S FIRST RENDERING WITHOUT ITS LABEL (#694). An
    /// item shows its title only once it has been UPDATED — a badge, an
    /// avatar, a selection — so at launch the selected Explore tab, and a
    /// guest's whole bar, were icons only until touched. The #547 cure, the
    /// update every item takes: its image (and title) sent round once, after
    /// the bar is in a window (keyed on that state, never on a delay) — at
    /// the bar's first appearance and after each `setTabs`. Same values, so
    /// nothing flickers. Measured: the label views existed, laid out, before
    /// the redraw; the selected tab's simply did not draw.
    private func refreshTabLabelsIfNeeded() {
        guard tabLabelsNeedRefresh, tabBarController.view.window != nil else { return }
        tabLabelsNeedRefresh = false
        for tab in tabBarController.tabs {
            let image = tab.image
            tab.image = nil
            tab.image = image
            let title = tab.title
            tab.title = ""
            tab.title = title
        }
    }

    /// The profile a tapped `@handle` names, by the same road as a
    /// `core-platform.click/@handle` link: `RouteResolver` pushes the profile at once, and
    /// the profile looks the handle up and says so when it names no one (#800).
    private func openMention(_ handle: String, from source: UIView) {
        container.router.route(to: .profileHandle(handle))
    }

    /// The "+" is never a place — see `CreateTabItem`. A tap on it lands HERE,
    /// on the real bubble, which is what keeps the bubble's glass press
    /// response; the selection is refused and the menu opens instead.
    /// VoiceOver and a hardware keyboard arrive by the same road.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab === createItem.tab else {
            // A re-tap on the tab already showing brings its root back to the
            // top (#1309); UIKit still pops a pushed stack on its own.
            TabReselect.target(
                tappedSelectedTab: tab === tabBarController.selectedTab,
                stack: tabBarController.selectedViewController as? UINavigationController
            )?.scrollToTopForTabReselect()
            return true
        }
        // A guest's bubble is "Sign in" (#626): one tap, the login sheet — no
        // menu of things they cannot do yet.
        if createItem.isSignIn {
            onSignIn()
            return false
        }
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
    /// Keeps every menu overlay exactly over its bar item: Profile's switcher
    /// and the "+".
    ///
    /// Runs on every layout pass, so it is cheap and idempotent: it re-adds
    /// nothing already added and writes the frame only when it moved.
    fileprivate func alignMenuOverlays() {
        align(profileMenuOverlay, over: profileTab?.tab)
        align(createItem.overlay, over: createItem.tab)
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
    /// "Use this sound" on a post: the camera, with the sound already chosen.
    fileprivate func openCamera(with sound: PostSound) {
        guard tabBarController.presentedViewController == nil,
              let file = sound.previewURL, file.isFileURL else { return }
        let soundtrack = VideoSoundtrack(fileURL: file, title: sound.title ?? "Original sound")
        tabBarController.present(
            container.uploadFeature.makeCameraViewController(soundtrack: soundtrack), animated: true
        )
    }

    /// Internal (not private) only for the +QA hooks.
    func openCreate(_ destination: CreateTabItem.Destination) {
        // Posting needs an account: a guest signs up first, then lands on the
        // screen they chose. Every "+" entry (menu, long press, debug hook)
        // comes through here.
        MemberGates.perform(.create, from: tabBarController) { [weak self] in
            self?.presentCreate(destination)
        }
    }

    private func presentCreate(_ destination: CreateTabItem.Destination) {
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
        guard let match = orderedTabs.first(where: { $0.0 == tab }),
              // Only a tab the bar holds: a guest's has no Messages (#626).
              tabBarController.tabs.contains(where: { $0 === match.1.tab })
        else { return }
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
        applyTabBarStyle()
        // Programmatic selection skips `didSelect` — reconcile the bar here.
        syncTabBarVisibility()
    }

    /// A route always lands on the main screen, so it closes the drawer —
    /// which is how a tap on a notification shows where it went: the drawer
    /// slides shut while the destination is pushed onto the selected tab.
    func closeOverlays() {
        notificationsDrawer.close()
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

/// A tab whose root depends on whether the viewer has an account: it installs
/// the member content or the guest invitation, and swaps between them when
/// the viewer signs in or out.
@MainActor
protocol AccountScopedTab: TabCoordinator {
    func show(member: Bool)
}

extension ProfileTabCoordinator: AccountScopedTab {}
extension MessagesTabCoordinator: AccountScopedTab {}
