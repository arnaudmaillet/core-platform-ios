import DesignSystem
import UIKit

/// How a `CommentRowView` arrives in its list and how it leaves it (#920) —
/// a parameter of the row, not a property of the screen that hosts it.
///
/// - `fadeUp`: a conversation's message. It rises from the composer below,
///   fading in on a short spring (#719), and sinks back the way it came when it
///   goes.
/// - `bounceIn`: a post's comment. It springs up from small, past its size and
///   back — the spinner's and the time's bounce (#725) at row scale — and
///   shrinks away when it goes.
///
/// Both play on the view that CARRIES the row on screen (a cell's content
/// view), never on the cell: the layout owns the cell's own attributes, and an
/// effect that fought them would be undone mid-flight.
enum ThreadRowEffect: Equatable, Sendable {
    case fadeUp
    case bounceIn

    /// Where an arrival starts: the transform and alpha the view is put at
    /// before it springs to identity and full ink.
    ///
    /// ⚠️ `fadeUp` is the message rise as it was before #920, to the point:
    /// 24pt below, invisible.
    @MainActor var appearStart: (transform: CGAffineTransform, alpha: CGFloat) {
        switch self {
        case .fadeUp:
            return (CGAffineTransform(translationX: 0, y: Self.riseDistance), 0)
        case .bounceIn:
            // Under Reduce Motion nothing moves: the row only fades in.
            let scale = MotionPreference.reducesMotion ? 1 : Self.bounceStartScale
            return (CGAffineTransform(scaleX: scale, y: scale), 0)
        }
    }

    /// Where a departure ends.
    @MainActor var disappearEnd: (transform: CGAffineTransform, alpha: CGFloat) {
        switch self {
        case .fadeUp:
            return (CGAffineTransform(translationX: 0, y: Self.riseDistance), 0)
        case .bounceIn:
            let scale = MotionPreference.reducesMotion ? 1 : Self.bounceEndScale
            return (CGAffineTransform(scaleX: scale, y: scale), 0)
        }
    }

    /// How long the arrival takes to land — what a host waits on before it
    /// lets something else replace the row (`ConversationThreadViewController`
    /// holds a fast delivery back until the rise has landed).
    var appearDuration: TimeInterval {
        switch self {
        case .fadeUp: 0.45
        case .bounceIn: 0.55
        }
    }

    var disappearDuration: TimeInterval {
        switch self {
        case .fadeUp: 0.25
        case .bounceIn: 0.2
        }
    }

    /// The arrival's spring: the message's soft landing, the comment's bounce.
    private var spring: (damping: CGFloat, velocity: CGFloat) {
        switch self {
        case .fadeUp: (0.78, 0.4)
        case .bounceIn: (0.55, 0.8)
        }
    }

    static let riseDistance: CGFloat = 24
    static let bounceStartScale: CGFloat = 0.6
    static let bounceEndScale: CGFloat = 0.85

    /// Puts `view` at the arrival's start and springs it home.
    ///
    /// ⚠️ NOT `.beginFromCurrentState`: that reads the from-value off the
    /// PRESENTATION layer, where a reused view is still at rest — the start set
    /// in this same turn is not there yet, and the animation would run
    /// end → end, invisibly.
    @MainActor func playAppear(on view: UIView, completion: (() -> Void)? = nil) {
        let start = appearStart
        view.layer.removeAllAnimations()
        view.transform = start.transform
        view.alpha = start.alpha
        UIView.animate(
            withDuration: appearDuration, delay: 0,
            usingSpringWithDamping: spring.damping, initialSpringVelocity: spring.velocity,
            options: [.allowUserInteraction]
        ) {
            view.transform = .identity
            view.alpha = 1
        } completion: { _ in
            completion?()
        }
    }

    /// Takes `view` away. It is left at the departure's end — invisible — for
    /// the host to remove the row in `completion`; a reused cell puts it back
    /// (`prepareForReuse`).
    @MainActor func playDisappear(on view: UIView, completion: (() -> Void)? = nil) {
        let end = disappearEnd
        UIView.animate(
            withDuration: disappearDuration, delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]
        ) {
            view.transform = end.transform
            view.alpha = end.alpha
        } completion: { _ in
            completion?()
        }
    }
}
