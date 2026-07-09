import CoreNavigation
import UIKit

/// A coordinator that owns one tab of the main tab bar: its own navigation
/// stack and tab bar item. `MainTabCoordinator` composes these; each is free
/// to push/present within its own `navigationController` without knowing about
/// the others (cross-tab moves go through the router).
@MainActor
protocol TabCoordinator: Coordinator {
    /// The navigation controller shown for this tab: the stack routed
    /// destinations are pushed onto, and the content vended by `tab`.
    var navigationController: UINavigationController { get }

    /// The tab this coordinator contributes to the bar. Built once and owned by
    /// the coordinator (so it can, e.g., update its own badge). `MainTabCoordinator`
    /// collects these into `UITabBarController.tabs`.
    var tab: UITab { get }
}
