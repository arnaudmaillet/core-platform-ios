
import UIKit

/// Turns a rightward drag on the snap feed into a *free-floating* interactive
/// dismissal — the iOS back-swipe idiom with a physical hand-grab feel.
///
/// Not percent-driven: `UIPercentDrivenInteractiveTransition` scrubs one
/// pre-baked animation, so the card's position would be a function of a
/// single scalar — a rail. This controller implements
/// `UIViewControllerInteractiveTransitioning` directly and splits the drag
/// into two channels that never fight:
///
/// - **Position** (2D, free): `card.center` is set directly on every pan
///   event — horizontal 1:1, vertical and back-drag through a rubber-band
///   curve — so the card floats under the finger with zero lag.
/// - **Morph** (progress-driven): the card's size and radius interpolate
///   toward the rect it will land on, and dim and presenter depth are pure
///   functions of `translation.x / width`. The 0.95 detach dip fires as a
///   real spring at `.began` — instant, independent of drag distance.
///
/// Because the drag phase sets *model* values with no animation in flight,
/// release simply springs from the card's exact current 2D coordinate to
/// `poseAtSource` (commit: the same clip-morph home the button dismiss flies)
/// or `poseAsPage` (cancel), seeding the spring with the gesture's release
/// velocity so the card is visibly "caught". The horizontal axis is chosen
/// deliberately: the feed pages and pulls-to-refresh vertically, so a
/// rightward grab has no scroll view to fight; direction is vetted in
/// `gestureRecognizerShouldBegin`, which is what lets `.began` claim
/// immediately.
@MainActor
final class ZoomDismissInteractionController: NSObject, UIViewControllerInteractiveTransitioning {
    /// Whether a grab is currently driving the dismissal — the transitioning
    /// delegate returns this controller only while true.
    private(set) var isInteracting = false

    private var source: (any ZoomTransitionSource)?
    private weak var destination: (any ZoomTransitionDestination)?
    /// Kicks off `dismiss(animated:)` on the presented feed when a grab begins.
    private var onBeginDismiss: (() -> Void)?
    private weak var pannedView: UIView?

    // Live-transition state, populated by startInteractiveTransition and
    // cleared when the release animation completes.
    private var context: (any UIViewControllerContextTransitioning)?
    private var flight: ZoomFlight?
    private var dim: UIView?
    /// The feed's native bottom toolbar — navigation-controller chrome above
    /// this container, never part of the flight card. Captured at stage time
    /// so the grab can cross-fade it with progress: unlike the navigation
    /// bar (whose item cross-fade UIKit runs after release), the toolbar is
    /// *content* chrome of the departing page and must recede under the
    /// finger like the dim does. The feed's own coordinator choreography
    /// settles the hidden state after completion; this only drives alpha.
    private weak var toolbar: UIToolbar?
    private weak var presentingView: UIView?
    private var screenRadius: CGFloat = 0
    private var pageCenter: CGPoint = .zero
    /// The rect the card is flying at, resolved once the source has settled
    /// (see `startInteractiveTransition`). The drag interpolates toward it, so
    /// the card is always exactly as far home as the finger has taken it.
    private var stagedLanding: CGRect = .zero
    /// The card's size at zero progress — the page after the detach dip. The
    /// interpolation's other endpoint.
    private var detachedSize: CGSize = .zero
    /// True while the detach spring is settling; pose sets wait for it so a
    /// direct set doesn't stomp the dip mid-flight (position is unaffected —
    /// the dip animates bounds and subviews only).
    private var isDetachSettling = false

    /// Rubber-band caps: generous vertically (the float), tight against
    /// dragging backwards past the origin.
    private let verticalDriftLimit: CGFloat = 140
    private let backDragLimit: CGFloat = 60

