import UIKit

/// Lets the viewer catch a flight that is already flying and take it over —
/// freeze on contact, follow the finger, decide at release.
///
/// **Why a percent-driven controller for a transition that starts on a tap.**
/// A running `UIView.animate` cannot be caught: there is no object to pause and
/// no way to tell UIKit the transition should be reversed. `UIPercentDriven
/// InteractiveTransition` with `wantsInteractiveStart == false` is exactly the
/// shape this needs — the flight begins non-interactively, as a tap always
/// did, and this sits dormant over it holding the right to interrupt. Nothing
/// about an untouched flight changes.
///
/// It pairs with `ZoomAnimator.interruptibleAnimator(using:)`, which hands
/// UIKit a `UIViewPropertyAnimator` instead of running the spring directly.
/// `pause()` stops that animator wherever it is; `update(_:)` scrubs it;
/// `finish()` and `cancel()` hand it back with the remaining distance re-timed.
///
/// **Freeze on contact.** A zero-duration press recognises at touch-down —
/// ~10pt of travel before any pan can — and pauses the flight under the
/// finger, so touching a flying card stops it instantly rather than after a
/// drag threshold. A finger that lifts without dragging resumes the flight
/// toward its end: holding was an inspection, not a veto.
///
/// **Two channels once a drag begins**, the same split the grab-from-rest
/// driver (`ZoomDismissInteractionController`) uses:
/// - vertical travel scrubs the percent driver — the morph, dim, depth and
///   navigation-bar rail;
/// - the residual of the finger's travel (what the scrub did not spend moving
///   the card) rides `card.transform`, the one geometric channel no pose
///   touches, so the card tracks the finger 1:1 near the grab point. The
///   arithmetic lives in `ZoomFlightGrabHandoff`, where it is unit-tested.
///
/// **Direction is per leg, and both mean "down puts it back".** On a DISMISSAL
/// downward advances, which is the direction that starts one from rest, so
/// catching a flight mid-air pushes it home the way it would have been thrown.
/// On a PRESENT the same downward drag has to REVERSE the push, because down
/// is the gesture for going back to the grid either way. One sign flip
/// expresses that, and inverting the velocity with it keeps a flick meaning
/// the same thing on both legs.
@MainActor
final class ZoomFlightInterruptor: UIPercentDrivenInteractiveTransition {
    /// The flight starts on its own. This object only ever interrupts one.
    override var wantsInteractiveStart: Bool {
        get { false }
        set { _ = newValue }
    }

    private weak var container: UIView?
    private weak var pan: UIPanGestureRecognizer?
    private weak var touchCatcher: UILongPressGestureRecognizer?
    /// Vends the card of the flight currently staged, for the free-position
    /// channel. Wired by the transition controller from the animator that
    /// builds the flight; the default answers nil, which degrades to the
    /// rail-only scrub.
    var flightCard: () -> (any ZoomFlightCard)? = { nil }

    /// The interruption's state machine and channel math — pure, so the
    /// transitions and the follow-the-finger arithmetic are unit-tested
    /// without a live transition. Rebuilt per flight with the real span.
    private var handoff: ZoomFlightGrabHandoff
    /// The card under the finger, held for the free channel. Present leg
    /// only: a dismissal may fly a hoisted surface above the card
    /// (the map's return), and a transform on the card alone would shear the
    /// two apart.
    private weak var grabbedCard: UIView?
    /// The card's rail position at grab-begin — presentation-layer truth, the
    /// baseline `railDelta` is measured against.
    private var railOrigin: CGPoint = .zero
    private let advancesOnDownwardDrag: Bool

    init(advancesOnDownwardDrag: Bool) {
        self.advancesOnDownwardDrag = advancesOnDownwardDrag
        handoff = ZoomFlightGrabHandoff(
            advancesOnDownwardDrag: advancesOnDownwardDrag, span: 1
        )
        super.init()
    }

