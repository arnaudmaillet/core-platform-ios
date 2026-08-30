import CoreGraphics

/// Which part of a long run of pages a strip is showing.
///
/// ⚠️ Shared, for the reason `PageScrubber` is: two strips draw this now — the
/// card's chip of dots and the post screen's segment bar — and the rule is
/// stateful, so writing it twice would give two windows that agree until one of
/// them is touched.
public enum PageWindow {
    /// The slots the mark is allowed to occupy — one in from each end.
    ///
    /// ⚠️ THE MARK WALKS; THE WINDOW ONLY FOLLOWS WHEN IT HAS TO.
    ///
    /// Recomputing the window from the current page alone gives the mark a
    /// FIXED slot, and then the whole row slides under it on every page change
    /// — so the one thing actually happening, the viewer moving along the run,
    /// is the one thing the indicator does not show. Worse when the direction
    /// changes: the fixed slot moves from one side of the middle to the other,
    /// so a single page back jumped the row by TWO. Reported exactly that way,
    /// as the mark landing on the second dot where the third was expected.
    ///
    /// So the window is KEPT and only pushed. The mark moves one slot per page
    /// until it reaches the slot one in from the end it is heading for, and
    /// from then on the row scrolls under it.
    ///
    /// Both bounds collapse gracefully on a narrow strip: with three slots the
    /// mark holds the middle, with two the trailing one, with one there is
    /// nowhere to walk.
    public static func slotBounds(visible: Int) -> (lowest: Int, highest: Int) {
        let lowest = min(1, max(visible - 1, 0))
        return (lowest, max(visible - 2, lowest))
    }

    /// The first slot of the window: the previous one, moved as little as the
    /// mark's bounds allow, and never off either end of the run.
    ///
    /// Fractional on purpose. The dots ask it about a page and get a whole
    /// number back; the segment bar asks it about a scroll POSITION, and gets a
    /// window that slides with the finger rather than one that jumps a whole
    /// slot at the crossing — which on a strip whose active segment is visibly
    /// wider is the difference between a run that flows and one that stutters.
    public static func start(
        current: CGFloat, visible: Int, count: Int, from previous: CGFloat
    ) -> CGFloat {
        guard count > visible else { return 0 }
        let bounds = slotBounds(visible: visible)
        let pushed = min(
            max(previous, current - CGFloat(bounds.highest)),
            current - CGFloat(bounds.lowest)
        )
        return min(max(pushed, 0), CGFloat(count - visible))
    }

    /// The whole-page twin, for callers whose mark lands on slots rather than
    /// between them. One formula, so the two cannot drift.
    public static func start(current: Int, visible: Int, count: Int, from previous: Int) -> Int {
        Int(start(
            current: CGFloat(current), visible: visible, count: count, from: CGFloat(previous)
        ))
    }
}
