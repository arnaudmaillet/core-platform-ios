import UIKit

/// Which scroll view, out of a screenful of them, the chrome should follow.
///
/// # Why this is a type and not a line of code in each screen
///
/// Every accessory-hosted selector needs the same answer, and getting it wrong
/// is INVISIBLE: the tab bar simply never minimizes, which reads as "UIKit's
/// `setContentScrollView` doesn't work" rather than "it was pointed at the
/// wrong view". Three ways to be wrong, all measured on this app:
///
///   1. **Let UIKit find it.** `setContentScrollView` is documented as
///      searching for a scroll view when none is set. Filmed on For You with
///      nothing registered: the grid scrolled and the tab bar sat at full
///      height through every flick. A scroller nested inside a horizontal
///      pager is not what that search finds. Registering is mandatory.
///   2. **Take the biggest.** A pager keeps its pages laid out side by side at
///      identical size, so "biggest" picks page 0 while the viewer reads page
///      1 — a `contentOffset` that never moves, and a band that never moves
///      with it.
///   3. **Ask before the page is on screen.** Measured by UITest on the
///      Messages inbox: at `viewDidAppear` every page is still zero-width, so
///      a rule that screens candidates on their geometry finds nothing —
///      `named=0` for the whole run, on a screen whose wiring is correct.
///
/// So the honest question is not "which scroller is on screen" but "which
/// scroller belongs to the page the pager says is in front". `vertical(in:)`
/// answers that, from a page the caller has already chosen, and needs no
/// geometry at all — which is what makes it immune to (3).
public enum OnScreenScroller {
    /// The vertical scroller inside one page.
    ///
    /// No geometry test, deliberately: the caller has already decided which
    /// page this is, so a zero-width page mid-launch is still the right answer.
    /// The only thing filtered out is a scroller that pages HORIZONTALLY —
    /// a pager nested in a page, and the pager itself when someone passes it
    /// here by mistake — because that one is the carriage, not the cargo.
    public static func vertical(in page: UIView) -> UIScrollView? {
        if let scroller = page as? UIScrollView, !isHorizontal(scroller) { return scroller }
        for subview in page.subviews {
            if let found = vertical(in: subview) { return found }
        }
        return nil
    }

    /// The visible vertical scroller inside `root`, for a caller that does NOT
    /// know which page is in front — the audit, which has to be able to
    /// disagree with the screen about what it registered.
    ///
    /// ⚠️ Centred-on-`root`, not biggest: see (2) above. And it needs a real
    /// width to answer at all, so it is the wrong tool for a screen that is
    /// still laying out — see (3).
    public static func candidate(in root: UIView) -> UIScrollView? {
        var best: UIScrollView?
        var bestDrift = CGFloat.greatestFiniteMagnitude
        let mid = root.bounds.midX
        func walk(_ view: UIView) {
            if let scroller = view as? UIScrollView, !isHorizontal(scroller),
               scroller.bounds.width > 1, !scroller.isHidden, scroller.alpha > 0.01 {
                let frame = scroller.convert(scroller.bounds, to: root)
                let drift = abs(frame.midX - mid)
                if drift < bestDrift { bestDrift = drift; best = scroller }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    /// A scroll view whose content is wider than it is: a pager, not a list.
    private static func isHorizontal(_ scroller: UIScrollView) -> Bool {
        scroller.contentSize.width > scroller.bounds.width + 1
    }
}
