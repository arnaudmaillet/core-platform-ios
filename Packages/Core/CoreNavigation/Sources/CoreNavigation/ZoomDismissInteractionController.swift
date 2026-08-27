
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
/// velocity so the card is visibly "caught".
///
/// The grab is armed per AXIS (`ZoomDismissAxis`): rightward, downward, or
/// both, chosen by the owner at attach time. The axis is picked per gesture
/// in `gestureRecognizerShouldBegin` from the hand's velocity — which is
/// what lets `.began` claim immediately — and selects the progress
/// component, the drift component, the span, and the release velocity;
/// every other channel is axis-blind. A vertical grab exists at all because
/// the feed is FORWARD-ONLY: its pager declines downward touches (the
/// mirror of this pan's begin gate), so downward is free the way rightward
/// always was.
@MainActor
final class ZoomDismissInteractionController: NSObject, UIViewControllerInteractiveTransitioning {
    /// Whether a grab is currently driving the dismissal — the transitioning
    /// delegate returns this controller only while true.
    private(set) var isInteracting = false

    /// Weak, like `destination`: the transition controller owns the source for
    /// the flight's lifetime, and this seam only borrows it. A strong copy
    /// here silently doubled the ownership for no benefit.
    private weak var source: (any ZoomTransitionSource)?
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
    /// Chrome belonging to the SOURCE screen that is down while the destination
    /// is up and has to come back with the return — the app's tab bar.
    ///
    /// It is driven here, on the progress channel, for a structural reason: the
    /// tab bar is a sibling of the navigation controller's view inside the tab
    /// bar controller, so it renders ABOVE the transition container and the dim
    /// cannot veil it. Left to a completion handler it snaps in at full opacity
    /// after the card has already landed. Its alpha instead tracks the finger,
    /// which is the same thing the dim does, so the bar is revealed by the hand.
    private weak var returningChrome: UIView?
    private weak var presentingView: UIView?
    private var screenRadius: CGFloat = 0
    private var pageCenter: CGPoint = .zero
    /// The rect the card is flying at, re-read on every pan event (see
    /// `currentLanding`). The drag interpolates toward it, so the card is always
    /// exactly as far home as the finger has taken it — and because release
    /// reads the same function, there is nothing left to correct when the spring
    /// takes over.
    private var stagedLanding: CGRect = .zero
    /// When the detach dip is due to have landed.
    ///
    /// A deadline rather than a flag, because the dip no longer *blocks* the
    /// scale channel — it shares it. Every pan event inside the window
    /// re-targets the dip at the live curve over the time the dip has left, so
    /// the animation converges to zero duration exactly as the window closes
    /// and the handoff to direct sets is continuous by construction.
    private var detachDeadline: CFTimeInterval = 0
    private var isDetachSettling: Bool { CACurrentMediaTime() < detachDeadline }

    /// How long the detach dip takes to settle.
    private static let detachDuration: TimeInterval = 0.18

    /// The card's scale for a drag progress — the ONE curve, used by the drag
    /// and by the detach dip alike.
    ///
    /// Having the dip animate to a constant while the drag used this function
    /// is what put a hole in the scale channel: for the dip's whole 180ms the
    /// finger accumulated progress that nothing applied, and the first ungated
    /// pan event discharged all of it in a single frame. Measured on a scripted
    /// grab: the card's height went 830pt to 774pt in one frame, against
    /// ~5.5pt/frame either side, and the drop grows with drag speed — 252pt at
    /// 1800pt/s.
    static func grabScale(at progress: CGFloat) -> CGFloat {
        let span = ZoomFlight.detachScale - ZoomFlight.minimumGrabScale
        return max(ZoomFlight.detachScale - span * progress, ZoomFlight.minimumGrabScale)
    }
    /// Set when this grab's teardown has restored (or is done with) the
    /// destination, so the staged frame-0 hide — which waits on a display-link
    /// gate — cannot fire afterwards and strand the feed invisible.
    private var hasAbandonedContentHide = false

