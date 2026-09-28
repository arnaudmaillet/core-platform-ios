import UIKit

/// Entry point contract for the Notifications (Activity) feature. The app shell
/// depends on this interface package — never on the implementation — so editing
/// Notifications internals recompiles nothing but Notifications itself.
@MainActor
public protocol NotificationsFeatureBuilding {
    /// The notifications list, as the shell's left drawer shows it. Tapping a
    /// row routes to its subject (a post or a profile) via the injected
    /// `Router`. It carries its own title; the host wraps it in a navigation
    /// controller. Its appearance callbacks drive "seen": it marks the new
    /// rows read once it has APPEARED, so a host must forward them for real
    /// (a drawer that only peeks marks nothing).
    func makeNotificationsViewController() -> UIViewController

    /// The viewer's unread count for the tab badge. Best-effort: returns 0 when
    /// it can't be read, so the badge never blocks or errors.
    func unreadCount() async -> Int
}