    override func startInteractiveTransition(_ transitionContext: any UIViewControllerContextTransitioning) {
        super.startInteractiveTransition(transitionContext)
        let container = transitionContext.containerView
        self.container = container
        // The travel that maps to the whole flight: the container's height
        // rather than the card's, so the gain does not change with the post's
        // shape.
        handoff = ZoomFlightGrabHandoff(
            advancesOnDownwardDrag: advancesOnDownwardDrag,
            span: container.bounds.height
        )

        #if DEBUG
        scheduleScriptedInterruptIfNeeded()
        #endif

        // Freeze on contact: recognises at touch-down, before the pan's
        // ~10pt movement threshold, so the flight stops the instant it is
        // touched. Coexists with the pan (delegate below); the pan takes over
        // when movement starts.
        let touch = UILongPressGestureRecognizer(target: self, action: #selector(handleTouch))
        touch.minimumPressDuration = 0
        touch.delegate = self
        container.addGestureRecognizer(touch)
        touchCatcher = touch

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        // Never blocks anything: the flight's container has no other recogniser
        // on it, and the screens underneath are not interactive mid-transition.
        pan.delegate = self
        container.addGestureRecognizer(pan)
        self.pan = pan
    }

    // MARK: - Touch catcher

    @objc private func handleTouch(_ recogniser: UILongPressGestureRecognizer) {
        // The container can outlive `completeTransition` by a beat; a touch
        // in that window must not pause a transition that already reported.
        guard container?.window != nil else { return }
        switch recogniser.state {
        case .began:
            // Freezes the animator wherever the spring had got to.
            if handoff.touchDown() == .pauseFlight { pause() }
        case .ended, .cancelled, .failed:
            if handoff.touchUp() == .resumeTowardEnd {
                detach()
                // Resume on the shared spring from rest — the same physics
                // every other leg lands with, minus the hand's velocity a
                // motionless hold does not have.
                timingCurve = UISpringTimingParameters(
                    dampingRatio: ZoomFlight.springDamping, initialVelocity: .zero
                )
                finish()
            }
        default:
            break
        }
    }

    // MARK: - Pan

    @objc private func handlePan(_ recogniser: UIPanGestureRecognizer) {
        guard let container else { return }
        let translation = recogniser.translation(in: container)

        switch recogniser.state {
        case .began:
            guard container.window != nil else { return }
            // Idempotent when the touch catcher froze the flight first; the
            // pause is what makes `percentComplete` current either way.
            pause()
            guard handoff.grabBegan(atFraction: percentComplete) else { return }
            // The free channel rides `card.transform` — the one geometric
            // channel no pose touches — so it composes with the scrubbed
            // animation instead of fighting it.
            if !advancesOnDownwardDrag, let card = flightCard() {
                grabbedCard = card
                railOrigin = Self.railPosition(of: card)
            }
        case .changed:
            guard handoff.phase == .grabbing else { return }
            update(handoff.fraction(forVerticalTranslation: translation.y))
            if let card = grabbedCard {
                // Measured AFTER the update, so the delta includes the scrub
                // this very event performed and the residual never
                // double-counts the rail's share of the travel.
                let rail = Self.railPosition(of: card)
                let offset = handoff.freeOffset(
                    translation: translation,
                    railDelta: CGPoint(x: rail.x - railOrigin.x, y: rail.y - railOrigin.y)
                )
                card.transform = CGAffineTransform(translationX: offset.x, y: offset.y)
            }
        case .ended, .cancelled, .failed:
            guard let release = handoff.released(
                verticalTranslation: translation.y,
                verticalVelocity: recogniser.velocity(in: container).y
            ) else { return }
            detach()
            settleFreeChannel()
            // Without an explicit curve the percent driver continues a caught
            // flight with its default completion curve — ease-in-out from
            // rest — which is different physics from every other leg of this
            // transition and reads as a hesitation-then-snap at exactly the
            // moment of release. Hand it the shared spring instead, seeded
            // with the hand's velocity, so a caught flight lands the way a
            // grab-from-rest release does.
            timingCurve = UISpringTimingParameters(
                dampingRatio: ZoomFlight.springDamping,
                initialVelocity: CGVector(dx: 0, dy: release.springVelocity)
            )
            release.completes ? finish() : cancel()
        default:
            break
        }
    }

    /// The card's scrubbed position — presentation-layer truth, so the rail
    /// delta reflects what is actually on screen whatever the timing curve or
    /// scrub mode does.
    private static func railPosition(of card: UIView) -> CGPoint {
        card.layer.presentation()?.position ?? card.layer.position
    }

    /// Springs the free channel's offset home alongside the percent driver's
    /// continuation, on the same shared spring, so the 2D float and the rail
    /// converge together — whichever outcome, the card's transform must be
    /// identity by the time the animator's completion tears the stage down.
    private func settleFreeChannel() {
        guard let card = grabbedCard else { return }
        grabbedCard = nil
        guard card.transform != .identity else { return }
        UIView.animate(
            withDuration: ZoomFlight.springDuration, delay: 0,
            usingSpringWithDamping: ZoomFlight.springDamping,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            card.transform = .identity
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
                // Zero velocity, but the SAME spring a hand's release hands
                // over — the scripted path must exercise the physics it
                // stands in for.
                self.timingCurve = UISpringTimingParameters(
                    dampingRatio: ZoomFlight.springDamping, initialVelocity: .zero
                )
                if mode == "cancel" { self.cancel() } else { self.finish() }
            }
        }
    }
    #endif

    /// Takes both recognisers off the container once a decision is made, so
    /// the same flight cannot be grabbed twice on its way out.
    private func detach() {
        if let pan { container?.removeGestureRecognizer(pan) }
        if let touchCatcher { container?.removeGestureRecognizer(touchCatcher) }
        pan = nil
        touchCatcher = nil
    }
}

extension ZoomFlightInterruptor: UIGestureRecognizerDelegate {
    /// The touch catcher always begins — freezing is what contact means over
    /// a flying card. The pan begins for ANY direction on the present leg:
    /// the whole point of the catch is that the finger takes the card
    /// wherever it goes, and the free channel can honour every direction. The
    /// dismiss leg keeps its vertical-intent gate — its card can fly a
    /// hoisted surface the free channel cannot carry, so a horizontal drag
    /// there would claim a gesture it cannot honour.
    nonisolated func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        guard let pan = recogniser as? UIPanGestureRecognizer else { return true }
        return MainActor.assumeIsolated {
            guard advancesOnDownwardDrag else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x)
        }
    }

    /// The touch catcher and the pan are both ours and must coexist: the
    /// freeze begins on contact, the pan takes over when movement starts.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
