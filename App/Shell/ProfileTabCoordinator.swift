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
///   and its own profile switcher (see `ProfileFeatureBuilding`). That is why
///   losing the avatar's long-press menu does not lose the switcher.
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
    private let onLogout: () -> Void

    private(set) lazy var tab = UITab(
        title: "Profile",
        image: Self.placeholder,
        identifier: AppTab.profile.rawValue
    ) { [navigationController] _ in navigationController }

    private static let placeholder = UIImage(systemName: "person.crop.circle")

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
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
        navigationController.viewControllers = [
            container.profileFeature.makeCurrentUserProfileViewController(
                onLogout: onLogout,
                identityStub: nil,
                trayPlacement: .aboveBottomSafeArea
            )
        ]
    }

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
