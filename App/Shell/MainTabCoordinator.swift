import ChatInterface
import CoreModels
import CoreNavigation
import CoreStorage
import Transitions
import FeedInterface
import LaunchArguments
import MediaCore
import MediaPlayback
import NotificationsInterface
import PostGrid
import ProfileInterface
import UIKit
import DesignSystem
import UploadInterface

/// The app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. It exists for guests and members alike (guest
/// mode, #438): a sign-in or sign-out swaps the tabs that need an account
/// (`viewerDidChange(isMember:)`) and leaves every other stack where it is. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
///
/// Tabs are set via the modern `UITabBarController.tabs` API: three places
/// (#2489, the owner 2026-11-18) in one centred bubble, `[ Explore · Messages
/// · Profile ]`, Profile no longer apart (#2579, the owner 2026-11-26) — see
/// `ShellTabs`. For You left the bar with #2453, and the "+" with #2489: it
/// is Explore's top bar item now (`CreateBarItem`).
///
/// Profile is a root tab, carrying the viewer's own avatar as its icon
/// (`ProfileTabCoordinator`) — it is the canonical entry point, so it is the one
/// place the settings gear, the profile switcher and Log Out belong. It replaced
/// the avatar button that used to sit in the map's nav bar (the Explore tab,
/// then called Maps); the map header now carries the notifications bell, the
/// wallet and search. Its "+" left with #152 — making a post starts from the
/// "+" beside Explore's search (`CreateBarItem`).
///
/// **Every bar button is a tab.** For You (slot 1 from 2026-10, Feed and
/// Shots) left the bar on 2026-11-15 (#2453): the app is the map's first.
/// `AppRoute.feed` still pushes the open-ended timeline through
/// `FeedFlowCoordinator`, which is therefore still built and held here even
/// though nothing in the bar reaches it.
@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = ShellTabBarController()

    /// Internal (not private) only for the +QA hooks.
    let container: AppContainer
    /// `container.likesGivenBack`, heard for as long as this coordinator
    /// lives (`observeLikesGivenBack`; a selector registration before #2376).
    var likesGivenBackObservation: StoreObservation?
    /// Profile switches, on the app's viewer channel (#2376), for as long as
    /// the shell lives.
    private var activeProfileSubscription: ViewerEventSubscription?
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
        // Baked for the WINDOW's traits — the app's appearance, not iOS's
        // (#1501).
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

    /// An invisible ANCHOR laid over the Profile tab, which the switcher opens
    /// from (#2034). It takes no touch: the tab keeps its own press response
    /// and its tap, and the hold is the bar's (`profileHold`).
    ///
    /// **Why not a `UIContextMenuInteraction`.** A context menu always LIFTS
    /// its source: it hides the original, floats a scaled copy and dims
    /// everything behind. On a tab that produced a second avatar hovering over
    /// the bar. This anchor is a *different view* from the tab, so UIKit never
    /// touches the real icon: not hidden, not snapshotted, not moved.
    private lazy var profileMenuOverlay: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = false
        return button
    }()

    /// The Profile tab's hold, hung on the BAR: the iOS 26 bar takes a touch
    /// on its items for its own selection, so a recognizer on an overlay
    /// never began. It looks only at touches on the Profile tab
    /// (`shouldReceive`): `UITab.frame(in:)` finds it in the bubble.
    ///
    /// ⚠️ **IT RUNS BESIDE THE BAR'S OWN SELECTION** (#2579). The bar selects
    /// its tabs, and drives the lens's press response, through a recognizer
    /// of its own on the same view. Left exclusive, that one won every touch
    /// inside the bubble and the hold never began: measured in the iOS 27.2
    /// simulator, a real hold on Profile selected the tab, and opened the
    /// switcher once the bar's recognizer was disabled. Only Profile standing
    /// apart (#2489) escaped it. So the two recognize together
    /// (`shouldRecognizeSimultaneouslyWith`), and the bar keeps its press
    /// response; once the hold is recognized, it takes the touch from the
    /// bar's (`takeTouchFromBar`), so the lift selects nothing.
    ///
    /// **Hold, slide, release** as a system menu: the hold opens the switcher
    /// (`beginTracking`), the finger lights the rows it crosses, and lifting
    /// it on one picks it — lifted on none, the switcher stays open. A tap
    /// still selects the tab: before the hold is recognized a lift fails it,
    /// and the bar's selection takes the tap as it always did.
    private lazy var profileHold: UILongPressGestureRecognizer = {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(profileOverlayHeld(_:)))
        hold.minimumPressDuration = 0.4
        hold.delegate = self
        return hold
    }()
    /// The switcher the hold opened, following the finger until it lifts.
    private var switcherTracking: (any ProfileSwitcherTracking)?
    /// The touch the hold is following, whose other recognizers on the bar
    /// it cancels once recognized (`takeTouchFromBar`).
    private weak var profileHoldTouch: UITouch?

    #if DEBUG
    /// `-profile-switcher-hold`: the Profile tab's hold, past its recognition
    /// — the switcher opened from the tab, as the finger would open it, for
    /// captures taken with no finger on the screen.
    func debugHoldProfileTab() {
        alignMenuOverlays()
        switcherTracking = profileSwitcher?.beginTracking(
            from: profileMenuOverlay, over: tabBarController, includesAddProfile: true,
            onSwitch: {}, onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
        )
    }
    #endif

    @objc private func profileOverlayHeld(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard isMember else { return }
            takeTouchFromBar()
            switcherTracking = profileSwitcher?.beginTracking(
                from: profileMenuOverlay, over: tabBarController, includesAddProfile: true,
                onSwitch: {}, onAddProfile: { [weak self] in self?.presentAddProfilePlaceholder() }
            )
        case .changed:
            switcherTracking?.move(to: gesture.location(in: nil))
        case .ended:
            switcherTracking?.end()
            switcherTracking = nil
        default:
            switcherTracking = nil
        }
    }
    /// The "+" beside Explore's search, a menu of ways to make a post; a
    /// guest's Sign in in its place (#2489). See `CreateBarItem`.
    private lazy var createItem = CreateBarItem(
        // "New Channel" with the channels on (#2230).
        destinations: CreateDestination.offered(channels: DebugFlags.isOn("-channels")),
        open: { [weak self] destination in self?.openCreate(destination) },
        signIn: { [weak self] in self?.onSignIn() }
    )

    /// Tabs paired with their `AppTab`, in bar order — the lookup `selectTab`
    /// resolves against. Every bar button is in here.
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
    /// account swap their whole stack; every other stack stays where it is, so a guest
    /// who signs in from a pushed screen is still on that screen.
    func viewerDidChange(isMember: Bool) {
        guard isMember != self.isMember else { return }
        self.isMember = isMember
        if !isMember {
            // The next viewer must never see this one's conversations.
            container.chatFeature.forgetViewer()
            // …nor the channels they joined from a showcase (#2216).
            ChannelEmbedLocalState.reset()
        }
        profileTab?.show(member: isMember)
        messagesTab?.show(member: isMember)
        // The bar itself changes shape with the viewer (#626), in place.
        applyBar(animated: true)
        for (_, tab) in orderedTabs {
            (tab as? ExploreTabCoordinator)?.viewerDidChange()
        }
        profileHold.isEnabled = isMember
        sweepOrphanedAccessory()
        loadAvatar()
        refreshUnreadBadge()
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
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
        activeProfileSubscription = container.viewerEvents.onActiveProfileChange { [weak self] _ in
            self?.activeProfileChanged()
        }
        // ⚠️ Opening the drawer reads nothing (#1572): a row is read once
        // SEEN, and the list says so after the server has it — the bells
        // follow then, not when the drawer opens.
        NotificationCenter.default.addObserver(
            self, selector: #selector(notificationsReadDidChange),
            name: .notificationsReadDidChange, object: nil
        )
        // Back in front, the dots read again (#2034): another profile may
        // have been notified meanwhile.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        // A stake's final failure is told (#1775).
        observeLikesGivenBack()
        // Warm the switcher up front: it opens from the last `reload`, so
        // without this the first hold would open on an empty snapshot,
        // offering only "Add Profile", with the viewer's own profiles missing.
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
        }

        let feedFlow = FeedFlowCoordinator(container: container)
        feedFlow.start()
        addChild(feedFlow)
        self.feedFlow = feedFlow

        let profileTab = ProfileTabCoordinator(
            container: container, notificationsBell: notificationsBell, onLogout: onLogout, onSignIn: onSignIn
        )
        self.profileTab = profileTab
        let messagesTab = MessagesTabCoordinator(
            container: container, notificationsBell: notificationsBell, onSignIn: onSignIn
        )
        self.messagesTab = messagesTab
        // Bar order: the three places (`ShellTabs`), in one bubble.
        orderedTabs = [
            (.explore, ExploreTabCoordinator(
                container: container,
                notificationsButtonItem: notificationsBell.makeItem(),
                createItem: createItem
            )),
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
        profileHold.isEnabled = isMember
        popGestureEnablers = orderedTabs.map { NativePopGestureEnabler(taking: $0.1.navigationController) }
        // The blur at the foot of the screen, mirroring the status band's:
        // one per stack, over its screens and under its bars and the tab bar
        // (#1002) — see `BottomEdgeBlurView`.
        for (_, tab) in orderedTabs { BottomEdgeBlurView.install(in: tab.navigationController) }
        applyBar(animated: false)
        // ⚠️ THE APP OPENS ON THE MAP (#2453, the owner 2026-11-15): For You
        // and its Shots left the bar, so the first tab, Explore, is the
        // launch's — it opened on Shots from #1765 until then.
        // `-select-tab N` still overrides it, later in the launch.
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
        // bakes them again, and so does a contrast setting.
        tabBarController.view.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]
        ) { [weak self] (_: UIView, _) in
            self?.notificationsBell.repaint()
            self?.refreshTabGlyphs()
        }
        tabBarController.tabBar.addGestureRecognizer(profileHold)
        // ⚠️ **iOS 27 DRAWS APART THE TAB `prominentTabIdentifier` NAMES**:
        // none, so the bar is one centred bubble, for a member and a guest
        // alike (#2579). With no `UISearchTab` left in the bar, iOS 26 has
        // nothing to detach either. See `ShellTabs`.
        ShellTabs.drawAsOneBubble(tabBarController)
        // Profile's long-press switcher. `UITab` carries no menu of its own —
        // `UITab`, `UITabBar`, `UITabBarItem` and the controller delegate were
        // all checked against the iOS 26 SDK and expose nothing — so it rides
        // an invisible button kept aligned over the tab.
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

    @objc private func notificationsReadDidChange() {
        refreshUnreadBadge()
    }

    private func activeProfileChanged() {
        loadAvatar()
        // ⚠️ A SWITCH IS ANOTHER VIEWER (#892). A sign-out rebuilds what holds
        // the viewer's own graph (`viewerDidChange(isMember:)`); a switch
        // between two profiles of one account never reaches that, so the
        // inbox, the map's people and the bell stayed the
        // previous profile's. The same rebuilds, minus the bar: the viewer is
        // still a member.
        if isMember {
            container.chatFeature.forgetViewer()
            ChannelEmbedLocalState.reset()
            // A fresh inbox stack (its search and suggestions too), primed for
            // the new profile.
            messagesTab?.show(member: true)
            for (_, tab) in orderedTabs {
                (tab as? ExploreTabCoordinator)?.viewerDidChange()
            }
            refreshUnreadBadge()
        }
        // The menu is built on demand from the last `reload`, so refresh the
        // snapshot rather than the menu — there is no menu object to replace.
        Task { [weak self] in
            await self?.profileSwitcher?.reload()
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
            profileTab?.setUnread(false)
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
        // The Profile tab's dot (#2034): any profile of the account, the
        // active one included — the switcher shows which.
        Task { [weak self] in
            guard let self, let switcher = profileSwitcher else { return }
            await switcher.reloadUnreadCounts()
            profileTab?.setUnread(switcher.hasUnreadNotifications)
        }
    }

    @objc private func appWillEnterForeground() {
        refreshUnreadBadge()
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

    /// The bar for this viewer (#626, #2489) — a member's: Explore, Messages
    /// and Profile; a guest's: Explore and Settings, with Sign in in
    /// Explore's top bar (`CreateBarItem`). Nothing in it is a dead end.
    ///
    /// ⚠️ MESSAGES LEAVES THE BAR, it is not greyed out. A disabled tab stood
    /// in a guest's bar doing nothing on tap (and iOS 27 would not even redraw
    /// it on sign-in, #547). A route to Messages still asks a guest to sign up
    /// (`AppRoute.gatedAction`) and lands in the inbox after.
    ///
    /// ⚠️ THE SAME TAB OBJECTS, re-composed with `setTabs` — never rebuilt. The
    /// Profile tab is re-dressed as Settings by its coordinator: the hold and
    /// the switcher's anchor are keyed on it.
    ///
    /// A viewer standing on a tab that leaves (a member on Messages who logs
    /// out) lands on Explore — set before the bar changes, so the bar never
    /// holds a selection it no longer has.
    /// The traits the bars' baked glyphs are drawn for — the tab icons and
    /// the badged bell: the window's, the app's appearance (#1501).
    private var barTraits: UITraitCollection {
        tabBarController.view.window?.traitCollection ?? tabBarController.view.traitCollection
    }

    private func applyBar(animated: Bool) {
        // A guest's tab is Settings, with no switcher behind a long press: the
        // overlay that carries Profile's menu goes, so the tab is the bar's own
        // button — one element for VoiceOver, not a duplicate laid over it.
        profileMenuOverlay.isHidden = !isMember
        let wanted = ShellTabs.tabs(isMember: isMember).compactMap { place in
            orderedTabs.first(where: { $0.0 == place })?.1.tab
        }
        if let selected = tabBarController.selectedTab, !wanted.contains(where: { $0 === selected }),
           let explore = orderedTabs.first(where: { $0.0 == .explore })?.1.tab {
            tabBarController.selectedTab = explore
        }
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
    /// Both faces through `UITab.setFaces`, which a guest's Settings gear
    /// wears too (#2073).
    func refreshTabGlyphs() {
        for (_, coordinator) in orderedTabs {
            guard let glyphTab = coordinator as? any GlyphTab else { continue }
            let tab = glyphTab.tab
            // Baked for the bar's traits (#1501): the app's appearance.
            let traits = barTraits
            let outline = glyphTab.glyph.image(selected: false, badged: glyphTab.hasUnread, traits: traits)
            let fill = glyphTab.glyph.image(selected: true, badged: glyphTab.hasUnread, traits: traits)
            // The same faces (a template between the dark bar and the light):
            // nothing to send, and the bar redraws an item it is handed (#2116).
            if tab.image !== outline || tab.selectedFace !== fill {
                tab.setFaces(outline: outline, fill: fill)
            }
            // The badge said aloud (#1196): an image tells VoiceOver nothing.
            tab.accessibilityValue = glyphTab.hasUnread ? glyphTab.glyph.unreadAccessibilityValue : nil
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

    /// Every tab is a place (#2489: the "+" left the bar), so every
    /// selection is taken. A re-tap on the tab already showing brings its
    /// root back to the top (#1309); UIKit still pops a pushed stack on its
    /// own.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        TabReselect.target(
            tappedSelectedTab: tab === tabBarController.selectedTab,
            stack: tabBarController.selectedViewController as? UINavigationController
        )?.scrollToTopForTabReselect()
        return true
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
    /// Keeps the menu overlay exactly over its bar item: Profile's switcher.
    ///
    /// Runs on every layout pass, so it is cheap and idempotent: it re-adds
    /// nothing already added and writes the frame only when it moved.
    fileprivate func alignMenuOverlays() {
        align(profileMenuOverlay, over: profileTab?.tab)
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
    /// iPhone SE simulator, not one `_UITabButton` labelled — and the tab bar's
    /// "+" of the time crashed opening its menu from an anchor outside any
    /// window.
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

    /// "Use this sound" on a post: the camera, with the sound already chosen.
    fileprivate func openCamera(with sound: PostSound) {
        guard tabBarController.presentedViewController == nil,
              let file = sound.previewURL, file.isFileURL else { return }
        let soundtrack = VideoSoundtrack(fileURL: file, title: sound.title ?? "Original sound")
        tabBarController.present(
            container.uploadFeature.makeCameraViewController(soundtrack: soundtrack), animated: true
        )
    }

    /// Opens one of the "+" menu's destinations.
    ///
    /// PRESENTED over the shell, not pushed onto the current tab: making a
    /// post belongs to no tab, and is finished or abandoned as a whole.
    ///
    /// Internal (not private) only for the +QA hooks.
    func openCreate(_ destination: CreateDestination) {
        // Posting needs an account: a guest signs up first, then lands on the
        // screen they chose. Every "+" entry (the menu, the debug hook) comes
        // through here.
        MemberGates.perform(.create, from: tabBarController) { [weak self] in
            self?.presentCreate(destination)
        }
    }

    private func presentCreate(_ destination: CreateDestination) {
        // A second presentation would be refused. The bar cannot be tapped
        // under one, so this only ever turns away the debug hook.
        guard tabBarController.presentedViewController == nil else { return }
        let screen: UIViewController? = switch destination {
        case .camera: container.uploadFeature.makeCameraViewController(soundtrack: nil)
        case .upload: container.uploadFeature.makeMediaUploadViewController()
        case .text: container.uploadFeature.makeTextPostViewController()
        // The channel's creation sheet (#2230): Create lands in Messages,
        // on Chats, with the thread pushed (Chat routes it). Nil with the
        // channels off, where the menu never offers it.
        case .channel: container.chatFeature.makeChannelCreationViewController()
        }
        guard let screen else { return }
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
        if let covering = tabBarController.presentedViewController {
            tabBarController.dismiss(presented: covering)
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
        if let covering = tabBarController.presentedViewController {
            tabBarController.dismiss(presented: covering)
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

// MARK: - The Profile tab's hold (#2034)

extension MainTabCoordinator: UIGestureRecognizerDelegate {
    /// Only touches on the Profile tab, from a member, with nothing covering
    /// the bar.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === profileHold, isMember, tabBarController.presentedViewController == nil,
              let tab = profileTab?.tab, let bar = gestureRecognizer.view,
              let frame = tab.frame(in: bar), !frame.isEmpty,
              frame.contains(touch.location(in: bar)) else { return false }
        profileHoldTouch = touch
        return true
    }

    /// The hold and the bar's own recognizers, on the same view, follow the
    /// same touch: the bar's selection keeps its press response and its tap
    /// (see `profileHold`).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === profileHold && otherGestureRecognizer.view === gestureRecognizer.view
    }

    /// The hold is recognized: every other recognizer of the bar following
    /// its touch is cancelled — disabled and enabled again, the public way —
    /// so the lens returns to the selected tab and the lift selects nothing.
    fileprivate func takeTouchFromBar() {
        let bar = tabBarController.tabBar
        for recognizer in profileHoldTouch?.gestureRecognizers ?? []
        where recognizer !== profileHold && recognizer.view === bar {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }
}
