import CoreNavigation
import ProfileInterface
import DesignSystem
import SettingsInterface
import UIKit

/// Owns the Profile tab: the signed-in viewer's own profile as a root
/// destination, on its own navigation stack.
///
/// This replaced the avatar button in the map's navigation bar (the Explore
/// tab, then called Maps), which pushed the same screen onto that stack.
/// Being a *tab root* rather than a pushed screen changes two things that are
/// easy to miss:
///
/// - **This is the canonical entry point**, so it is built with a non-nil
///   `onLogout` — which is also what makes the screen carry the settings gear
///   and its own profile switcher (see `ProfileFeatureBuilding`). That is why
///   losing the avatar's long-press menu does not lose the switcher.
/// - **Its root is built once per viewer**, where the pushed profile is built
///   per push and released on pop. A tab root cannot be rebuilt on every visit
///   without throwing away scroll position and gallery state on every tab
///   switch, so freshness has to come from the repositories and the image
///   cache. It IS rebuilt when the viewer changes (`show(member:)`): a guest
///   has no profile — their tab is Settings (#626) — and a sign-in or
///   sign-out swaps the whole stack.
/// - **The shell outlives the session.** Logging out returns to guest mode in
///   the same shell rather than to a login screen (guest mode, #438).
@MainActor
final class ProfileTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    /// ⚠️ THE ONE TAB STACK THAT PREFERS LARGE TITLES (#1906), so Settings
    /// can wear its large "Settings". A screen on it shows one if it states
    /// `.always` (only Settings does) or inherits it, left `.automatic`, from
    /// the screen it was pushed from. The own profile states `.never`, and so
    /// does every screen Settings pushes.
    let navigationController: UINavigationController = {
        let navigation = ArbitratedNavigationController()
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }()

    private let container: AppContainer
    /// The shell's bell, minted into this header's leading edge — the ROOT's
    /// only: a pushed profile leads with its back button.
    private let notificationsBell: NotificationsBell
    private let onLogout: () -> Void
    private let onSignIn: () -> Void

    private(set) lazy var tab: UITab = {
        let tab = UITab(
            title: "Profile",
            image: nil,
            identifier: AppTab.profile.rawValue
        ) { [navigationController] _ in navigationController }
        tab.setFaces(outline: Self.placeholder?.outline, fill: Self.placeholder?.fill)
        return tab
    }()

    /// ⚠️ OUTLINE AND FILL, AS THE GLYPH TABS (#2073): a plain symbol image
    /// on a tab is drawn filled in both states by the bar. The person until
    /// the avatar arrives.
    private static let placeholder = TabFaces.system(outline: "person.crop.circle", fill: "person.crop.circle.fill")
    /// A guest's tab: Settings, wearing the gear the guest Profile page used to
    /// carry in its header (#626) — its outline, and its fill when selected:
    /// the owner's gear (#2433).
    private static let guestSettingsFaces = TabFaces.app(outline: .settings, fill: .settingsFill)
    /// Whether the tab is a guest's Settings — so an avatar reset cannot put
    /// the person glyph back over the gear.
    private var showsGuestSettings = false

    init(
        container: AppContainer,
        notificationsBell: NotificationsBell,
        onLogout: @escaping () -> Void,
        onSignIn: @escaping () -> Void
    ) {
        self.container = container
        self.notificationsBell = notificationsBell
        self.onLogout = onLogout
        self.onSignIn = onSignIn
    }

    /// `TabCoordinator` conformance; the shell calls `show(member:)` instead.
    func start() {
        show(member: true)
    }

    /// Installs the root for this viewer, replacing the whole stack: the own
    /// profile for a member, the guest Settings for a guest (#626).
    func show(member: Bool) {
        guard member else {
            #if DEBUG
            walletSheetHook = nil
            #endif
            // ⚠️ A GUEST'S TAB IS SETTINGS ITSELF (#626), not a sign-up page with
            // Settings behind a gear: a guest has no profile, and the Sign in
            // beside Explore's search is the way in (#2489). The settings a guest can use —
            // preferences, help, legal — are the tab's root.
            showsGuestSettings = true
            tab.title = "Settings"
            // Said outright: a title changed on an item already in the bar
            // left VoiceOver reading the old name (the #547 family).
            tab.accessibilityLabel = "Settings"
            tab.setFaces(outline: Self.guestSettingsFaces?.outline, fill: Self.guestSettingsFaces?.fill)
            let settings = container.settingsFeature.makeGuestSettingsViewController(onSignIn: onSignIn)
            // ⚠️ THE BAR STAYS. The screen asks to hide it when PUSHED ("not a
            // fifth tab"), and here it is a tab's root: the bar is how a guest
            // leaves it. Its sub-pages push on this stack as before.
            settings.hidesBottomBarWhenPushed = false
            navigationController.viewControllers = [settings]
            return
        }
        showsGuestSettings = false
        tab.title = "Profile"
        tab.accessibilityLabel = "Profile"
        // The person until this viewer's avatar arrives (`setAvatar`), and
        // never the gear's fill left behind as the selected face.
        avatar = nil
        applyAvatar()
        // `.aboveBottomSafeArea` is the whole difference between a tab root and
        // a pushed profile: `hidesBottomBarWhenPushed` is left off so the bar
        // that gets you out of this tab stays — alone, with no accessory
        // (#2475: the selector is in the header, then in the bar).
        let profile = container.profileFeature.makeCurrentUserProfileViewController(
            onLogout: onLogout,
            identityStub: nil,
            trayPlacement: .aboveBottomSafeArea
        )
        navigationController.viewControllers = [profile]
        // The bar reads `[🔔] … [✎][⋯ ⚙]` (#2475): the bell leads, the screen
        // composes the rest. No balance on a profile (#2475, revising #2336):
        // the wallet is Settings' (Wallet and Purchases).
        (profile as? any HeaderAccessoryHosting)?
            .setLeadingAccessoryItem(notificationsBell.makeItem())
        #if DEBUG
        // `-open-wallet` (QA, `WalletSheetUITests`): no root wears a badge any
        // more, so a badge nobody shows answers the hook from this tab.
        walletSheetHook = container.makeWalletBadge(presenter: navigationController) { _ in }
        #endif
    }

    #if DEBUG
    /// `-open-wallet`'s installer: its badge is never shown (#2475).
    private var walletSheetHook: AnyObject?
    #endif

    /// Shows the viewer's own avatar as the tab's icon, falling back to the
    /// glyph when there isn't one.
    ///
    /// `.alwaysOriginal` matters: a tab image is a template by default, so an
    /// avatar handed over untouched renders as a flat silhouette in the tint
    /// colour — the photo is there and invisible, which reads as a broken image
    /// rather than a wrong render mode.
    func setAvatar(_ image: UIImage?) {
        avatar = image
        applyAvatar()
    }

    /// Whether a profile of the account has an unread notification (#2034):
    /// the bar's dot, cut into the avatar as the glyph tabs wear theirs.
    func setUnread(_ unread: Bool) {
        guard unread != hasUnread else { return }
        hasUnread = unread
        applyAvatar()
    }

    /// The avatar as the bar last received it, circular and `avatarSide` across.
    private var avatar: UIImage?
    private var hasUnread = false

    private func applyAvatar() {
        // A guest's tab is Settings: its gear is not an avatar placeholder.
        guard !showsGuestSettings else { return }
        // ⚠️ ONE BOX FOR BOTH STATES (#2034): the avatar is drawn into the
        // badged box whether the dot shows or not, so it never moves.
        if let avatar {
            // The avatar in both states: no selected face.
            tab.setFaces(outline: TabAvatarBadge.image(avatar: avatar, badged: hasUnread), fill: nil)
        } else {
            tab.setFaces(outline: Self.placeholder?.outline, fill: Self.placeholder?.fill)
        }
        // What VoiceOver hears with the dot, as the glyph tabs (#1196).
        tab.accessibilityValue = hasUnread && avatar != nil ? "New notifications" : nil
    }
}
