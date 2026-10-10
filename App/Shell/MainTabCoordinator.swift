import ChatInterface
import CoreModels
import CoreNavigation
import FeedInterface
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
    private lazy var notificationsBell: NotificationsBell = NotificationsBell { [weak self] in
        guard let self else { return }
        // A guest has no notifications: the bell invites them to sign up, and
        // opens the drawer once they have.
        MemberGates.perform(.notifications, from: tabBarController) { [weak self] in
            self?.notificationsDrawer.open()
        }
    }
    /// Notifications, as a drawer BEHIND the shell: the whole tab bar
    /// controller slides right to reveal it. See `NotificationsDrawer`.
    ///
    /// Internal (not private) only for the +QA hooks.
    private(set) lazy var notificationsDrawer: NotificationsDrawer = NotificationsDrawer(
        tabBarController: tabBarController,
        list: container.notificationsFeature.makeNotificationsViewController(),
        onDidOpen: { [weak self] in
            // Opening the list is what reads it (the list tells the server
            // itself); the bells stop saying "unread" at once.
            self?.notificationsBell.setUnread(false)
        }
    )
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
        loadAvatar()
        refreshUnreadBadge()
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
            self?.rebuildSwitcherMenu()
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
            if let accountTab = tab as? any AccountScopedTab {
                accountTab.show(member: isMember)
            } else {
                tab.start()
            }
            addChild(tab)
        }
        profileMenuOverlay.isContextMenuInteractionEnabled = isMember
        popGestureEnablers = orderedTabs.map { NativePopGestureEnabler(taking: $0.1.navigationController) }
        applyBar(animated: false)
        tabBarController.delegate = self
        // The stake menu's way to the cartridge pack, from any screen.
        tabBarController.makeStakeShopSheet = { [unowned container] in container.makeStakeShopSheet() }
        // A `@handle` tapped in a comment, a caption or a bio (#524).
        tabBarController.openMention = { [weak self] handle, source in self?.openMention(handle, from: source) }
        tabBarController.openHashtag = { [weak container] tag in container?.router.route(to: .hashtag(tag)) }
        // ...and completes them while they are typed, in every composer.
        tabBarController.textCompletions = container.textCompletions
        // The gate every write asks before it runs, found up the chain.
        tabBarController.memberGate = container.memberGate
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
        }

        loadAvatar()
        refreshUnreadBadge()

        #if DEBUG
        installQAHooks()
        #endif
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
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        refreshUnreadBadge()
        syncTabBarVisibility()
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
        let current = tabBarController.tabs
        guard current.count != wanted.count || zip(current, wanted).contains(where: { $0 !== $1 }) else { return }
        tabBarController.setTabs(wanted, animated: animated)
        // The re-composed bar draws its items afresh — without their labels
        // (#694): redraw each once it has placed them.
        tabLabelsNeedRefresh = true
        DispatchQueue.main.async { [weak self] in self?.refreshTabLabelsIfNeeded() }
        // The bar changed under VoiceOver's cursor: ask it to re-read.
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
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
    /// `wynn.cn/@handle` link: `RouteResolver` looks the handle up, pushes the
    /// profile like an author's, and says so when it names no one.
    private func openMention(_ handle: String, from source: UIView) {
        container.router.route(to: .profileHandle(handle))
    }

    /// The "+" is never a place — see `CreateTabItem`. A tap on it lands HERE,
    /// on the real bubble, which is what keeps the bubble's glass press
    /// response; the selection is refused and the menu opens instead.
    /// VoiceOver and a hardware keyboard arrive by the same road.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab === createItem.tab else { return true }
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