    /// Which axes may begin a grab, set at attach; the axis of the LIVE grab
    /// is chosen from the hand's velocity in `gestureRecognizerShouldBegin`
    /// and holds for the gesture's whole lifetime.
    private var axes: Set<ZoomDismissAxis> = [.horizontal]
    private var activeAxis: ZoomDismissAxis = .horizontal

    /// Set by the owner alongside `attach`; see `returningChrome`.
    func setReturningChrome(_ chrome: UIView?) {
        returningChrome = chrome
    }

    /// Reports a cancelled grab, so the owner can put back whatever it undid
    /// when the grab began (the tab bar's hidden state). Completed grabs are
    /// reported by the navigation controller's `didShow` instead.
    var onCancelled: (() -> Void)?

    /// Installs the pan on the presented feed's view. `onBeginDismiss` should
    /// pop (or dismiss) the presented view controller; `axes` arms the grab's
    /// directions (both by default — the forward-only feed leaves downward
    /// free everywhere this driver is used).
    func attach(
        to view: UIView,
        source: any ZoomTransitionSource,
        destination: any ZoomTransitionDestination,
        axes: Set<ZoomDismissAxis> = [.horizontal, .vertical],
        onBeginDismiss: @escaping () -> Void
    ) {
        self.source = source
        self.destination = destination
        self.axes = axes
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] GRAB from rest: staging own flight")
        }
        #endif
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
        // Same frame-0 rule as the animator legs, which this staging predated:
        // hiding the feed in the SAME commit that first puts the card (and its
        // freshly attached surface) in the tree trades the page for a surface
        // whose content may not have composited yet — the card's floor for a
        // pass, at the exact start of a grab. Commit first, then the card
        // drawing plus one display tick, then hide. The feed staying opaque
        // over the already-tracking card for those ticks is 8–16ms of finger
        // travel — invisible — and a lightning cancel is covered by the
        // abandon flag, or the restore in `finishTransition` would be undone
        // by a hide still in flight.
        hasAbandonedContentHide = false
        ZoomAnimator.afterCurrentTransactionCommits { [weak self] in
            ZoomAnimator.whenReady(ceiling: ZoomAnimator.maximumFirstFrameHold,
                                   afterTicks: 1,
                                   condition: { [weak card = flight.card] in
                                       card?.zoomLiveMediaIsDrawing ?? true
                                   }) {
                guard let self, !self.hasAbandonedContentHide else { return }
                self.destination?.setZoomContentHidden(true)
            }
        }

        // Depth rides the source-nominated view when there is one; see
        // `ZoomTransitionSource.zoomPresenterDepthView`.
        let presentingView = source.zoomPresenterDepthView ?? context.viewController(forKey: .to)?.view
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
        // ⚠️ ARMED AT REST, HERE, BEFORE ANYTHING HAS MOVED.
        //
        // A destination that tracks the card used to hear about the grab on
        // its FIRST PAN EVENT, which already carries a travelled card and a
        // non-zero rate — so it armed and jumped in the same frame, and the
        // deferred content hide could land in the gap before it. That is the
        // flash and the half-frame of misalignment at the start of a grab.
        //
        // Told the identity state now, it installs a window that is exactly
        // the page it is already showing: nothing changes on screen, and every
        // event after this one is a move from somewhere rather than an arrival
        // from nowhere.
        destination?.setZoomDismissState(ZoomDismissState(
            progress: 0, card: pageFrame, cornerRadius: screenRadius, isSettling: false
        ))

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
        detachDeadline = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detachDeadline = CACurrentMediaTime() + Self.detachDuration
            // Progress is still ~0 one runloop turn in, so this is the same dip
            // it always was; pan events re-aim it from here.
            self.springDetach(flight, to: Self.grabScale(at: 0), progress: 0)
        }
        context.updateInteractiveTransition(0)
    }

    /// Springs the card's scale toward `scale` over whatever the dip has left.
    ///
    /// The shrinking duration is the point. A fixed one re-issued per pan event
    /// behaves like a lag filter — the card trails the finger by the spring's
    /// time constant, and the trailing error has to be discharged somewhere,
    /// which is the very jump this replaces. Winding the duration down to the
    /// deadline makes the animation vanish into a direct set exactly when the
    /// window closes, so there is nothing left to discharge.
    /// The card's corner for a drag progress: the display's at the page, the
    /// source's own at the landing. One curve, so the card and anything drawing
    /// beside it can never be rounded differently.
    private static func grabCornerRadius(
        at progress: CGFloat, screen: CGFloat, flight: ZoomFlight
    ) -> CGFloat {
        screen + (flight.card.zoomRestingCornerRadius - screen) * min(max(progress, 0), 1)
    }

    private func springDetach(_ flight: ZoomFlight, to scale: CGFloat, progress: CGFloat) {
        let remaining = max(detachDeadline - CACurrentMediaTime(), 0)
        let radius = Self.grabCornerRadius(at: progress, screen: screenRadius, flight: flight)
        UIView.animate(
            withDuration: remaining, delay: 0, usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            flight.poseFloating(scale: scale, cornerRadius: radius)
            // ⚠️ THE DESTINATION RIDES THE DIP TOO, from inside the block.
            //
            // The dip is the one stretch of a grab where the card is ANIMATING
            // rather than tracking: it springs to the detached scale on its own
            // curve while the finger may not have moved at all. A destination
            // told the card's model frame jumped straight to the target and sat
            // there while the card was still on its way — the interface and the
            // media visibly out of step at the start of every grab, which is
            // what "they are not synchronised" was.
            //
            // Told the same target from in here, UIKit interpolates its answer
            // on the dip's own spring. Same block, same curve, nothing to keep
            // in step by hand.
            self.destination?.setZoomDismissState(ZoomDismissState(
                progress: progress, card: flight.card.frame,
                cornerRadius: radius, isSettling: false
            ))
        }
    }

    // MARK: - Drag

    /// The source's rect in the container, read with the presenter momentarily
    /// at IDENTITY — which is the space the card's own frame lives in.
    ///
    /// The presenter is part-way through its depth recede for most of a grab, and
    /// converting through that transform would hand back a rect skewed by
    /// whatever scale the finger happens to be at; the spring returns the
    /// presenter to identity by landing time, so identity is the only frame of
    /// reference that is true at the end. The toggle is confined to one
    /// transaction, so nothing can render it. Falls back to the last known rect
    /// when the source has scrolled out of sight, where a real rect does not
    /// exist and `zoomHeroFrame` would answer with a centred collapse.
    private func currentLanding(in container: UIView) -> CGRect {
        guard let source, source.zoomSourceIsOnScreen else { return stagedLanding }
        let recede = presentingView?.transform ?? .identity
        presentingView?.transform = .identity
        let rect = source.zoomHeroFrame(in: container)
        presentingView?.transform = recede
        return rect
    }

    private func updateDrag(translation: CGPoint, in view: UIView) {
        guard isInteracting, let flight, let context else { return }
        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: activeAxis.along(translation),
            span: activeAxis.span(of: view.bounds.size)
        )
        // Re-read the target every event rather than trusting the stage-time
        // snapshot. It is one rect conversion per pan, and it means anything
        // that moves the source mid-grab — a page landing and reloading the
        // grid, a late layout pass — is absorbed continuously instead of
        // surfacing as a correction the moment the finger lifts.
        stagedLanding = currentLanding(in: context.containerView)

        // Position channel: free 2D float, decomposed along the LIVE axis.
        // Travel and back-drag rubber-band along it; drift rubber-bands
        // across it — so the card follows the hand but resists leaving the
        // dismissal axis, whichever axis that is.
        // Both directions resist now. Forward used to be 1:1, so a hard throw
        // could put the card most of the way off screen while the finger was
        // still down — motion that promises the card has left when the gesture
        // can still be abandoned.
        let along = activeAxis.along(translation)
        let bandedAlong = along >= 0
            ? ZoomTransitionGeometry.rubberBand(along, limit: ZoomTransitionGeometry.forwardDragLimit)
            : ZoomTransitionGeometry.rubberBand(along, limit: ZoomTransitionGeometry.backDragLimit)
        let bandedAcross = ZoomTransitionGeometry.rubberBand(
            activeAxis.across(translation), limit: ZoomTransitionGeometry.crossDriftLimit
        )
        let offset = activeAxis.offset(along: bandedAlong, across: bandedAcross)
        flight.card.center = CGPoint(x: pageCenter.x + offset.x, y: pageCenter.y + offset.y)

        // Scale channel: the card shrinks but keeps the PAGE's aspect ratio the
        // whole time it is held.
        //
        // It used to interpolate toward the landing rect, so the card was
        // already becoming tile-shaped under the finger — the post visibly
        // turning into its thumbnail before the viewer had decided anything,
        // and a shape that has to snap back if the grab is abandoned. The
        // aspect morph belongs to the release, which is when the outcome is
        // known: `poseAtSource(at:)` takes the card from this pose to the
        // tile's rect on the landing spring.
        //
        // Applied on EVERY event, dip or no dip. While the dip is settling the
        // curve is handed to it as a moving target rather than skipped, so the
        // finger's travel is never banked up to be released in one frame.
        let scale = Self.grabScale(at: progress)
        // ⚠️ THE CARD ROUNDS AS IT GOES, rather than snapping at the release.
        //
        // It held the display's radius for the whole drag and jumped to the
        // source's on release, which is a step in the one channel the eye is
        // most sensitive to — and it made anything ELSE that rounds with the
        // gesture disagree with it for the length of the grab. Interpolated,
        // the release inherits the shape the drag already had, and a
        // destination that draws alongside the card can be told the same
        // number instead of guessing it.
        let radius = Self.grabCornerRadius(at: progress, screen: screenRadius, flight: flight)
        if isDetachSettling {
            springDetach(flight, to: scale, progress: progress)
        } else {
            flight.poseFloating(scale: scale, cornerRadius: radius)
            // Outside the dip the card is not animating, so its model frame IS
            // what it is showing and a direct set is exact. See `springDetach`
            // for the branch where that stops being true.
            destination?.setZoomDismissState(ZoomDismissState(
                progress: progress, card: flight.card.frame,
                cornerRadius: radius, isSettling: false
            ))
        }
        dim?.alpha = 1 - progress
        // The toolbar recedes on the same channel as the dim: pure function
        // of progress, tracking the finger frame-by-frame.
        toolbar?.alpha = 1 - progress
        // And the source's own chrome arrives on the mirror of it.
        returningChrome?.alpha = progress
        let mapScale = ZoomFlight.presenterDepthScale + (1 - ZoomFlight.presenterDepthScale) * progress
        presentingView?.transform = CGAffineTransform(scaleX: mapScale, y: mapScale)
        context.updateInteractiveTransition(progress)
    }

    // MARK: - Release

    #if DEBUG
    private var releaseProbe: CADisplayLink?
    private var releaseProbeStart: CFTimeInterval = 0
    private weak var releaseProbeCard: UIView?

    /// Samples the card's PRESENTATION frame after a release, under
    /// `-zoom-probe`. A teleport and a spring are indistinguishable in a log
    /// that only records the endpoints; this records the path.
    private func armReleaseProbe(card: UIView) {
        guard ProcessInfo.processInfo.arguments.contains("-zoom-probe") else { return }
        releaseProbe?.invalidate()
        releaseProbeStart = CACurrentMediaTime()
        releaseProbeCard = card
        let link = CADisplayLink(target: self, selector: #selector(sampleRelease))
        link.add(to: .main, forMode: .common)
        releaseProbe = link
    }

    @objc private func sampleRelease() {
        let t = CACurrentMediaTime() - releaseProbeStart
        guard let card = releaseProbeCard, t < 4.0 else {
            releaseProbe?.invalidate(); releaseProbe = nil; return
        }
        let f = card.layer.presentation()?.frame ?? card.layer.frame
        print(String(format: "[release] %.3f card=(%.0f,%.0f,%.0fx%.0f)",
                     t, f.origin.x, f.origin.y, f.width, f.height))
    }
    #endif

    private func releaseGrab(translation: CGPoint, velocity: CGPoint, ended: Bool, in view: UIView) {
        guard isInteracting, let context, let flight else { return }
        isInteracting = false
        destination?.setContentScrollEnabled(true)

        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: activeAxis.along(translation),
            span: activeAxis.span(of: view.bounds.size)
        )
        // Thresholds come from the shared release contract (CoreNavigation),
        // so the pin grab and the timeline slide complete identically — and
        // both axes read the same fraction-of-span and flick numbers.
        let commit = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: progress, velocity: activeAxis.along(velocity)
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

        // Read once more at release, through the same function the drag used, so
        // the spring starts from the card's current shape and ends on the rect
        // the drag was already aiming at — nothing to correct. It matters that
        // this is not the stage-time value: a grab can hold for seconds, and on
        // the map it is taken on a view freshly re-attached after the navigation
        // controller unloaded it, before its restored camera settled.
        let landing = commit ? currentLanding(in: context.containerView) : flight.sourceFrame

        // The drag set model values directly, so "current state" needs no
        // presentation-layer capture: the spring starts from the card's exact
        // 2D coordinate and inherits the hand's release velocity — the card
        // is caught mid-air, not restarted.
        let target = commit
            ? CGPoint(x: landing.midX, y: landing.midY)
            : pageCenter
        let springVelocity = ZoomTransitionGeometry.springVelocity(
            of: velocity, from: flight.card.center, to: target
        )
        #if DEBUG
        armReleaseProbe(card: flight.card)
        #endif
        let dim = dim
        let toolbar = toolbar
        let returningChrome = returningChrome
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
            // ⚠️ THE DESTINATION RIDES THIS BLOCK, it does not run a spring of
            // its own.
            //
            // A destination that is more than its media has been tracking the
            // card frame by frame, and the release is where a second animation
            // would start drifting from the first. Told the OUTCOME's values
            // from inside this block, every property it sets in answer — its
            // window, its transform, its alpha — is interpolated by UIKit on
            // exactly the spring the card is on. Cancel therefore carries the
            // interface back to full screen with the card, and commit carries
            // it onto the tile and to nothing, which is also the state its
            // teardown expects: there is no frame where the two disagree.
            self.destination?.setZoomDismissState(ZoomDismissState(
                progress: commit ? 1 : 0,
                card: commit ? landing : flight.pageFrame,
                cornerRadius: commit ? flight.card.zoomRestingCornerRadius : screenRadius,
                isSettling: true
            ))
            if commit {
                flight.poseAtSource(at: landing)
                dim?.alpha = 0
                toolbar?.alpha = 0
                returningChrome?.alpha = 1
                presentingView?.transform = .identity
            } else {
                flight.poseAsPage(cornerRadius: screenRadius)
                dim?.alpha = 1
                toolbar?.alpha = 1
                returningChrome?.alpha = 0
                presentingView?.transform = CGAffineTransform(
                    scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
                )
            }
        }
        // Teardown follows the ANIMATION, not the wall clock.
        //
        // This was a fixed `asyncAfter(springDuration + 0.04)`, on the
        // reasoning that UIView completions inside an interactive nav
        // transition's ambit can be deferred indefinitely — which is real, and
        // is why the completion block is still not used here.
        //
        // But a delay and a spring are two clocks, and Slow Animations stretches
        // only one of them. Measured: the card was retired 0.46s after release
        // with its presentation frame still at 688pt of 831 — barely a sixth of
        // the way home — so it vanished mid-flight and the tile appeared. That
        // is what reads as an instant teleport on release.
        //
        // Nor can the factor simply be looked up: the simulator does not
        // implement the slowdown as a layer speed, and the window reports 1.0
        // either way (measured). So this watches the card's PRESENTATION
        // instead, which is on whatever clock the animation is actually on, and
        // keeps a wall-clock ceiling as the backstop the old timer was.
        whenViewSettles(flight.card, ceiling: viewSettleCeiling) { [weak self] in
            self?.finishTransition(cancelled: !commit)
        }
    }

    /// Tears the stage down exactly like the non-interactive animator's
    /// completion, then reports the outcome to UIKit and drops all state.
    /// (finish/cancelInteractiveTransition was already reported at release.)
    private func finishTransition(cancelled: Bool) {
        // Whatever happens below, the staged frame-0 hide is stale from here.
        hasAbandonedContentHide = true
        // The two steps the non-interactive completion performs and this one
        // did not: hand the card's live surface to the source, then hold the
        // card over the landing until that surface is actually drawing.
        //
        // This path is the one a real finger takes, and it removed the card on
        // its first line — so whenever the landing tile was not already
        // rendering, the card vanished and the tile's COVER IMAGE was what
        // appeared. A scripted dismissal hides this because it always lands on
        // the post it left from, whose player never stopped; anything that
        // makes the landing not-instant (a slow stream, a dismissal to a post
        // the viewer scrolled to) exposes it.
        //
        // The hold owns removing the card. A cancelled grab has no landing to
        // wait for — the page is coming back — so its card goes immediately.
        if !cancelled, let card = flight?.card {
            if let surface = card.zoomLiveMediaSurface {
                source?.zoomAdoptLiveMediaView(surface)
            }
            ZoomAnimator.holdCard(card,
                                  liveMediaIsDrawing: { [weak card] in
                                      card?.zoomLiveMediaIsDrawing ?? true
                                  },
                                  liveMediaState: { [weak card] in
                                      card?.zoomLiveMediaDebugState ?? "card gone"
                                  },
                                  finalizeLanding: { [weak sourceRef = source] in
                                      sourceRef?.zoomFinalizeLanding()
                                  },
                                  path: "grab",
                                  while: { [weak sourceRef = source] in
                                      sourceRef.map { !$0.zoomLandingMediaIsReady } ?? false
                                  })
        } else {
            flight?.card.removeFromSuperview()
        }
        flight?.shadow.removeFromSuperview()
        dim?.removeFromSuperview()
        presentingView?.transform = .identity
        ZoomFlight.clearRecededChrome(from: presentingView) // reset is covered either way
        // Hand the toolbar back at full alpha: on cancel it stays shown; on
        // commit the feed's disappearance bookkeeping hides it within this
        // same completeTransition turn, so no restored frame can render.
        toolbar?.alpha = 1
        // Restore the feed content for the cancel path; moot when finished.
        destination?.setZoomDismissState(ZoomDismissState(
            progress: 0, card: .zero, cornerRadius: 0, isSettling: false
        ))
        destination?.setZoomContentHidden(false)
        destination?.zoomTransitionDidEnd()
        // Unconditional, cancel included: a cancelled grab that left the source
        // hidden strands an invisible tile behind the page, and nothing else
        // would ever restore it if the feed then left by some other route. On
        // the cancel path this is covered by the restored page anyway.
        source?.setZoomSourceHidden(false)
        // A cancelled grab has to hand back the hidden state the owner undid
        // when the grab began; a completed one is reported through `didShow`.
        if cancelled {
            onCancelled?()
        }
        context?.completeTransition(!cancelled)
        context = nil
        flight = nil
        dim = nil
        toolbar = nil
        detachDeadline = 0
    }

    #if DEBUG
    /// Scripted grab for sim recordings (`-maps-demo-grab`): touch injection
    /// is impossible in the simulator, so this walks the exact
    /// begin/update/release path a finger drives — a diagonal drag to
    /// (`peakProgress` × span, `drift` across it), a hold, then a release.
    /// Whether it completes or springs back is decided by the same threshold
    /// logic as a real release. `axis` substitutes for the velocity vetting a
    /// real gesture gets in `gestureRecognizerShouldBegin`.
    func debugPerformGrab(
        peakProgress: CGFloat, verticalDrift: CGFloat = 0, axis: ZoomDismissAxis = .horizontal
    ) async {
        guard let view = pannedView else { return }
        activeAxis = axis
        beginGrab()
        let peak = axis.offset(
            along: peakProgress * axis.span(of: view.bounds.size), across: verticalDrift
        )
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
    /// The whole conflict story lives here: the pan begins only for an
    /// outbound movement predominantly along one ARMED axis (rightward, or —
    /// with the pager forward-only — downward), so the paging the feed still
    /// owns never sees a competitor — and when it does begin, the intent is
    /// unambiguous enough to claim on the spot.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // `context == nil` also gates on the PREVIOUS grab's transition having
        // fully completed — overlapping lifecycles must never share state.
        guard !isInteracting, context == nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let view = pannedView else { return grabLog("no pan/view", false) }
        guard destination?.isReadyForInteractiveDismissal == true
        else { return grabLog("not ready", false) }
        // ⚠️ ONLY FOR A POST THAT HAS SOMETHING TO FLY.
        //
        // This screen is a pager: the post being dismissed is not always the
        // one that opened it, and a text page has no media for a hero to carry.
        // Refusing here leaves the drag to the driver that carries a whole card
        // instead — the two gate on the same question, from opposite sides, so
        // exactly one of them claims any given grab.
        guard destination?.zoomDismissalKind != .card
        else { return grabLog("post wants a card, not a hero", false) }
        // `context == nil` only covers OUR transitions. A pop of a screen
        // pushed above the feed (profile, comments) can still be settling —
        // the feed is already `topViewController` then, and beginning a grab
        // would start a second pop mid-transition. Refuse; the next grab retries.
        guard (destination as? UIViewController)?.transitionCoordinator == nil
        else { return grabLog("transition settling", false) }
        guard let axis = ZoomDismissAxis.match(velocity: pan.velocity(in: view), axes: axes)
        else { return grabLog("no axis v=\(pan.velocity(in: view))", false) }
        // The vertical axis carries one gate the horizontal never needed: the
        // destination may host subsurfaces that own their own vertical
        // gestures (a scrolling rail, an open comments panel), and a grab
        // must not fight them. The destination answers per touch; horizontal
        // grabs keep their historical behaviour unchanged.
        if axis == .vertical,
           destination?.zoomVerticalDismissalPermitted(at: pan.location(in: view), in: view) == false {
            return false
        }
        // And the horizontal axis has tenants too, since a post's media became
        // a carousel: a rightward drag on its pages means "previous photo" and
        // not "dismiss". Same per-touch question, asked of the same authority —
        // the destination is the only thing that knows which page it is on.
        // ⚠️ The gesture's ORIGIN, not where the finger is now.
        //
        // `gestureRecognizerShouldBegin` fires once a pan has already travelled
        // its slop, so `location(in:)` here is tens of points along the drag —
        // measured at x=52 for a drag that started at x=12. A rule about the
        // screen's leading strip read that as "not the edge" and refused, which
        // is the second wrong answer this bug produced.
        let origin = CGPoint(
            x: pan.location(in: view).x - pan.translation(in: view).x,
            y: pan.location(in: view).y - pan.translation(in: view).y
        )
        if axis == .horizontal,
           destination?.zoomHorizontalDismissalPermitted(at: origin, in: view) == false {
            return grabLog("horizontal refused at x=\(origin.x)", false)
        }
        activeAxis = axis
        return grabLog("BEGIN \(axis) from x=\(origin.x)", true)
    }

    /// `-grab-log`: every begin decision, with the reason it went that way.
    ///
    /// A grab that never begins is indistinguishable ON SCREEN from a grab that
    /// begins and cancels, and from a touch that never reached this recognizer
    /// at all. Three causes, one symptom — nothing happens — which is why the
    /// last attempt at this bug was a guess.
    @discardableResult
    private func grabLog(_ reason: String, _ answer: Bool) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print(String(format: "[grab] %.3f %@ -> %@",
                         CACurrentMediaTime(), reason, answer ? "yes" : "no"))
        }
        #endif
        return answer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true // coexist with the pager's pan; we self-gate by direction above
    }
}
