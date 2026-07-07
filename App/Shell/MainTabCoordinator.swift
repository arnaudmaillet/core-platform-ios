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
    private let onLogout: () -> Void

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
    }

    func start() {
        let tabs: [any TabCoordinator] = [
            FeedTabCoordinator(container: container),
            SearchTabCoordinator(),
            NotificationsTabCoordinator(),
            ProfileTabCoordinator(container: container, onLogout: onLogout)
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

// MARK: - AppNavigating

extension MainTabCoordinator: AppNavigating {
    var activeNavigationController: UINavigationController? {
        tabBarController.selectedViewController as? UINavigationController
    }

    func selectTab(_ tab: AppTab) {
        guard tabBarController.viewControllers?.indices.contains(tab.rawValue) == true else { return }
        tabBarController.selectedIndex = tab.rawValue
    }
}
