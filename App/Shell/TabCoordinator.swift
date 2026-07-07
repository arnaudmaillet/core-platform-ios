import CoreNavigation
import UIKit

/// A coordinator that owns one tab of the main tab bar: its own navigation
/// stack and tab bar item. `MainTabCoordinator` composes these; each is free
/// to push/present within its own `navigationController` without knowing about
/// the others (cross-tab moves go through the router).
@MainActor
protocol TabCoordinator: Coordinator {
    /// The navigation controller shown for this tab (becomes one of the tab
    /// bar's view controllers). Its `tabBarItem` is configured in `start()`.
    var navigationController: UINavigationController { get }
}
