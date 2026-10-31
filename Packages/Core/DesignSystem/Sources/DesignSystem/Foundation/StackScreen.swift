import UIKit

/// How a pushed screen is left (#1144) — what it declares as a
/// `StackScreen`.
public enum ScreenLeaving: Sendable, Equatable {
    /// UIKit's way back: the back button, the edge swipe, and the
    /// full-surface swipe where the screen lets it begin (`ContentPopGating`
    /// in CoreNavigation: the regions it keeps, a pager or a carousel with a
    /// page to its left, #691).
    case nativeBack
    /// Its own gesture: a hero zoom or grab, or a full-width slide, driven by
    /// its transition owner (`ZoomTransitionDestination`). No native back
    /// swipe ever races it.
    case ownGesture
    /// Only its own controls — Cancel, Done, a step's button: no back button
    /// and no back swipe, for as long as it says so (a step at work, a search
    /// field).
    case controlsOnly
}

/// A screen pushed onto a navigation stack, stating how it is left (#1144):
/// every pushed screen declares one, and `StackScreenGuardTests`
/// (CoreNavigation) lists the screens that do not.
///
/// CoreNavigation's `NativePopPolicy` reads it: a screen that does not say
/// `.nativeBack` never gets a native back swipe, whatever its other signals.
/// It is read per swipe, so a screen can change its answer — a step that
/// hides its back button while it works.
///
/// Here, below CoreNavigation, so any package's screen can declare itself.
@MainActor
public protocol StackScreen: UIViewController {
    /// How this screen is left, now.
    var leaving: ScreenLeaving { get }
}

public extension ScreenLeaving {
    /// `.nativeBack`, unless `item` hides its back button — then only the
    /// screen's own controls leave it.
    @MainActor
    static func nativeBack(unlessHiddenIn item: UINavigationItem) -> ScreenLeaving {
        item.hidesBackButton ? .controlsOnly : .nativeBack
    }
}
