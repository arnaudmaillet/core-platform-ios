import DesignSystem
import EmoteKit
import UIKit

/// The caption slide's delegate: begins only on a clearly horizontal travel
/// over a post with a strip (`SnapChromeView.captionSlideMayBegin`). An object
/// of its own — the chrome is a `UIView`, whose own `gestureRecognizerShouldBegin`
/// is asked of every recognizer attached to it.
final class SnapCaptionSlideGate: NSObject, UIGestureRecognizerDelegate {
    var mayBegin: (CGPoint) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Past its slop, the travel says the direction; the velocity backs it
        // when the travel is still too small to read.
        let travel = pan.translation(in: pan.view)
        return mayBegin(travel == .zero ? pan.velocity(in: pan.view) : travel)
    }
}

/// The caption: an `EmoteLabel` that tells a horizontal pager above it
/// (Shots' sector pager, `HorizontalDragClaiming`) when a slide starting on it
/// is its own — on a post with a strip (#2269).
final class SnapCaptionLabel: EmoteLabel, HorizontalDragClaiming {
    var claimsDrag: (CGPoint) -> Bool = { _ in false }

    func claimsHorizontalDrag(velocity: CGPoint) -> Bool {
        claimsDrag(velocity)
    }
}
