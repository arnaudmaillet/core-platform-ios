import CoreNavigation
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
/// - **Morph** (progress-driven): scale, dim, and map depth are pure
///   functions of `translation.x / width`. The 0.95 detach dip fires as a
///   real spring at `.began` — instant, independent of drag distance.
///
/// Because the drag phase sets *model* values with no animation in flight,
/// release simply springs from the card's exact current 2D coordinate to
/// `poseAsPin` (commit: the same clip-morph home the button dismiss flies)
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

    private var source: MapPinZoomSource?
    private weak var destination: (any ZoomTransitionDestination)?
    /// Kicks off `dismiss(animated:)` on the presented feed when a grab begins.
    private var onBeginDismiss: (() -> Void)?
    private weak var pannedView: UIView?

    // Live-transition state, populated by startInteractiveTransition and
    // cleared when the release animation completes.
    private var context: (any UIViewControllerContextTransitioning)?
    private var flight: ZoomFlight?
    private var dim: UIView?
    private weak var presentingView: UIView?
    private var screenRadius: CGFloat = 0
    private var pageCenter: CGPoint = .zero
    /// True while the detach spring is settling; pose sets wait for it so a
    /// direct set doesn't stomp the dip mid-flight (position is unaffected —
    /// the dip animates bounds and subviews only).
    private var isDetachSettling = false
    /// Ramps the *reported* progress to its endpoint during the release
    /// spring, so everything UIKit coordinates off `updateInteractiveTransition`
    /// (the navigation bar's item cross-fade) settles in step with the card
    /// instead of freezing at the release value and jumping at completion.
    private var releaseLink: CADisplayLink?
    private var releaseRamp: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?

    /// Fraction of the view's *width* a drag must cover to complete on release.
    private let completionThreshold: CGFloat = 0.35
    /// A rightward flick above this speed completes regardless of distance.
    private let flickVelocity: CGFloat = 900
    /// The card keeps shrinking gently past the detach as progress grows.
    private let floatShrink: CGFloat = 0.08
    /// Rubber-band caps: generous vertically (the float), tight against
    /// dragging backwards past the origin.
    private let verticalDriftLimit: CGFloat = 140
    private let backDragLimit: CGFloat = 60

    /// Installs the pan on the presented feed's view. `onBeginDismiss` should
    /// call `dismiss(animated: true)` on the presented view controller.
    func attach(
        to view: UIView,
        source: MapPinZoomSource,
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
        guard !isInteracting else { return }
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
        // The map can't move while the feed covers it, so the pin rect is
        // stable for the lifetime of the grab.
        let pinFrame = source.zoomHeroFrame(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let flight = ZoomFlight.build(
            source: source, destination: destination, pinFrame: pinFrame, pageFrame: pageFrame
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
            scaleX: ZoomFlight.mapDepthScale, y: ZoomFlight.mapDepthScale
        )

        self.context = context
        self.flight = flight
        self.dim = dim
        self.presentingView = presentingView
        self.screenRadius = screenRadius
        self.pageCenter = CGPoint(x: pageFrame.midX, y: pageFrame.midY)

        // The detach: a real spring, not a scrubbed keyframe — it registers
        // the instant the grab starts, however slowly the finger then moves.
        // It animates bounds/radius/subviews only; position stays on the live
        // channel, so pan events keep landing during the settle.
        isDetachSettling = true
        UIView.animate(
            withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            flight.poseFloating(scale: ZoomFlight.detachScale, cornerRadius: screenRadius)
        } completion: { _ in
            self.isDetachSettling = false
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

        // Morph channel: pure functions of progress. Skipped while the detach
        // spring settles (its endpoint differs from these by well under a
        // point at small progress, so the handoff is invisible).
        if !isDetachSettling {
            flight.poseFloating(
                scale: ZoomFlight.detachScale - floatShrink * progress,
                cornerRadius: screenRadius
            )
        }
        dim?.alpha = 1 - progress
        let mapScale = ZoomFlight.mapDepthScale + (1 - ZoomFlight.mapDepthScale) * progress
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
        let commit = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: progress,
            velocity: velocity.x,
            progressThreshold: completionThreshold,
            flickVelocity: flickVelocity
        )
        // finish/cancelInteractiveTransition is reported at the END of the
        // release animation (in finishTransition); until then the ramp below
        // keeps the interaction's reported progress moving with the spring.
        beginReleaseRamp(from: progress, to: commit ? 1 : 0, duration: 0.38)

        // The drag set model values directly, so "current state" needs no
        // presentation-layer capture: the spring starts from the card's exact
        // 2D coordinate and inherits the hand's release velocity — the card
        // is caught mid-air, not restarted.
        let target = commit
            ? CGPoint(x: flight.pinFrame.midX, y: flight.pinFrame.midY)
            : pageCenter
        let springVelocity = Self.normalizedSpringVelocity(
            of: velocity, from: flight.card.center, to: target
        )
        let dim = dim
        let presentingView = presentingView
        let screenRadius = screenRadius
        UIView.animate(
            withDuration: 0.38, delay: 0,
            usingSpringWithDamping: commit ? 0.9 : 0.82,
            initialSpringVelocity: springVelocity,
            options: [.beginFromCurrentState]
        ) {
            if commit {
                flight.poseAsPin()
                dim?.alpha = 0
                presentingView?.transform = .identity
            } else {
                flight.poseAsPage(cornerRadius: screenRadius)
                dim?.alpha = 1
                presentingView?.transform = CGAffineTransform(
                    scaleX: ZoomFlight.mapDepthScale, y: ZoomFlight.mapDepthScale
                )
            }
        } completion: { _ in
            self.finishTransition(cancelled: !commit)
        }
    }

    private func beginReleaseRamp(from: CGFloat, to: CGFloat, duration: TimeInterval) {
        releaseRamp = (from, to, CACurrentMediaTime(), duration)
        let link = CADisplayLink(target: self, selector: #selector(tickReleaseRamp))
        link.add(to: .main, forMode: .common)
        releaseLink = link
    }

    @objc private func tickReleaseRamp() {
        guard let ramp = releaseRamp, let context else {
            releaseLink?.invalidate()
            releaseLink = nil
            return
        }
        let t = min((CACurrentMediaTime() - ramp.start) / ramp.duration, 1)
        // Quadratic ease-out — close enough to the release spring's settle.
        let eased = 1 - pow(1 - t, 2)
        context.updateInteractiveTransition(ramp.from + (ramp.to - ramp.from) * CGFloat(eased))
        if t >= 1 {
            releaseLink?.invalidate()
            releaseLink = nil
        }
    }

    /// Tears the stage down exactly like the non-interactive animator's
    /// completion, then reports the outcome to UIKit and drops all state.
    private func finishTransition(cancelled: Bool) {
        releaseLink?.invalidate()
        releaseLink = nil
        if let ramp = releaseRamp {
            context?.updateInteractiveTransition(ramp.to)
        }
        releaseRamp = nil
        cancelled ? context?.cancelInteractiveTransition() : context?.finishInteractiveTransition()
        flight?.card.removeFromSuperview()
        flight?.shadow.removeFromSuperview()
        dim?.removeFromSuperview()
        presentingView?.transform = .identity
        ZoomFlight.clearRecededChrome(from: presentingView) // reset is covered either way
        // Restore the feed content for the cancel path; moot when finished.
        destination?.setZoomContentHidden(false)
        destination?.zoomTransitionDidEnd()
        if !cancelled {
            source?.zoomSourceDidReturn()
        }
        context?.completeTransition(!cancelled)
        context = nil
        flight = nil
        dim = nil
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
        guard !isInteracting,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let view = pannedView else { return false }
        guard destination?.isReadyForInteractiveDismissal == true else { return false }
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
