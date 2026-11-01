import UIKit

/// Entry point contract for the Notifications (Activity) feature. The app shell
/// depends on this interface package — never on the implementation — so editing
/// Notifications internals recompiles nothing but Notifications itself.
@MainActor
public protocol NotificationsFeatureBuilding {
    /// The notifications list, as the shell's left drawer shows it. Tapping a
    /// row routes to its subject (a post or a profile) via the injected
    /// `Router`. It carries its own title; the host wraps it in a navigation
    /// controller. Its appearance callbacks drive "seen": it marks a row read
    /// once the row has been on screen with the list APPEARED, so a host must
    /// forward them for real (a drawer that only peeks marks nothing). Each
    /// time rows are read it posts `.notificationsReadDidChange`.
    func makeNotificationsViewController() -> UIViewController

    /// The viewer's unread count for the tab badge. Best-effort: returns 0 when
    /// it can't be read, so the badge never blocks or errors.
    func unreadCount() async -> Int

    /// One profile of the viewer's account's unread count (#2034), for the
    /// Profile tab's dot and the switcher's rows — `GetUnreadCount` takes
    /// any profile the account owns. Nil when it can't be read: a count not
    /// known is drawn as none, never as zero.
    func unreadCount(forProfile profileID: String) async -> Int?
}

extension Notification.Name {
    /// Rows were marked read on the server (#1572): the unread count fell,
    /// so a badge reads it again. Posted on the main queue.
    public static let notificationsReadDidChange = Notification.Name("NotificationsReadDidChange")
}
