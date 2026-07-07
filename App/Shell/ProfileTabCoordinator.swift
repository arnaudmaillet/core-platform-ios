import CoreNavigation
import ProfileInterface
import UIKit

/// Owns the Profile tab: the signed-in viewer's own profile, which also hosts
/// the Log Out affordance (moved here from the feed).
@MainActor
final class ProfileTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let container: AppContainer
    private let onLogout: () -> Void

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
    }

    func start() {
        let profileViewController = container.profileFeature.makeCurrentUserProfileViewController(onLogout: onLogout)
        navigationController.viewControllers = [profileViewController]
        // The profile VC sets its own title ("Profile"), which UIKit proxies
        // onto the tab bar item; match it here so the tab reads consistently.
        navigationController.tabBarItem = UITabBarItem(
            title: "Profile",
            image: UIImage(systemName: "person.crop.circle"),
            selectedImage: UIImage(systemName: "person.crop.circle.fill")
        )
    }
}
