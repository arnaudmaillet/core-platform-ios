import UIKit

/// A container that keeps only the touches its controls actually want, and
/// lets every other touch fall through to whatever is behind it.
///
/// The profile's header floats OVER the pages rather than scrolling inside
/// them — that is the whole of the architecture, and it is what lets one header
/// ride three independently scrolling tabs. The cost is hit-testing: a plain
/// `UIView` takes every touch inside its bounds whether or not it has anything
/// there to receive it, so the avatar, the name, the bio and the empty space
/// around them all swallowed drags. Scrolling worked everywhere except over the
/// part of the screen a viewer is most likely to have their thumb on.
///
/// ⚠️ **The test is whether something INTERACTIVE was hit, not whether
/// something was hit.** `hitTest` returns the deepest view containing the
/// point, and a label with no interaction of its own is skipped in favour of
/// its container — so "did I get a subview back" is answered yes for the bio's
/// blank margins and no for the bio's own glyphs, neither of which is the
/// question. The chain from the hit view up to this one is walked instead, and
/// the touch is claimed only if something on it does something.
///
/// A `UIControl` is the test that matters here: every interactive thing in this
/// header is one — the action buttons are `UIButton`s and the four counters are
/// `ProfileStatView`, which is a `UIControl` for exactly this kind of reason.
/// Gesture recognizers are checked too, so anything added later that reads
/// touches directly (the selector's grabbable capsule already does) keeps them
/// without having to be remembered here.
final class ScrollPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        var node: UIView? = hit
        while let current = node, current !== self {
            if current is UIControl { return hit }
            if current.gestureRecognizers?.isEmpty == false { return hit }
            node = current.superview
        }
        return nil
    }
}
