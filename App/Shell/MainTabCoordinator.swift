import CoreModels
import CoreNavigation
import UIKit

/// The authenticated app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
@MainActor
final class MainTabCoordinator: Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = UITabBarController()

    private let container: AppContainer
    private let accountID: AccountID
    private let onLogout: () -> Void

    init(container: AppContainer, accountID: AccountID, onLogout: @escaping () -> Void) {
        self.container = container
        self.accountID = accountID
        self.onLogout = onLogout
    }

    func start() {
        let tabs: [any TabCoordinator] = [
            FeedTabCoordinator(container: container),
            SearchTabCoordinator(),
            NotificationsTabCoordinator(),
            ProfileTabCoordinator(accountID: accountID, onLogout: onLogout)
        ]
        for tab in tabs {
            tab.start()
            addChild(tab)
        }
        tabBarController.viewControllers = tabs.map(\.navigationController)

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), tabBarController.viewControllers?.indices.contains(tabIndex) == true {
            tabBarController.selectedIndex = tabIndex
        }
        #endif
    }
}
