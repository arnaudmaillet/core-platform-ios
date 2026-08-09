import Foundation

/// Whether the native edge-swipe-to-pop may begin, as a pure decision.
///
/// Lives here rather than in the app's gesture delegate because it is POLICY,
/// and policy is the part that was wrong: the delegate inferred "this screen
/// owns its dismissal" from a type conformance, which stopped being true the
/// day text posts went back to an ordinary push. A pure function can be
/// tested; a `UIGestureRecognizerDelegate` reached only by a real finger
/// cannot, and this app cannot synthesise one — the simulator does not accept
/// injected touches.
public enum NativePopPolicy {
    /// - Parameters:
    ///   - isAtRoot: nothing to pop; a begun pop here freezes the UI.
    ///   - isTransitioning: a second pop mid-transition corrupts the stack.
    ///   - hidesBackButton: the screen suppressed going back explicitly.
    ///   - ownsInteractiveDismissal: nil when the screen is not a hero
    ///     destination at all; true when it hosts its own dismissal gesture,
    ///     which the native pop must never race.
    ///   - hasCustomLeadingItem: a custom leading item replaces the back
    ///     affordance, and UIKit's own contract takes the gesture with it.
    ///   - leadingItemsSupplementBackButton: unless the screen says the item
    ///     merely supplements the back button.
    public static func shouldBegin(
        isAtRoot: Bool,
        isTransitioning: Bool,
        hidesBackButton: Bool,
        ownsInteractiveDismissal: Bool?,
        hasCustomLeadingItem: Bool,
        leadingItemsSupplementBackButton: Bool
    ) -> Bool {
        if isAtRoot || isTransitioning || hidesBackButton { return false }
        // A hero destination answers for itself. One that disclaims ownership
        // has ASKED for the ordinary pop — custom leading item and all, since
        // its back chevron is exactly such an item and the gesture is the only
        // other way back.
        if let ownsInteractiveDismissal {
            return !ownsInteractiveDismissal
        }
        if hasCustomLeadingItem, !leadingItemsSupplementBackButton { return false }
        return true
    }
}
