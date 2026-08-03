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
    /// The staged flight's endpoint rects in animation order, for recovering
    /// the caught fraction from the card's presentation size. Same wiring and
    /// same degradation as `flightCard`.
    var flightEndpoints: () -> (start: CGRect, end: CGRect)? = { nil }

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
    #if DEBUG
    /// Thins the per-event drag trace under `-zoom-live-log`.
    private var dragEventCount = 0
    #endif

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
            if handoff.touchDown() == .pauseFlight {
                pause()
                alignWithPresentation()
            }
        case .ended, .cancelled, .failed:
            if handoff.touchUp() == .resumeTowardEnd {
                detach()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print(String(format: "[zoom-live] CATCH resume toward end from=%.2f", percentComplete))
                }
                #endif
                // Resume on the shared spring from rest — the same physics
                // every other leg lands with, minus the hand's velocity a
                // motionless hold does not have.
                timingCurve = UISpringTimingParameters(
                    dampingRatio: ZoomFlight.springDamping, initialVelocity: .zero
                )
                continueOverFullSpring(fromProgress: percentComplete, towardEnd: true)
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
            // Idempotent when the touch catcher froze the flight first: the
            // second alignment recomputes from a presentation the first one
            // already posed, and lands on the same fraction.
            pause()
            let caught = alignWithPresentation() ?? percentComplete
            guard handoff.grabBegan(atFraction: caught) else { return }
            // The free channel rides `card.transform` — the one geometric
            // channel no pose touches — so it composes with the scrubbed
            // animation instead of fighting it.
            if !advancesOnDownwardDrag, let card = flightCard() {
                grabbedCard = card
                railOrigin = Self.railPosition(of: card)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print(String(format: "[zoom-live] CATCH grab at=%.2f free=%@",
                             caught, grabbedCard == nil ? "no" : "yes"))
            }
            #endif
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
                #if DEBUG
                dragEventCount += 1
                if dragEventCount % 12 == 1,
                   ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print(String(format: "[zoom-live] CATCH drag t=(%.0f,%.0f) fraction=%.2f offset=(%.0f,%.0f)",
                                 translation.x, translation.y, percentComplete, offset.x, offset.y))
                }
                #endif
            }
        case .ended, .cancelled, .failed:
            guard let release = handoff.released(
                verticalTranslation: translation.y,
                verticalVelocity: recogniser.velocity(in: container).y
            ) else { return }
            detach()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print(String(format: "[zoom-live] CATCH release completes=%@ caught=%.2f progress=%.2f vy=%.0f",
                             release.completes ? "yes" : "no", handoff.grabbedAt,
                             handoff.fraction(forVerticalTranslation: translation.y),
                             recogniser.velocity(in: container).y))
            }
            #endif
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
            continueOverFullSpring(
                fromProgress: handoff.fraction(forVerticalTranslation: translation.y),
                towardEnd: release.completes
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

    /// Re-aims the percent driver at the fraction the SCREEN is showing,
    /// immediately after a `pause()`, and returns that fraction.
    ///
    /// `pause()` syncs `percentComplete` from the animator's
    /// `fractionComplete`, and for a spring animator that number is
    /// time-based and wrong — measured as 0.00 on a flight that was visibly
    /// half-flown. Left uncorrected, the first scrub snapped the card
    /// straight back to the start pose (tile-sized, on a present) the moment
    /// it was caught. The card's presentation size recovers the true
    /// fraction (`ZoomFlightGrabHandoff.caughtFraction` — every posed
    /// property rides one shared scalar, so size determines the whole pose),
    /// and one `update` re-poses the paused animator exactly where the eye
    /// already has it: the catch changes nothing on screen.
    ///
    /// RETURNED rather than read back, because `percentComplete` does not
    /// reflect an `update` within the same call (measured: 0.00 immediately
    /// after `update(0.21)`, 0.21 by the next event) — a caller that anchored
    /// the grab on the readback would measure the whole drag from zero and
    /// snap the card on the first pan event. Nil when the seam is unwired,
    /// the animation has no presentation, or the endpoints are the same size;
    /// the synced value is then all there is.
    @discardableResult
    private func alignWithPresentation() -> CGFloat? {
        var aligned: CGFloat?
        defer {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                let card = flightCard()
                let bounds = card?.layer.presentation()?.bounds.size ?? card?.bounds.size
                print(String(format: "[zoom-live] CATCH freeze at=%.2f (synced=%.2f) card=%.0fx%.0f",
                             aligned ?? percentComplete, percentComplete,
                             bounds?.width ?? -1, bounds?.height ?? -1))
            }
            #endif
        }
        guard let card = flightCard(),
              let endpoints = flightEndpoints(),
              let presented = card.layer.presentation()?.bounds.size,
              let fraction = ZoomFlightGrabHandoff.caughtFraction(
                  presented: presented,
                  start: endpoints.start.size,
                  end: endpoints.end.size
              )
        else { return nil }
        update(fraction)
        aligned = fraction
        return fraction
    }

    /// Stretches the percent driver's continuation to the flight's FULL
    /// spring duration, whatever fraction remains.
    ///
    /// The driver's default scales the continuation by the remaining
    /// fraction — `(1 − progress) × duration` toward the end, `progress ×
    /// duration` back to the start — so a flight caught early rewound to the
    /// tile in a tenth of a second: no time for the spring to breathe, which
    /// reads as a rigid snap rather than the elastic settling every other
    /// dismissal lands with. Every non-caught release in this transition runs
    /// the whole `ZoomFlight.springDuration` regardless of remaining distance
    /// (the grab-from-rest release is a fixed-duration `UIView.animate`), so
    /// the caught one does too: `completionSpeed` divides the remaining time,
    /// making it the full duration again.
    private func continueOverFullSpring(fromProgress progress: CGFloat, towardEnd: Bool) {
        let remaining = towardEnd ? 1 - progress : progress
        completionSpeed = min(max(remaining, 0.001), 1)
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
