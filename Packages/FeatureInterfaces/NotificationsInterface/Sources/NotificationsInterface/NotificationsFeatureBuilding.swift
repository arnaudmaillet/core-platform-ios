import UIKit

/// Entry point contract for the Notifications (Activity) feature. The app shell
/// depends on this interface package — never on the implementation — so editing
/// Notifications internals recompiles nothing but Notifications itself.
@MainActor
public protocol NotificationsFeatureBuilding {
    /// The activity list for the Notifications tab. Tapping a row routes to its
    /// subject (a post or a profile) via the injected `Router`.
    func makeNotificationsViewController() -> UIViewController

    /// The viewer's unread count for the tab badge. Best-effort: returns 0 when
    /// it can't be read, so the badge never blocks or errors.
    func unreadCount() async -> Int
}
