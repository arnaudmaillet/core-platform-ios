import CoreNavigation
import ProfileInterface
import UIKit

/// Owns the Profile tab: the signed-in viewer's own profile as a root
/// destination, on its own navigation stack.
///
/// This replaced the avatar button in the Maps navigation bar, which pushed the
/// same screen onto the Maps stack. Being a *tab root* rather than a pushed
/// screen changes two things that are easy to miss:
///
/// - **This is the canonical entry point**, so it is built with a non-nil
///   `onLogout` — which is also what makes the screen carry the settings gear
///   and Share (see `ProfileFeatureBuilding`). The profile switcher is this
///   tab's long press (`MainTabCoordinator.profileMenuOverlay`), which is why
///   neither the avatar's old long-press menu nor the header's old switcher
///   button took it away.
/// - **It is built once and retained for the session**, where the pushed profile
///   is built per push and released on pop. A tab root cannot be rebuilt on
///   every visit without throwing away scroll position and gallery state on
///   every tab switch, so freshness has to come from the repositories and the
///   image cache — which is where it already lives.
@MainActor
final class ProfileTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    /// The shell's bell, minted into this header's leading edge — the ROOT's
    /// only: a pushed profile leads with its back button.
    private let notificationsBell: NotificationsBell
    private let onLogout: () -> Void

    private(set) lazy var tab = UITab(
        title: "Profile",
        image: Self.placeholder,
        identifier: AppTab.profile.rawValue
    ) { [navigationController] _ in navigationController }

    private static let placeholder = UIImage(systemName: "person.crop.circle")

    init(
        container: AppContainer,
        notificationsBell: NotificationsBell,
        onLogout: @escaping () -> Void
    ) {
        self.container = container
        self.notificationsBell = notificationsBell
        self.onLogout = onLogout
    }

    func start() {
        // `.aboveBottomSafeArea` is the whole difference between a tab root and
        // a pushed profile, and it settles both halves at once: the tray is
        // hosted in the screen's own view above the bottom safe area (the top of
        // the tab bar), and `hidesBottomBarWhenPushed` is left off so the bar
        // that gets you out of this tab stays. The navigation toolbar cannot be
        // made to clear a tab bar from out here — measured three ways: it
        // positions against the window's bottom safe area, reports a zeroed safe
        // area of its own, and ignores both `additionalSafeAreaInsets` on the
        // navigation controller and its own layout margins.
        let profile = container.profileFeature.makeCurrentUserProfileViewController(
            onLogout: onLogout,
            identityStub: nil,
            trayPlacement: .aboveBottomSafeArea
        )
        navigationController.viewControllers = [profile]
        // The header reads `[bell][filter] … [coins][share settings]`. The bell
        // leads, ahead of the source filter the screen composes itself.
        (profile as? any HeaderAccessoryHosting)?
            .setLeadingAccessoryItem(notificationsBell.makeItem())
        // The balance, inboard of the share + settings pair — the same
        // installer every root header uses.
        //
        // ⚠️ A PUSHED PROFILE WEARS ONE TOO NOW, and did not before: the rule
        // was "a pushed profile is someone else's, and a viewer's balance has
        // no business on it". The balance is the viewer's wherever they stand
        // — the post screen and the search results already said so — and the
        // header was asked to carry it everywhere. A pushed profile has no
        // coordinator, so its installer hangs on the screen itself; see
        // `RouteResolver`'s `.profile` case and `WalletBadgeInstaller.attach`.
        walletBadge = WalletBadgeInstaller(
            wallet: container.walletStore,
            presenter: navigationController,
            makeSheet: { [unowned container] in container.makeWalletSheet() }
        ) { [weak profile] item in
            (profile as? (any HeaderAccessoryHosting))?.setTrailingAccessoryItem(item)
        }
    }

    /// The header's balance badge. Held for the coordinator's life, which is
    /// the process's.
    private var walletBadge: WalletBadgeInstaller?

    /// Shows the viewer's own avatar as the tab's icon, falling back to the
    /// glyph when there isn't one.
    ///
    /// `.alwaysOriginal` matters: a tab image is a template by default, so an
    /// avatar handed over untouched renders as a flat silhouette in the tint
    /// colour — the photo is there and invisible, which reads as a broken image
    /// rather than a wrong render mode.
    func setAvatar(_ image: UIImage?) {
        tab.image = image ?? Self.placeholder
    }
}
