import CoreGraphics

/// WHICH GESTURE OWNS A HORIZONTAL DRAG ON A PAGED SCREEN.
///
/// Two things want the same movement on any screen with tabs: the pager, which
/// walks between them, and the stack, which wants to go back. The rule that
/// settles it is what the drag could OTHERWISE do.
///
/// On the FIRST tab there is nothing to the left, so a rightward drag would only
/// rubber-band — the movement is free, and the whole surface may dismiss. Past
/// the first tab that same drag has a job, and dismissing belongs to the screen
/// edge alone.
///
/// ⚠️ THE EDGE IS NEVER TRADED AWAY, on any tab. It is the platform's own
/// reservation, `HorizontalPagerScrollView` already yields it outright, and a
/// screen that also refuses it leaves the strip claimed by NOBODY — the drag
/// does nothing at all. That is exactly how a place page's Activity tab shipped
/// with no way back: the pager gave the edge up and the flight refused it,
/// because the flight was asking only "am I on the first tab".
///
/// Shared rather than restated because it is one boolean deciding which of two
/// gestures a thumb reaches, it is invisible at every call site, and the
/// constant behind it had already been written down three times.
public enum PagedScreenDismissalPolicy {
    /// The leading strip a navigation stack's interactive pop owns, matching
    /// the system's. ONE definition: two surfaces disagreeing about where the
    /// edge ends is a band where each believes the other has the drag.
    public static let edgeZone: CGFloat = 20

    /// Whether a drag beginning at `x` (in the screen's own coordinates) may
    /// dismiss, given which tab is up.
    ///
    /// `isPushed` is not a detail: a screen that IS its stack's root has
    /// nothing to go back to, and a pop gesture there would either do nothing
    /// or tear the root off its own stack.
    public static func allowsDismissal(atX x: CGFloat, activeIndex: Int, isPushed: Bool) -> Bool {
        guard isPushed else { return false }
        return x <= edgeZone || activeIndex == 0
    }

    /// Whether a drag anywhere on the surface may dismiss — the first tab's
    /// privilege, asked without a location.
    public static func allowsFullWidthDismissal(activeIndex: Int, isPushed: Bool) -> Bool {
        isPushed && activeIndex == 0
    }

    /// The edge strip always dismisses, on every tab. Stated so the rule above
    /// reads as "and also the whole surface", not "instead of the edge".
    public static func allowsEdgeDismissal(isPushed: Bool) -> Bool {
        isPushed
    }
}
