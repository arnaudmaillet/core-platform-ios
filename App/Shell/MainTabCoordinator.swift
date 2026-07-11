import CoreNavigation
import UIKit

/// The authenticated app shell: a `UITabBarController` composed of one child
/// `TabCoordinator` per tab. Each tab owns its own navigation stack; this
/// coordinator only assembles them and holds them alive.
///
/// Tabs are set via the modern `UITabBarController.tabs` API. The Search tab is
/// a `UISearchTab`, which the system detaches to the trailing edge, producing
/// the grouped bar `| Maps  Feed  Messages  Profile |  Search |` natively.
@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []
    let tabBarController = UITabBarController()

    private let container: AppContainer
    private let onLogout: () -> Void
    private let profileTab: ProfileTabCoordinator
    /// Tabs paired with their `AppTab`, in bar order — the lookup `selectTab`
    /// and the `-select-tab` debug hook resolve against.
    private var orderedTabs: [(AppTab, any TabCoordinator)] = []

    init(container: AppContainer, onLogout: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
        self.profileTab = ProfileTabCoordinator(container: container, onLogout: onLogout)
        super.init()
    }

    func start() {
        orderedTabs = [
            (.maps, MapsTabCoordinator(container: container)),
            (.feed, FeedTabCoordinator(container: container)),
            (.messages, MessagesTabCoordinator(container: container)),
            (.profile, profileTab),
            (.search, SearchTabCoordinator(container: container))
        ]
        for (_, tab) in orderedTabs {
            tab.start()
            addChild(tab)
        }
        tabBarController.tabs = orderedTabs.map { $0.1.tab }
        tabBarController.delegate = self

        #if DEBUG
        // Dev convenience: `-select-tab N` opens directly on a tab for testing
        // (0 = Maps … 4 = Search).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-select-tab"), index + 1 < arguments.count,
           let tabIndex = Int(arguments[index + 1]), orderedTabs.indices.contains(tabIndex) {
            tabBarController.selectedTab = orderedTabs[tabIndex].1.tab
        }
        #endif
    }
}

// MARK: - Badge refresh

extension MainTabCoordinator: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        // Re-read the unread count on every tab switch, so the Profile badge
        // reflects state after the user reads/marks notifications in Activity.
        profileTab.refreshBadge()
    }
}

// MARK: - AppNavigating

extension MainTabCoordinator: AppNavigating {
    var activeNavigationController: UINavigationController? {
        tabBarController.selectedViewController as? UINavigationController
    }

    func selectTab(_ tab: AppTab) {
        guard let match = orderedTabs.first(where: { $0.0 == tab }) else { return }
        tabBarController.selectedTab = match.1.tab
    }
}
