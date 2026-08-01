import UIKit

/// Lets the viewer catch a dismissal that is already flying and take it over.
///
/// **Why a percent-driven controller for a transition that starts on a tap.**
/// A running `UIView.animate` cannot be caught: there is no object to pause and
/// no way to tell UIKit the pop should be reversed. `UIPercentDrivenInteractive
/// Transition` with `wantsInteractiveStart == false` is exactly the shape this
/// needs — the pop begins non-interactively, as a tap-back always did, and this
/// sits dormant over it holding the right to interrupt. Nothing about an
/// untouched flight changes.
///
/// It pairs with `ZoomAnimator.interruptibleAnimator(using:)`, which hands UIKit
/// a `UIViewPropertyAnimator` instead of running the spring directly. `pause()`
/// stops that animator wherever it is; `update(_:)` scrubs it; `finish()` and
/// `cancel()` hand it back with the remaining distance re-timed.
///
/// **Direction.** Downward advances the dismissal, which is the same direction
/// that starts one from rest (`ZoomDismissInteractionController`), so a viewer
/// who grabs a flight mid-air pushes it home the way they would have thrown it.
/// Dragging up runs it backwards toward the page.
///
/// This is the DISMISS leg only. Interrupting a present means defining what a
/// reversed push does to the pool loan and to a surface that has been hoisted
/// above the navigation controller, and that is its own change.
@MainActor
final class ZoomFlightInterruptor: UIPercentDrivenInteractiveTransition {
    /// The flight starts on its own. This object only ever interrupts one.
    override var wantsInteractiveStart: Bool {
        get { false }
        set { _ = newValue }
    }

    private weak var container: UIView?
    private weak var pan: UIPanGestureRecognizer?
    /// `percentComplete` at the moment the flight was caught — the drag is
    /// measured from there, not from zero, or grabbing a half-flown card would
    /// snap it back to the page.
    private var grabbedAt: CGFloat = 0
    /// The travel that maps to the whole flight. The container's height rather
    /// than the card's, so the gain does not change with the post's shape.
    private var span: CGFloat = 1
    private var isGrabbing = false

    override func startInteractiveTransition(_ transitionContext: any UIViewControllerContextTransitioning) {
        super.startInteractiveTransition(transitionContext)
        let container = transitionContext.containerView
        self.container = container
        span = max(container.bounds.height, 1)

        #if DEBUG
        scheduleScriptedInterruptIfNeeded()
        #endif

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        // Never blocks anything: the flight's container has no other recogniser
        // on it, and the screens underneath are not interactive mid-transition.
        pan.delegate = self
        container.addGestureRecognizer(pan)
        self.pan = pan
    }

    @objc private func handlePan(_ recogniser: UIPanGestureRecognizer) {
        guard let container else { return }
        let translation = recogniser.translation(in: container).y

        switch recogniser.state {
        case .began:
            isGrabbing = true
            // Freezes the animator wherever the spring had got to. Everything
            // below is measured from that point.
            pause()
            grabbedAt = percentComplete
        case .changed:
            guard isGrabbing else { return }
            update(min(max(grabbedAt + translation / span, 0), 1))
        case .ended, .cancelled, .failed:
            guard isGrabbing else { return }
            isGrabbing = false
            let velocity = recogniser.velocity(in: container).y
            let progress = min(max(grabbedAt + translation / span, 0), 1)
            // A flick decides regardless of distance, matching the grab-from-rest
            // contract; otherwise the same completion threshold everything else
            // in this transition uses.
            let completes = ZoomTransitionGeometry.shouldCompleteDismissal(
                progress: progress, velocity: velocity
            )
            detach()
            if completes { finish() } else { cancel() }
        default:
            break
        }
    }

    #if DEBUG
    /// `-zoom-interrupt finish|cancel`: catch the next flight mid-air without a
    /// finger.
    ///
    /// The reversal path is the one worth exercising — it is the only place
    /// that has to give back a hoisted surface — and a real drag cannot be
    /// timed reliably against a 0.42s spring from a script.
    private func scheduleScriptedInterruptIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-zoom-interrupt"),
              position + 1 < arguments.count
        else { return }
        let mode = arguments[position + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.pause()
            let caught = self.percentComplete
            self.update(min(max(caught + 0.1, 0), 1))
            print("[zoom-live] SCRIPTED INTERRUPT caught=\(String(format: "%.2f", caught)) mode=\(mode)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.detach()
                if mode == "cancel" { self.cancel() } else { self.finish() }
            }
        }
    }
    #endif

    /// Takes the recogniser off the container once a decision is made, so the
    /// same flight cannot be grabbed twice on its way out.
    private func detach() {
        if let pan { container?.removeGestureRecognizer(pan) }
        pan = nil
    }
}

extension ZoomFlightInterruptor: UIGestureRecognizerDelegate {
    /// Vertical intent only. A horizontal drag over a flying card is not a
    /// dismissal gesture, and claiming it would swallow it for no purpose.
    nonisolated func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        guard let pan = recogniser as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.y) > abs(velocity.x)
    }
}
