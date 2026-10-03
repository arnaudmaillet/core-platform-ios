import CoreModels
import CoreNavigation
import UIKit

/// Notifications as a LEFT DRAWER behind the whole shell — the tab bar
/// controller slides right to reveal them, the way the Claude and ChatGPT iOS
/// apps reveal their sidebar. It replaced a push onto the selected tab's stack.
///
/// The mechanics are CoreNavigation's `SideDrawerContainerViewController` (see
/// its header for why a custom container: UIKit has no sidebar that shows on
/// an iPhone). This object is the shell's half: what goes in the drawer, WHEN
/// the edge may open it, and what opening it means for the bell.
///
/// ## Where the left edge belongs to the drawer
///
/// Only on a tab ROOT — Explore, For You, Messages, Profile — at rest:
/// - on a pushed screen the edge is the stack's own back swipe (see
///   `NativePopGestureEnabler`), and the drawer must not compete with it;
/// - with anything presented over the shell (a sheet, the composer, a
///   wallet), the drawer is covered and must not open under it;
/// - mid-push, mid-pop or mid tab switch, nothing may start.
///
/// The bell stands only on those same roots, so the button and the edge agree
/// on where notifications are reachable.
@MainActor
final class NotificationsDrawer {
    let container: SideDrawerContainerViewController
    private unowned let tabBarController: UITabBarController

    /// - Parameters:
    ///   - list: the notifications screen. Wrapped in its own navigation
    ///     controller here, for its large title; routes it emits go through
    ///     the router onto the TAB stacks, never onto this one.
    ///   - onDidOpen: the drawer settled open — the viewer has seen the list.
    init(
        tabBarController: UITabBarController,
        list: UIViewController,
        onDidOpen: @escaping () -> Void
    ) {
        self.tabBarController = tabBarController
        let navigation = UINavigationController(rootViewController: list)
        navigation.navigationBar.prefersLargeTitles = true
        container = SideDrawerContainerViewController(main: tabBarController, drawer: navigation)
        container.dimmingAccessibilityLabel = "Close notifications"
        container.onDidOpen = onDidOpen
        // A guest has no notifications: the edge swipe stays shut for them (the
        // bell asks them to sign up instead). The bell's own `open()` is left
        // ungated, so it opens the drawer once they have.
        container.canOpenInteractively = { [weak self, weak tabBarController] in
            guard let self, let tabBarController else { return false }
            return edgeBelongsToDrawer && MemberGates.gate(from: tabBarController)?.isMember != false
        }
    }

    var isOpen: Bool { container.isOpen }

    /// The bell's action.
    func open() {
        guard edgeBelongsToDrawer else { return }
        container.open(animated: true)
    }

    func close(completion: (() -> Void)? = nil) {
        container.close(animated: true, completion: completion)
    }

    /// True on a tab root at rest with nothing over it. See the type's header.
    var edgeBelongsToDrawer: Bool {
        guard tabBarController.presentedViewController == nil,
              tabBarController.transitionCoordinator == nil,
              let stack = tabBarController.selectedViewController as? UINavigationController,
              stack.viewControllers.count == 1,
              stack.transitionCoordinator == nil else { return false }
        return true
    }
}
