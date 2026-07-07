import CoreModels
import CoreNavigation
import UIKit

/// Owns the Profile tab. Placeholder until the profile feature is built; for
/// now it shows the signed-in account and hosts Log Out (which moved here from
/// the feed).
@MainActor
final class ProfileTabCoordinator: TabCoordinator {
    var childCoordinators: [Coordinator] = []
    let navigationController = UINavigationController()

    private let accountID: AccountID
    private let onLogout: () -> Void

    init(accountID: AccountID, onLogout: @escaping () -> Void) {
        self.accountID = accountID
        self.onLogout = onLogout
    }

    func start() {
        let placeholder = PlaceholderViewController(
            title: "Profile",
            systemImage: "person.crop.circle",
            message: "Signed in as \(accountID.rawValue)",
            actionTitle: "Log Out",
            action: onLogout
        )
        navigationController.viewControllers = [placeholder]
        navigationController.tabBarItem = UITabBarItem(
            title: "Profile",
            image: UIImage(systemName: "person.crop.circle"),
            selectedImage: UIImage(systemName: "person.crop.circle.fill")
        )
    }
}