    /// Installs the pan on the presented feed's view. `onBeginDismiss` should
    /// call `dismiss(animated: true)` on the presented view controller.
    func attach(
        to view: UIView,
        source: any ZoomTransitionSource,
        destination: any ZoomTransitionDestination,
        onBeginDismiss: @escaping () -> Void
    ) {
        self.source = source
        self.destination = destination
        self.onBeginDismiss = onBeginDismiss
        self.pannedView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    // MARK: - Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = pannedView else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            // Direction was vetted by gestureRecognizerShouldBegin — claim
            // immediately so the card detaches under the finger at frame 0.
            beginGrab()
        case .changed:
            updateDrag(translation: translation, in: view)
        case .ended, .cancelled:
            releaseGrab(
                translation: translation,
                velocity: gesture.velocity(in: view),
                ended: gesture.state == .ended,
                in: view
            )
        default:
            break
        }
    }

    private func beginGrab() {
        // `context == nil` also gates the debug path: a new grab must never
        // begin while a previous transition is still completing.
        guard !isInteracting, context == nil else { return }
        isInteracting = true
        // Freeze the pager so a diagonal drag can't page mid-dismiss.
        destination?.setContentScrollEnabled(false)
        // Triggers dismissal; UIKit calls startInteractiveTransition(_:)
        // synchronously within, so the flight is staged when this returns.
        onBeginDismiss?()
    }

    // MARK: - UIViewControllerInteractiveTransitioning

    /// Stages the same flight the non-interactive animator flies — card,
    /// shadow, dim, receded map — then fires the detach dip and hands control
    /// to the pan events. No transition animation is started: the drag phase
    /// owns the card frame-by-frame.
    func startInteractiveTransition(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from), let source else {
            context.completeTransition(false)
            return
        }
        // Reinstall the map behind the grabbed card — a navigation controller
        // removes non-top views, so it isn't in the hierarchy yet.
        if let toView = context.view(forKey: .to) {
            if let toVC = context.viewController(forKey: .to) {
                toView.frame = context.finalFrame(for: toVC)
            }
            container.insertSubview(toView, at: 0)
        }

        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        // Settle the presenter's own layout FIRST — it was only just
        // reinstalled above — and only then let the source move within it. The
        // order matters: a grid asked to scroll a tile into view against stale
        // bounds computes the wrong offset, and every rect read afterwards
        // inherits the error.
        container.layoutIfNeeded()
        source.zoomSourceWillStageDismissal()
        // The presenter can't move under the user while the feed covers it, so
        // this rect is stable for the grab's lifetime — but it is recomputed at
        // release anyway (see `releaseGrab`), because staging can be seconds
        // earlier on a view that had not settled.
        let sourceFrame = source.zoomHeroFrame(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let flight = ZoomFlight.build(
            source: source, destination: destination, sourceFrame: sourceFrame, pageFrame: pageFrame
        )
        container.insertSubview(flight.card, belowSubview: fromView)
        container.insertSubview(flight.shadow, belowSubview: flight.card)
        container.layoutIfNeeded()
        let screenRadius = ZoomFlight.screenCornerRadius(behind: container)
        flight.poseAsPage(cornerRadius: screenRadius)
        destination?.setZoomContentHidden(true)

        let presentingView = context.viewController(forKey: .to)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)
        presentingView?.transform = CGAffineTransform(
            scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
        )

        self.context = context
        self.flight = flight
        self.dim = dim
        if let nav = context.viewController(forKey: .from)?.navigationController,
           !nav.isToolbarHidden {
            self.toolbar = nav.toolbar
        }
        self.presentingView = presentingView
        self.screenRadius = screenRadius
        self.pageCenter = CGPoint(x: pageFrame.midX, y: pageFrame.midY)
        stagedLanding = sourceFrame
        detachedSize = CGSize(
            width: pageFrame.width * ZoomFlight.detachScale,
            height: pageFrame.height * ZoomFlight.detachScale
        )

        // The detach: a real spring, not a scrubbed keyframe — it registers
        // the instant the grab starts, however slowly the finger then moves.
        // It animates bounds/radius/subviews only; position stays on the live
        // channel, so pan events keep landing during the settle.
        //
        // Deferred one runloop turn, deliberately: a navigation controller
        // *defers* interactive-transition start and runs this method inside
        // setup machinery where `UIView.animate` blocks apply without
        // animating — the dip silently became an instant jump under the push
        // pivot. One hop later the scope is a normal animation context. (Not
        // a UIViewPropertyAnimator: its tracked animations entangled the
        // release spring's completion under the transition, freezing it.)
        isDetachSettling = true
        DispatchQueue.main.async {
            UIView.animate(
                withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                flight.poseFloating(scale: ZoomFlight.detachScale, cornerRadius: self.screenRadius)
            } completion: { _ in
                self.isDetachSettling = false
            }
        }
        context.updateInteractiveTransition(0)
    }

    // MARK: - Drag

    private func updateDrag(translation: CGPoint, in view: UIView) {
        guard isInteracting, let flight, let context else { return }
        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: translation.x, span: view.bounds.width
        )

        // Position channel: free 2D float. Horizontal 1:1 (it is also the
        // progress axis); vertical and back-drag rubber-band so the card
        // follows the hand but resists leaving the dismissal axis.
        let dx = translation.x >= 0
            ? translation.x
            : ZoomTransitionGeometry.rubberBand(translation.x, limit: backDragLimit)
        let dy = ZoomTransitionGeometry.rubberBand(translation.y, limit: verticalDriftLimit)
        flight.card.center = CGPoint(x: pageCenter.x + dx, y: pageCenter.y + dy)

        // Morph channel: pure functions of progress, interpolating the card's
        // size and radius toward the rect it will actually land on. Skipped
        // while the detach spring settles (its endpoint is this function at
        // progress 0, so the handoff is invisible).
        if !isDetachSettling {
            flight.poseInterpolated(
                progress, from: detachedSize, to: stagedLanding, startCornerRadius: screenRadius
            )
        }
        dim?.alpha = 1 - progress
        // The toolbar recedes on the same channel as the dim: pure function
        // of progress, tracking the finger frame-by-frame.
        toolbar?.alpha = 1 - progress
        let mapScale = ZoomFlight.presenterDepthScale + (1 - ZoomFlight.presenterDepthScale) * progress
        presentingView?.transform = CGAffineTransform(scaleX: mapScale, y: mapScale)
        context.updateInteractiveTransition(progress)
    }

    // MARK: - Release

    private func releaseGrab(translation: CGPoint, velocity: CGPoint, ended: Bool, in view: UIView) {
        guard isInteracting, let context, let flight else { return }
        isInteracting = false
        destination?.setContentScrollEnabled(true)

        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: translation.x, span: view.bounds.width
        )
        // Thresholds come from the shared release contract (CoreNavigation),
        // so the pin grab and the timeline slide complete identically.
        let commit = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: progress, velocity: velocity.x
        )
        // The outcome is reported NOW, at release — the framework's contract
        // for the end of the user-driven phase. UIKit then runs the remaining
        // coordinated choreography (the navigation bar's item cross-fade)
        // over the transition's leftover duration on its own clock. An
        // earlier design deferred this to the spring's completion while
        // ramping updateInteractiveTransition alongside — that froze the
        // release animation's clock under the nav pipeline: the completion
        // arrived seconds late, and if a new grab had started by then, the
        // stale completion tore down the NEW grab's transition.
        commit ? context.finishInteractiveTransition() : context.cancelInteractiveTransition()

        // The landing rect is recomputed NOW, not reused from grab-begin: the
        // stage-time value was taken on a map view freshly re-attached after
        // the navigation controller unloaded it, before its restored camera
        // fully settled — and a grab can hold for seconds. The programmatic
        // pop lands pixel-perfect precisely because it converts the pin rect
        // milliseconds before flying; this matches it. Converted at map
        // *identity* (the partial recede would skew the rect, and the spring
        // returns the map to identity by landing time); the toggle is within
        // one transaction, so nothing renders it.
        var landing = flight.sourceFrame
        if commit, let source, source.zoomSourceIsOnScreen {
            let recede = presentingView?.transform ?? .identity
            presentingView?.transform = .identity
            landing = source.zoomHeroFrame(in: context.containerView)
            presentingView?.transform = recede
        }

        // The drag set model values directly, so "current state" needs no
        // presentation-layer capture: the spring starts from the card's exact
        // 2D coordinate and inherits the hand's release velocity — the card
        // is caught mid-air, not restarted.
        let target = commit
            ? CGPoint(x: landing.midX, y: landing.midY)
            : pageCenter
        let springVelocity = Self.normalizedSpringVelocity(
            of: velocity, from: flight.card.center, to: target
        )
        let dim = dim
        let toolbar = toolbar
        let presentingView = presentingView
        let screenRadius = screenRadius
        // The SAME spring as the tap-back dismissal (`ZoomFlight.spring*`), so a
        // released swipe and a tap land with identical physics — commit and
        // cancel alike. Only the initial velocity differs: it's the hand's
        // release velocity (the card is caught mid-fling, not restarted), so a
        // harder fling overshoots more, but the damping curve is one and the
        // same.
        UIView.animate(
            withDuration: ZoomFlight.springDuration, delay: 0,
            usingSpringWithDamping: ZoomFlight.springDamping,
            initialSpringVelocity: springVelocity,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            if commit {
                flight.poseAtSource(at: landing)
                dim?.alpha = 0
                toolbar?.alpha = 0
                presentingView?.transform = .identity
            } else {
                flight.poseAsPage(cornerRadius: screenRadius)
                dim?.alpha = 1
                toolbar?.alpha = 1
                presentingView?.transform = CGAffineTransform(
                    scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
                )
            }
        }
        // Completion by wall clock, NOT by the animation's completion block:
        // UIView completions delivered inside an interactive nav transition's
        // ambit can be deferred indefinitely (observed: a cancel's completion
        // frozen for seconds, then flushed by the NEXT grab's animation — and
        // tearing down that newer grab's transition). A timer makes teardown
        // deterministic; the spring is visuals-only. A hair past the spring's
        // own duration so the card has reached its pose before it's retired.
        DispatchQueue.main.asyncAfter(deadline: .now() + ZoomFlight.springDuration + 0.04) { [weak self] in
            self?.finishTransition(cancelled: !commit)
        }
    }

    /// Tears the stage down exactly like the non-interactive animator's
    /// completion, then reports the outcome to UIKit and drops all state.
    /// (finish/cancelInteractiveTransition was already reported at release.)
    private func finishTransition(cancelled: Bool) {
        flight?.card.removeFromSuperview()
        flight?.shadow.removeFromSuperview()
        dim?.removeFromSuperview()
        presentingView?.transform = .identity
        ZoomFlight.clearRecededChrome(from: presentingView) // reset is covered either way
        // Hand the toolbar back at full alpha: on cancel it stays shown; on
        // commit the feed's disappearance bookkeeping hides it within this
        // same completeTransition turn, so no restored frame can render.
        toolbar?.alpha = 1
        // Restore the feed content for the cancel path; moot when finished.
        destination?.setZoomContentHidden(false)
        destination?.zoomTransitionDidEnd()
        // Unconditional, cancel included: a cancelled grab that left the source
        // hidden strands an invisible tile behind the page, and nothing else
        // would ever restore it if the feed then left by some other route. On
        // the cancel path this is covered by the restored page anyway.
        source?.setZoomSourceHidden(false)
        context?.completeTransition(!cancelled)
        context = nil
        flight = nil
        dim = nil
        toolbar = nil
        isDetachSettling = false
    }

    /// UIKit's spring velocity is normalized to "distances to target per
    /// second": project the hand's speed onto the remaining travel, clamped
    /// so a wild flick can't detonate the spring.
    private static func normalizedSpringVelocity(
        of velocity: CGPoint, from current: CGPoint, to target: CGPoint
    ) -> CGFloat {
        let distance = hypot(target.x - current.x, target.y - current.y)
        guard distance > 1 else { return 0 }
        return min(hypot(velocity.x, velocity.y) / distance, 3)
    }

    #if DEBUG
    /// Scripted grab for sim recordings (`-maps-demo-grab`): touch injection
    /// is impossible in the simulator, so this walks the exact
    /// begin/update/release path a finger drives — a diagonal drag to
    /// (`peakProgress` × width, `verticalDrift`), a hold, then a release.
    /// Whether it completes or springs back is decided by the same threshold
    /// logic as a real release.
    func debugPerformGrab(peakProgress: CGFloat, verticalDrift: CGFloat = 0) async {
        guard let view = pannedView else { return }
        beginGrab()
        let peak = CGPoint(x: peakProgress * view.bounds.width, y: verticalDrift)
        let steps = 30
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let t = CGFloat(step) / CGFloat(steps)
            updateDrag(translation: CGPoint(x: peak.x * t, y: peak.y * t), in: view)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        releaseGrab(translation: peak, velocity: .zero, ended: true, in: view)
    }
    #endif
}

// MARK: - Direction and coexistence

extension ZoomDismissInteractionController: UIGestureRecognizerDelegate {
    /// The whole conflict story lives here: the pan begins only for a
    /// rightward, predominantly horizontal movement, so vertical paging and
    /// pull-to-refresh never see a competitor — and when it does begin, the
    /// intent is unambiguous enough to claim on the spot.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // `context == nil` also gates on the PREVIOUS grab's transition having
        // fully completed — overlapping lifecycles must never share state.
        guard !isInteracting, context == nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let view = pannedView else { return false }
        guard destination?.isReadyForInteractiveDismissal == true else { return false }
        // `context == nil` only covers OUR transitions. A pop of a screen
        // pushed above the feed (profile, comments) can still be settling —
        // the feed is already `topViewController` then, and beginning a grab
        // would start a second pop mid-transition. Refuse; the next grab retries.
        guard (destination as? UIViewController)?.transitionCoordinator == nil else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true // coexist with the pager's pan; we self-gate by direction above
    }
}
