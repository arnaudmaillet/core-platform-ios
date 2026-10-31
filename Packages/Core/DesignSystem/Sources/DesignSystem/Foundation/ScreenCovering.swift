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
        return ScreenCoveringSheet.coversAtLarge(
            selected: sheet.selectedDetentIdentifier, detents: sheet.detents.map(\.identifier)
        )
    }

    /// Tells the window's covers to read this screen again.
    func coverChanged() {
        NotificationCenter.default.post(name: ScreenCoveringNotification.didChange, object: self)
    }
}

/// The one reading of a sheet's height as a cover (#1970), shared by the
/// declared default and CoreNavigation's default table.
public enum ScreenCoveringSheet {
    /// A sheet covers at `.large()`. With no detent selected, UIKit shows the
    /// SMALLEST of its detents — not the first listed — so it covers then
    /// only when every detent is large (no detents at all means `.large()`).
    /// Pure, for tests.
    public static func coversAtLarge(
        selected: UISheetPresentationController.Detent.Identifier?,
        detents: [UISheetPresentationController.Detent.Identifier]
    ) -> Bool {
        if let selected { return selected == .large }
        return detents.allSatisfy { $0 == .large }
    }
}

/// What `ScreenCovering.coverChanged()` posts, with the screen as its object.
public enum ScreenCoveringNotification {
    public static let didChange = Notification.Name("ScreenCovering.didChange")
}
