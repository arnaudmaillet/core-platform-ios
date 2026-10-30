import CoreModels
import CoreNavigation
import DesignSystem
import UIKit

/// Notifications as a LEFT DRAWER behind the whole shell — the tab bar
/// controller slides right to reveal them, the way the Claude and ChatGPT iOS
/// apps reveal their sidebar. It replaced a push onto the selected tab's stack.
///
/// The mechanics are CoreNavigation's `SideDrawerContainerViewController` (see
/// its header for why a custom container: UIKit has no sidebar that shows on
/// an iPhone). This object is the shell's half: what goes in the drawer, WHEN
/// the edge may open it.
///
/// ## How a finger opens it
///
/// ⚠️ AS "PAGE −1" OF THE TAB ROOTS' PAGERS (#1739, the owner 2026-10-25), not
/// by an edge swipe: For You, Messages and Profile page between tabs, and
/// pulling past the FIRST tab opens the drawer with that same gesture
/// (`DrawerPull`, `LeadingPullTarget`) — the tabs' own pan, with their
/// priority over the content. Explore (the map) opens it from the bell only.
///
/// And only on a tab ROOT at rest:
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
    init(tabBarController: UITabBarController, list: UIViewController) {
        self.tabBarController = tabBarController
        let navigation = ChevronBackNavigationController(rootViewController: list)
        navigation.navigationBar.prefersLargeTitles = true
        // The blur at the foot of the screen the tab stacks wear (#1002),
        // on the drawer's own stack too (#1576): over its screens, under its
        // bars and its toolbar, at the drawer's width — once, so a screen
        // pushed in the drawer wears it as well.
        BottomEdgeBlurView.install(in: navigation)
        container = SideDrawerContainerViewController(main: tabBarController, drawer: navigation)
        container.dimmingAccessibilityLabel = "Close notifications"
        container.openRegion = .hostDriven
        DrawerPull.shared.drawer = container
        // The screen it slides aside is still on screen but not watched: its
        // media pauses (#1703, the owner: the feed played on behind it).
        container.onDidOpen = { [weak self] in self?.onSetAsideChange?(true) }
        container.onDidClose = { [weak self] in self?.onSetAsideChange?(false) }
        // And as it moves (#1914): the clip fades with the share of the
        // screen left showing, and pauses at half — the rule of every screen
        // that covers another.
        container.onMainShareChange = { [weak self] share in self?.onMainShareChange?(share) }
        // A guest has no notifications: the edge swipe stays shut for them (the
        // bell asks them to sign up instead). The bell's own `open()` is left
        // ungated, so it opens the drawer once they have.
        container.canOpenInteractively = { [weak self, weak tabBarController] in
            guard let self, let tabBarController else { return false }
            return edgeBelongsToDrawer && MemberGates.gate(from: tabBarController)?.isMember != false
        }
    }

    var isOpen: Bool { container.isOpen }

    /// The main screen was set aside (true: the drawer is opening or open) or
    /// brought back (false: closed).
    var onSetAsideChange: ((Bool) -> Void)?
    /// The share of the main screen still showing, 0…1, frame by frame.
    var onMainShareChange: ((CGFloat) -> Void)?

    #if DEBUG
    /// How many foot blurs the drawer's stack carries — one (#1576). QA.
    var debugBottomBlurCount: Int {
        (container.drawerViewController as? UINavigationController)?.viewIfLoaded?.subviews
            .filter { $0 is BottomEdgeBlurView }.count ?? 0
    }
    #endif

    /// The bell's action.
    func open() {
        guard edgeBelongsToDrawer else { return }
        // The media fades and pauses with the slide (`onMainShareChange`,
        // #1914), no longer at the tap.
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
