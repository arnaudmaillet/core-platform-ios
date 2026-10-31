import UIKit

/// A presented screen that says itself whether it hides the screens under it
/// (#1970): a sheet that can change height while it stays up, which the
/// window cannot see. CoreNavigation's `ScreenCovers` reads it, and pauses
/// the clips it hides; every other presentation is read by default.
///
/// By default it covers at the large detent — its own sheet's, or its
/// stack's. It calls `coverChanged()` whenever that may have changed: its
/// sheet's delegate hears a drag settle, and a programmatic change tells no
/// one.
///
/// Here, below CoreNavigation, so any package's sheet can declare itself.
@MainActor
public protocol ScreenCovering: UIViewController {
    /// Whether it hides the screens under it now: a sheet expanded, never
    /// one collapsed.
    var coversScreen: Bool { get }
}

public extension ScreenCovering {
    var coversScreen: Bool {
        guard let sheet = (navigationController ?? self).sheetPresentationController else { return true }
        return (sheet.selectedDetentIdentifier ?? sheet.detents.first?.identifier ?? .large) == .large
    }

    /// Tells the window's covers to read this screen again.
    func coverChanged() {
        NotificationCenter.default.post(name: ScreenCoveringNotification.didChange, object: self)
    }
}

/// What `ScreenCovering.coverChanged()` posts, with the screen as its object.
public enum ScreenCoveringNotification {
    public static let didChange = Notification.Name("ScreenCovering.didChange")
}
