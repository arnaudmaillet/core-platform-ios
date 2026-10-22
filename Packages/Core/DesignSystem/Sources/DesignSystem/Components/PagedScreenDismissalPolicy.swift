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
    /// The leading strip a navigation stack's interactive pop owns. ONE
    /// definition: two surfaces disagreeing about where the edge ends is a
    /// band where each believes the other has the drag.
    ///
    /// Wider than the system's ~20pt on purpose: a thumb swiping "from the
    /// edge" past a rounded bezel or a case touches down 20–25pt in, and a
    /// strip that misses it hands the drag to the tab pager — the opposite
    /// of what the swipe meant. Still narrow enough that a tab swipe, which
    /// starts on the content, never lands in it.
    ///
    /// ⚠️ Measured at the drag's ORIGIN (location minus translation) by every
    /// caller: `gestureRecognizerShouldBegin` fires after the slop, when the
    /// finger is already tens of points past this strip.
    public static let edgeZone: CGFloat = 28

    /// The TRAILING strip a leftward drag claims for the screen over a
    /// carousel's own paging (#1580: the snap feed's side list, or the
    /// author's profile, from any photo). Wider than `edgeZone`: nothing
    /// system-owned shares this edge, and the owner's thumb, swiping in "from
    /// the right edge" on the device, landed past the 28 pt strip and paged
    /// the carousel instead (2026-10-22). A carousel swipe starts on the
    /// photo, well clear of it.
    ///
    /// ⚠️ 36, NOT 44 (#1592, the owner 2026-10-22): the edge wins over
    /// EVERYTHING, and nothing may share the strip — the snap feed's emote
    /// rail used to sit 12 pt from the edge, 32 pt INSIDE a 44 pt strip, and
    /// took the edge swipes. 36 still clears the 28 pt the owner's thumb
    /// landed past, and a trailing control column now stands clear of it
    /// (`trailingClearance`).
    public static let trailingEdgeZone: CGFloat = 36

    /// The air between the trailing strip and the first control beside it:
    /// a thumb on the control never starts an edge swipe, and the reverse.
    public static let trailingEdgeGap: CGFloat = 8

    /// How far from the trailing edge a column of controls that owns its own
    /// drags (the snap feed's emote rail) must stand: the strip, then the gap.
    public static var trailingClearance: CGFloat { trailingEdgeZone + trailingEdgeGap }

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
