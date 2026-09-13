import UIKit

/// When a sideways drag belongs to the stack's back-swipe rather than to the
/// carousel under the finger.
///
/// ⚠️ **THE BACK-SWIPE IS DRIVEN BY A FULL-WIDTH PAN ON THE STACK, NOT BY THE
/// VENDED EDGE RECOGNISER — MEASURED, AFTER TWO WRONG FIXES.** A probe on the
/// editor logged, during a real drag: `interactivePopGestureRecognizer`'s
/// delegate was **never asked at all** (`ask on` lines: 0), while UIKit
/// consulted the delegate about `_UIParallaxTransitionPanGestureRecognizer` on
/// the navigation controller's `UILayoutContainerView`. That is the second of
/// the two pans `MediaEditorViewController`'s own note warns about — *"the stack
/// has two back-swipe recognisers and `interactivePopGestureRecognizer` vends
/// only one"*. Gating or ordering the vended one governs a gesture that never
/// arrives, which is why an edge drag on the editor moved nothing twice over.
///
/// Two consequences worth keeping:
///
/// - **The reach is the WHOLE SURFACE, not the leading 20pt.** The driver is a
///   full-width pan, so a rightward drag anywhere carries the screen back.
/// - **The arbitration belongs to the carousel, not to the stack.** A carousel
///   is the only thing that knows whether it still has somewhere to go, and
///   declining its own pan is public API — disputing a private recogniser is not.
///
/// At the leading edge a rightward drag would only rubber-band, so nothing is
/// given up by declining it.
enum CarouselBackSwipe {
    /// How far from the window's leading edge a drag may start and still be a
    /// back-swipe.
    ///
    /// ⚠️ **ONE DEFINITION, TWO USERS.** `UploadNavigationController`'s gate reads
    /// this too. If a carousel yielded over a wider band than the stack accepts,
    /// drags in the difference would get neither a pop NOR a rubber-band — they
    /// would simply do nothing, which is how this was found.
    ///
    /// A choice, not a measurement: UIKit's own edge band is not published.
    static let edgeWidth: CGFloat = 20

    /// Whether this drag belongs to the stack rather than to the carousel.
    ///
    /// ⚠️ PURE, AND DELIBERATELY SO: a `UIPanGestureRecognizer`'s translation
    /// cannot be set, so the decision is only testable once it is separated from
    /// the gesture that carries it.
    ///
    /// The vertical test matters on the finalisation screen, where the strip sits
    /// inside a list: a mostly-vertical drag that happens to lean right is
    /// someone scrolling the page, and handing that to the stack would make the
    /// screen leave under them.
    /// ⚠️ **`startedNearLeadingEdge` IS NOT OPTIONAL POLISH.** The stack only
    /// accepts a back-swipe that began at the window's edge, so a carousel that
    /// stood aside for a drag starting anywhere would hand the touch to a gesture
    /// that then refuses it: at the first item, a rightward drag from mid-screen
    /// would neither pop nor rubber-band, and the carousel would feel dead.
    /// Measured after the stack's gate landed, which is when that gap opened.
    static func yields(
        translation: CGPoint, isAtLeadingEdge: Bool, startedNearLeadingEdge: Bool
    ) -> Bool {
        guard startedNearLeadingEdge else { return false }
        guard isAtLeadingEdge else { return false }
        guard abs(translation.x) > abs(translation.y) else { return false }
        return translation.x > 0
    }

    /// ⚠️ **NOT `contentOffset.x == 0`.** The finalisation strip centres its
    /// thumbnails with a computed `contentInset`, so at rest it sits at MINUS
    /// that inset; comparing against zero would call a resting strip scrolled and
    /// it would never yield at all.
    static func isAtLeadingEdge(_ scroller: UIScrollView) -> Bool {
        scroller.contentOffset.x + scroller.adjustedContentInset.left <= 0.5
    }

    /// Shared by both hosts below, which differ only in what they inherit from.
    ///
    /// ⚠️ Unlike the stack's gate — where translation is `(0,0)` at
    /// `shouldBegin`, measured twice — a scroll view's own pan HAS travelled by
    /// the time it asks, which is what makes `location − translation` a usable
    /// start point here and not there. Same-named method, different moment.
    static func shouldBegin(_ pan: UIPanGestureRecognizer, in scroller: UIScrollView) -> Bool {
        let space: UIView = scroller.window ?? scroller
        let moved = pan.translation(in: space)
        let startX = pan.location(in: space).x - moved.x
        return !yields(
            translation: pan.translation(in: scroller),
            isAtLeadingEdge: isAtLeadingEdge(scroller),
            startedNearLeadingEdge: startX <= edgeWidth
        )
    }
}

/// The editor's full-bleed paging canvas.
final class CarouselCollectionView: UICollectionView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }

        guard CarouselBackSwipe.shouldBegin(pan, in: self) else { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// The finalisation screen's media strip, which is a plain scroll view holding a
/// stack rather than a collection view.
final class CarouselScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }

        guard CarouselBackSwipe.shouldBegin(pan, in: self) else { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
