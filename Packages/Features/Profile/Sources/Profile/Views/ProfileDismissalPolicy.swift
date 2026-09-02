import DesignSystem
import Foundation

/// WHICH GESTURE OWNS A HORIZONTAL DRAG ON A PUSHED PROFILE.
///
/// A profile has two things that want the same movement: the pager, which
/// walks between Activity / Gallery / Short, and the stack, which wants to go
/// back. The rule that settles it is what the drag could otherwise do.
///
/// On the FIRST tab there is nothing to the left, so a rightward drag would
/// only rubber-band — the movement is free, and the whole surface can dismiss.
/// Past the first tab the same drag has a job: it pages. Dismissing then
/// belongs to the screen edge alone, which is the platform's own reservation
/// and already the only thing the pager refuses.
///
/// Stated as a value because it is one boolean that decides which of two
/// gestures a viewer's thumb reaches, and it is invisible at both call sites.
enum ProfileDismissalPolicy {
    /// Whether a drag anywhere on the surface may dismiss.
    ///
    /// `isPushed` is not a detail: a profile that IS the tab root has nothing
    /// to go back to, and a full-width pop gesture there would either do
    /// nothing or, worse, tear the root off its own stack.
    static func allowsFullWidthDismissal(activeIndex: Int, isPushed: Bool) -> Bool {
        PagedScreenDismissalPolicy.allowsFullWidthDismissal(
            activeIndex: activeIndex, isPushed: isPushed
        )
    }

    /// The edge strip always dismisses, on every tab. Stated so the rule above
    /// reads as "and also the whole surface", not "instead of the edge" — the
    /// edge is the platform contract and is never traded away.
    static func allowsEdgeDismissal(isPushed: Bool) -> Bool {
        PagedScreenDismissalPolicy.allowsEdgeDismissal(isPushed: isPushed)
    }
}
