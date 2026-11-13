
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
/// - **Morph** (progress-driven): the card's size and radius, the dim, the
///   presenter's depth, the destination and UIKit's percent are all pure
///   functions of ONE eased shrink (`grabEase`) of `translation / span`.
///   Nothing happens at `.began`: the card is the page, at its size, until
///   the finger travels (#2362 removed the 0.95 detach dip).
///
/// Because the drag phase sets *model* values with no animation in flight,
/// release simply springs from the card's exact current 2D coordinate to
/// `poseAtSource` (commit: the same clip-morph home the button dismiss flies)
/// or `poseAsPage` (cancel), seeding the spring with the gesture's release
/// velocity so the card is visibly "caught".
///
/// A cancel keeps the transition interactive until its spring has settled,
/// and a grab during that spring catches the card where it is
/// (`catchSettlingCard`, #2362) — the same transition, carried on.
///
/// The grab is armed per AXIS (`ZoomDismissAxis`): rightward, downward, or
/// both, chosen by the owner at attach time. The axis is picked per gesture
/// in `gestureRecognizerShouldBegin` from the hand's velocity — which is
/// what lets `.began` claim immediately — and selects the progress
/// component, the drift component, the span, and the release velocity;
/// every other channel is axis-blind. A vertical grab exists because the
/// feed's FIRST post leaves downward free: there its pager declines downward
/// touches (the mirror of this pan's begin gate). On any later post the
/// downward drag pages back, and the feed's own gate refuses this pan
/// (`zoomVerticalDismissalPermitted`, #2056).
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
    /// The grab's pan, which UIKit's own pops wait on
    /// (`NativePopSubordination`).
    private(set) weak var pan: ZoomDismissPan?

    // Live-transition state, populated by startInteractiveTransition and
    // cleared when the release animation completes.
    private var context: (any UIViewControllerContextTransitioning)?
    private var flight: ZoomFlight?
    /// The held card's give — see `GrabDeformation`. Lives for one grab.
    private var deformation: GrabDeformation?
    private var dim: UIView?
    // ⚠️ NO TOOLBAR HERE, and there used to be one. The grab captured the
    // feed's native `UIToolbar` and wrote `alpha = 1 - progress` on it every
    // pan event, then 0/1 on the release spring. Native chrome is UIKit's
    // (see `TabBarRevealPolicy`): the feed hides its toolbar with
    // `setToolbarHidden(_:animated: true)` as it disappears, and UIKit runs
    // that alongside this transition exactly as it runs the navigation bar's
    // item cross-fade.
    private weak var presentingView: UIView?
    private var screenRadius: CGFloat = 0
    private var pageCenter: CGPoint = .zero
    /// The rect the card is flying at, re-read on every pan event (see
    /// `currentLanding`). The drag interpolates toward it, so the card is always
    /// exactly as far home as the finger has taken it — and because release
    /// reads the same function, there is nothing left to correct when the spring
    /// takes over.
    private var stagedLanding: CGRect = .zero

    // ⚠️ NO DETACH DIP (#2362, the owner 2026-11-12). The grab used to spring
    // the card to 0.95 in 0.18 s at `.began`, before the finger had travelled,
    // and then had to hand the scale channel back to the drag mid-spring
    // (a deadline, a "yield" on the first travel, the presented bounds adopted
    // as the model). Instagram's Explore post has no such dip, and ours was
    // the zoom out at every grab and the jump at every grab / let go / grab
    // again. With it went all of that hand-over: the scale channel is set
    // directly on every event, from the first.

    /// A cancel's spring is carrying the card home and the transition is still
    /// interactive: a grab now catches the card (`catchSettlingCard`).
    private(set) var isCancelSettling = false
    /// Bumped by every release and every catch, so a settle watch that belongs
    /// to a release a re-grab has since caught tears nothing down.
    private var releaseGeneration = 0
    /// What the current grab continues from — `.none` for a grab from rest.
    private var grabCatch = ZoomGrabCatch.none
    /// The re-grab pan's own translation at its `.began`, which is where the
    /// caught pose stands: the drag continues from there without the pan's
    /// slop as a step.
    private var catchPanTranslation: CGPoint = .zero
    /// The pan a re-grab arrives on. It lives on the release's touch shield,
    /// which covers the feed (and its own pan) for the whole release.
    private weak var regrabPan: UIPanGestureRecognizer?
    /// The last percent told to UIKit, which holds it there through a
    /// cancel's spring.
    private var reportedPercent: CGFloat = 0
    /// What UIKit was holding at a catch, minus what the caught shrink would
    /// report — owed the same way the shrink's own gap is
    /// (`ZoomGrabCatch.weight`), so the bars' alongside animations (the
    /// footer's fade) do not step at a catch either.
    private var catchPercentOffset: CGFloat = 0

    /// How far the held card has shrunk for a drag progress: 0 at the page,
    /// 1 at `minimumGrabScale` — the ONE curve every channel of the drag reads
    /// (size, corners, dim, presenter depth, destination, UIKit's percent).
    ///
    /// Eased (#2362): `progress ^ grabShrinkExponent`, flat at the start so a
    /// grab first just carries the page, 0.25 at half the span (a scale of
    /// 0.9), the floor only at the full span.
    nonisolated static func grabEase(at progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return pow(clamped, ZoomFlight.grabShrinkExponent)
    }

    /// The card's scale for a shrink: 1 at none, `minimumGrabScale` at the
    /// whole — and never below it. A negative shrink (a cancel spring's
    /// overshoot, caught) reads above 1.
    nonisolated static func grabScale(forEase ease: CGFloat) -> CGFloat {
        max(1 - (1 - ZoomFlight.minimumGrabScale) * ease, ZoomFlight.minimumGrabScale)
    }

    /// `grabScale(forEase:)` run backwards — what shrink a presented scale is.
    nonisolated static func grabEase(forScale scale: CGFloat) -> CGFloat {
        (1 - scale) / (1 - ZoomFlight.minimumGrabScale)
    }

    /// The card's scale for a drag progress. Having two definitions of this
    /// (the dip's and the drag's) once put a 56pt hole in the scale channel;
    /// there is one, and the tests pin its shape.
    nonisolated static func grabScale(at progress: CGFloat) -> CGFloat {
        grabScale(forEase: grabEase(at: progress))
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

    #if DEBUG
    /// Which axes this driver was armed for, so a harness can pick the one it
    /// means. A stack that carries an intermediate screen attaches TWO drivers
    /// with disjoint axis sets, and a script that always drove the first could
    /// only ever reach one of the two destinations.
    var debugArmedAxes: Set<ZoomDismissAxis> { axes }
    #endif

    /// Whether `upward` rides with `vertical` on this driver (`withUpward`).
    /// Off for a driver whose vertical lands BENEATH (a place page) while a
    /// sibling driver, armed with `upward` explicitly, takes the end of the
    /// list to the source (#761). ⚠️ Outside `#if DEBUG`: Release begins on it.
    var armsUpward = true
    /// The axes this driver begins along.
    var debugEffectiveAxes: Set<ZoomDismissAxis> { armsUpward ? ZoomDismissAxis.withUpward(axes) : axes }

    override init() {
        super.init()
        #if DEBUG
        ZoomDebugCensus.increment(ZoomDebugCensus.Key.grabDriver)
        #endif
    }

    #if DEBUG
    deinit {
        ZoomDebugCensus.decrement(ZoomDebugCensus.Key.grabDriver)
    }
    #endif

    /// Reports a cancelled grab, so the owner can put back whatever it undid
    /// when the grab began. Completed grabs are reported by the navigation
    /// controller's `didShow` instead.
    var onCancelled: (() -> Void)?

    /// Installs the pan on the presented feed's view. `onBeginDismiss` should
    /// pop (or dismiss) the presented view controller; `axes` arms the grab's
    /// directions (both by default — the feed leaves downward free on its
    /// first post, and its destination gate says where, #2056).
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
        // ⚠️ A REUSED VIEW KEEPS EVERY PAN EVER ADDED TO IT. For You hands the
        // same feed to every opening, and each attached a fresh pan that
        // outlived its driver: a recognizer with no target and no delegate,
        // which begins on any drag (its delegate's default) and arbitrates
        // against the pager. N openings left N-1 of them. The dead ones are
        // swept here, at the one moment a new one is about to join them;
        // live siblings (the cluster gallery's second axis) stay.
        Self.removeDeadPans(from: view)
        let pan = ZoomDismissPan(target: self, action: #selector(handlePan))
        pan.driver = self
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        self.pan = pan
    }

    /// Removes every dismissal pan on `view` whose driver is gone.
    static func removeDeadPans(from view: UIView) {
        for pan in view.gestureRecognizers ?? [] {
            guard let dismissal = pan as? ZoomDismissPan, dismissal.driver == nil else { continue }
            view.removeGestureRecognizer(dismissal)
        }
    }

    // MARK: - Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = pannedView else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            if gesture === regrabPan {
                // A grab during the cancel spring: the card is caught where
                // it is and this drag carries on from there (#2362).
                catchSettlingCard(panTranslation: translation)
                return
            }
            // Direction was vetted by gestureRecognizerShouldBegin — claim
            // immediately so the card follows the finger from frame 0.
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

    /// Disarms a grab that has no transition: the driver can begin again,
    /// and the pager scrolls again.
    private func abandonUnstagedGrab() {
        isInteracting = false
        destination?.setContentScrollEnabled(true)
    }

    /// Internal (not private) so the arming rule is testable without a finger.
    func beginGrab() {
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
    /// shadow, dim, receded map — at the page's own pose, and hands control to
    /// the pan events. No animation is started, at staging or at `.began`:
    /// the drag phase owns the card frame-by-frame.
    func startInteractiveTransition(_ context: any UIViewControllerContextTransitioning) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] GRAB from rest: staging own flight")
        }
        #endif
        let container = context.containerView
        guard let fromView = context.view(forKey: .from), let source else {
            context.completeTransition(false)
            // `beginGrab` armed this driver and froze the pager before UIKit
            // got here; nothing will release a grab that never staged.
            abandonUnstagedGrab()
            return
        }
        // ⚠️ SETUP WITH VIEW ANIMATIONS OFF — see `ZoomAnimator.present` for the
        // measurement. iOS 26/27 calls this inside an implicit animation
        // context of the transition's duration, so a frame or a first layout
        // assigned here would animate from the view's previous (or zero)
        // frame: the screen unfolding from the top-left. The poses below are
        // frame 0; only the blocks after the restore may animate.
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
        // The grab takes the screen — see `ZoomAnimator.dismiss`.
        ZoomLandingLeftovers.clear(over: fromView)
        ZoomLandingLeftovers.clear(over: container)
        // Rotation waits for the grab (`FlightOrientationLock`). Its emotes
        // sit it out — unless the grab moves the live page (#1915): nothing
        // is drawn twice then, and the page's interface stays alive in the
        // viewer's hand, its emote wheel included.
        orientationLease?.release()
        orientationLease = FlightOrientationLock.acquire(
            in: destination?.zoomGrabCarriesLiveInterface == true ? nil : container.window
        )
        // Reinstall the map behind the grabbed card — a navigation controller
        // removes non-top views, so it isn't in the hierarchy yet.
        if let toView = context.view(forKey: .to) {
            if let toVC = context.viewController(forKey: .to) {
                toView.frame = context.finalFrame(for: toVC)
            }
            container.insertSubview(toView, at: 0)
        }

        // Settle the presenter's own layout FIRST — it was only just
        // reinstalled above — and only then let the source move within it. The
        // order matters: a grid asked to scroll a tile into view against stale
        // bounds computes the wrong offset, and every rect read afterwards
        // inherits the error.
        container.layoutIfNeeded()
        // The page rect too is read AFTER that layout, as the tap-back reads
        // it, with the same fallback for a rect that is not one.
        let pageFrame = ZoomTransitionGeometry.pageFrame(
            measured: destination?.zoomTargetFrame(in: container), container: container.bounds
        )
        source.zoomSourceWillStageDismissal()
        // ⚠️ THE GRAB ASSERTS THE CONCEALMENT RATHER THAN INHERITING IT.
        //
        // The card is the source's twin, so for the length of this gesture the
        // original must not also be on screen — and until now that was true
        // only by inheritance: the PUSH hid it (`ZoomAnimator`'s frame-0
        // handoff) and nothing re-applied it. Inheritance is not enough here.
        // The hide is an `isHidden` flag on one view instance, and this line is
        // the first thing that runs after the presenter has been put back in
        // the window — which is exactly when MapKit re-realizes its annotation
        // views (`prepareForReuse` resets `isHidden`) and when a settling
        // region can mint a replacement marker. Either one leaves the twin
        // showing under the page for the whole drag.
        //
        // Idempotent everywhere it is not needed, and the same thing the reveal
        // driver has always done at its own staging.
        source.setZoomSourceHidden(true)
        // The presenter can't move under the user while the feed covers it, so
        // this rect is stable for the grab's lifetime — but it is recomputed at
        // release anyway (see `releaseGrab`), because staging can be seconds
        // earlier on a view that had not settled.
        let sourceFrame = ZoomTransitionGeometry.sourceFrame(
            measured: source.zoomHeroFrame(in: container), container: container.bounds
        )

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
                // ⚠️ A SURFACE THAT STOPPED DRAWING. The hold timed out on a
                // donated surface that had a frame when it was taken and has
                // shown nothing since — measured on a grab within ~2 s of a
                // cluster feed's landing: the window flew EMPTY over the place
                // page and the feed underneath went black. The card's cover
                // comes back before the page is hidden.
                if let card = self.flight?.card, !card.zoomLiveMediaIsDrawing {
                    card.zoomLiveMediaDidStall()
                }
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
        deformation?.cancel()
        deformation = GrabDeformation(layer: flight.card.layer)
        self.dim = dim
        #if DEBUG
        // ⚠️ HERE, AND NOWHERE EARLIER. Armed from `beginGrab` — either before
        // or after `onBeginDismiss`, both were tried — the sampler read
        // `flight == nil` and recorded not one frame, with no error and a log
        // that looked exactly like a passing one. The staging is what makes a
        // card exist, so the arming belongs where the card is assigned.
        ZoomGeometrySampler.shared.start(card: flight.mediaCard, label: "grab")
        // `-grab-frames`: the held stretch's and the release's frame pacing
        // (#1915) — what drawing the page at a scale costs.
        GrabFramePacer.shared.start()
        #endif
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

        // ⚠️ AND NOTHING ELSE AT THE GRAB (#2362). The detach dip that sprang
        // the card to 0.95 here, one runloop turn later, is gone: the card is
        // the page — its size, the display's corners — until the finger
        // travels, and every channel is set directly by the pan events.
        isCancelSettling = false
        grabCatch = .none
        catchPanTranslation = .zero
        catchPercentOffset = 0
        reportedPercent = 0
        context.updateInteractiveTransition(0)
    }

    /// The card's corner for a shrink: the display's own, scaled with
    /// the card. One curve, so the card and anything drawing beside it can
    /// never be rounded differently.
    ///
    /// ⚠️ IT USED TO SWEEP TOWARD THE LANDING'S, and the note that asked for
    /// that is kept here because it was solving a real problem the wrong way.
    /// It read: the card "held the display's radius for the whole drag and
    /// jumped to the source's on release, which is a step in the one channel
    /// the eye is most sensitive to". True of a radius that was CONSTANT while
    /// the card shrank — the shape drifting further from the screen's the
    /// smaller it got — and the answer was to start arriving early instead.
    ///
    /// Scaled with the card, there is no drift to compensate and no step to
    /// avoid: radius over size is the screen's at every instant of the drag,
    /// and the release's spring carries the corner to the landing's along with
    /// the frame (`poseAtSource` sets it from inside the animation block). The
    /// reveal reached the same rule from the other end — see
    /// `RevealStage.heldRadius` — after a viewer reported its window turning
    /// into a capsule halfway through a drag that had decided nothing.
    private static func grabCornerRadius(forEase ease: CGFloat, screen: CGFloat) -> CGFloat {
        screen * grabScale(forEase: ease)
    }

    /// Clears a cancel spring's in-flight animations across the card and
    /// everything autoresized under it, so a catch leaves no residue — a
    /// UIView animation is not cancelled by writing its property, and an
    /// additive one would keep adding what it had left onto the caught pose.
    ///
    /// The whole subtree, because the card's live surface and its host are
    /// sized by autoresizing: they carry their own copy of every `bounds.size`
    /// animation the card was given, and leaving those behind would keep the
    /// picture interpolating under a frame that has stopped.
    ///
    /// Except the card's own `transform`: no pose writes it, so what rides it
    /// is the give easing out (`GrabDeformation.release`), which a catch has
    /// no reason to cut short.
    static func stopSpringAnimations(on layer: CALayer, keepingTransform: Bool = true) {
        for key in layer.animationKeys() ?? [] {
            let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath
            if keepingTransform, path == "transform" { continue }
            layer.removeAnimation(forKey: key)
        }
        layer.sublayers?.forEach { stopSpringAnimations(on: $0, keepingTransform: false) }
    }

    /// Removes the animations on `layer` (only — not its sublayers) whose key
    /// path is `keyPath`: what a catch takes off the dim and the presenter,
    /// which may carry animations that are not the release's.
    private static func stopAnimations(on layer: CALayer?, keyPath: String) {
        guard let layer else { return }
        for key in layer.animationKeys() ?? []
        where (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath == keyPath {
            layer.removeAnimation(forKey: key)
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
        let rect = ZoomTransitionGeometry.sourceFrame(
            measured: source.zoomHeroFrame(in: container), container: container.bounds
        )
        presentingView?.transform = recede
        return rect
    }

    /// The drag translation a pan's own translation stands for: the pan's,
    /// for a grab from rest; the caught pose's plus whatever the re-grab pan
    /// has travelled since its `.began`, for a catch.
    private func dragTranslation(fromPan translation: CGPoint) -> CGPoint {
        CGPoint(
            x: grabCatch.translation.x + translation.x - catchPanTranslation.x,
            y: grabCatch.translation.y + translation.y - catchPanTranslation.y
        )
    }

    /// Internal (not private) so a test can drive the drag without a finger.
    func updateDrag(translation: CGPoint, in view: UIView) {
        guard isInteracting, flight != nil, context != nil else { return }
        applyDrag(dragTranslation(fromPan: translation), in: view)
    }

    /// Poses every channel of the held grab for a drag translation.
    private func applyDrag(_ translation: CGPoint, in view: UIView) {
        guard let flight, let context else { return }
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
            ? ZoomTransitionGeometry.rubberBand(
                along,
                limit: ZoomTransitionGeometry.forwardDragLimit(
                    forSpan: activeAxis.span(of: view.bounds.size)
                )
            )
            : ZoomTransitionGeometry.rubberBand(along, limit: ZoomTransitionGeometry.backDragLimit)
        let bandedAcross = ZoomTransitionGeometry.rubberBand(
            activeAxis.across(translation), limit: ZoomTransitionGeometry.crossDriftLimit
        )
        let offset = activeAxis.offset(along: bandedAlong, across: bandedAcross)
        flight.card.center = CGPoint(x: pageCenter.x + offset.x, y: pageCenter.y + offset.y)
        // The give: the card stretches a little along the way it is carried —
        // measured from the card's own (banded) travel, so what it leans into
        // is the motion the viewer sees.
        deformation?.track(translation: offset)

        // ⚠️ ONE SHRINK FOR EVERY CHANNEL (#2362). Eased (`grabEase`): flat at
        // the start, so a grab first just carries the page — no zoom out at
        // the grab, none over the first ~60pt —, 0.9 at half the span, the
        // floor only at the full span. A re-grab continues from the shrink it
        // caught (`ZoomGrabCatch.ease`), which is the curve's for a grab from
        // rest.
        let shrink = grabCatch.ease(at: progress)
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
        let scale = Self.grabScale(forEase: shrink)
        // ⚠️ THE CARD ROUNDS AS IT GOES, rather than snapping at the release.
        //
        // It held the display's radius for the whole drag and jumped to the
        // source's on release, which is a step in the one channel the eye is
        // most sensitive to — and it made anything ELSE that rounds with the
        // gesture disagree with it for the length of the grab. Interpolated,
        // the release inherits the shape the drag already had, and a
        // destination that draws alongside the card can be told the same
        // number instead of guessing it.
        let radius = Self.grabCornerRadius(forEase: shrink, screen: screenRadius)
        // Set directly, on every event, from the first: nothing in a held
        // grab is on a spring, so the card's model frame IS what it shows and
        // the destination can be told it exactly.
        flight.poseFloating(scale: scale, cornerRadius: radius)
        let shown = min(max(shrink, 0), 1)
        destination?.setZoomDismissState(ZoomDismissState(
            progress: shown, card: flight.card.frame,
            cornerRadius: radius, isSettling: false
        ))
        // The dim, the presenter's depth and UIKit's percent — which scrubs
        // the bars' alongside animations, the footer's fade among them — ride
        // the same shrink: nothing changes at touch-down that a short drag
        // has not earned, and nothing parts from the card.
        dim?.alpha = 1 - shrink
        let mapScale = ZoomFlight.presenterDepthScale + (1 - ZoomFlight.presenterDepthScale) * shrink
        presentingView?.transform = CGAffineTransform(scaleX: mapScale, y: mapScale)
        let percent = min(max(shown + catchPercentOffset * grabCatch.weight(at: progress), 0), 1)
        reportedPercent = percent
        context.updateInteractiveTransition(percent)
    }

    // MARK: - Re-grab

    /// A grab during the cancel spring: catches the card where it IS — its
    /// presented pose, scale and position — and carries the drag on from
    /// there, in the same transition (#2362).
    ///
    /// ⚠️ WHY THE SAME TRANSITION. UIKit's interactive transition cannot be
    /// re-entered once it has been told the outcome: a cancelled pop has to
    /// complete before another can begin, and a second pop begun in the same
    /// turn as the first one's completion is UIKit bookkeeping nobody here can
    /// vouch for. So a cancel is no longer reported at the release
    /// (`releaseGrab`): the transition stays interactive while the spring
    /// carries the card home, and only when the card has settled is the
    /// cancel reported and the stage torn down. A grab in between simply
    /// resumes driving it — no teardown, no second staging, no surface handed
    /// back and forth, no frame at full screen.
    ///
    /// Every channel the spring moves is caught at its presented value and
    /// stopped there, so the pose on screen does not change at the catch; the
    /// next pan event moves it from there (`ZoomGrabCatch`).
    func catchSettlingCard(panTranslation: CGPoint) {
        guard let flight else { return }
        let presented = flight.card.layer.presentation()
        catchSettlingCard(
            presentedCenter: presented?.position ?? flight.card.center,
            presentedSize: presented?.bounds.size ?? flight.card.bounds.size,
            panTranslation: panTranslation
        )
    }

    /// `catchSettlingCard(panTranslation:)` with the presented pose handed in
    /// — internal, so a test can say what the spring was presenting.
    func catchSettlingCard(presentedCenter: CGPoint, presentedSize: CGSize, panTranslation: CGPoint) {
        guard isCancelSettling, !isInteracting, let flight, context != nil,
              let view = pannedView else { return }
        isCancelSettling = false
        // The cancel's settle watch is stale from here: its card is in a hand.
        releaseGeneration += 1
        isInteracting = true
        destination?.setContentScrollEnabled(false)
        // Stop every animation the release spring started, at what it was
        // presenting: the card's subtree (its give keeps easing out), the
        // shadow, the dim's opacity and the presenter's depth. The values
        // themselves are re-set below, by the same pose the drag applies.
        Self.stopSpringAnimations(on: flight.card.layer)
        flight.shadow.layer.removeAllAnimations()
        Self.stopAnimations(on: dim?.layer, keyPath: "opacity")
        Self.stopAnimations(on: presentingView?.layer, keyPath: "transform")
        let span = activeAxis.span(of: view.bounds.size)
        grabCatch = ZoomGrabCatch(
            offset: CGPoint(x: presentedCenter.x - pageCenter.x, y: presentedCenter.y - pageCenter.y),
            scale: presentedSize.width / max(flight.pageFrame.width, 1),
            axis: activeAxis,
            span: span
        )
        catchPanTranslation = panTranslation
        let caughtShrink = min(max(grabCatch.ease(at: grabCatch.progress), 0), 1)
        catchPercentOffset = reportedPercent - caughtShrink
        deformation?.cancel()
        deformation = GrabDeformation(layer: flight.card.layer)
        // The pose the spring was presenting, now as the model — the
        // destination told it as a held state, which drops whatever its own
        // release animation had left in flight (`ZoomDismissState.isSettling`).
        applyDrag(grabCatch.translation, in: view)
        // Exact, not via the band's round trip.
        flight.card.center = presentedCenter
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print(String(format: "[grab] %.3f CAUGHT the cancel at scale=%.4f offset=(%.1f, %.1f) progress=%.3f",
                         CACurrentMediaTime(), presentedSize.width / max(flight.pageFrame.width, 1),
                         presentedCenter.x - pageCenter.x, presentedCenter.y - pageCenter.y,
                         grabCatch.progress))
        }
        // The cycle that was caught prints as one; the re-grab gets its own.
        GrabFramePacer.shared.stop(outcome: "caught")
        GrabFramePacer.shared.start()
        #endif
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

    func releaseGrab(translation: CGPoint, velocity: CGPoint, ended: Bool, in view: UIView) {
        #if DEBUG
        GrabFramePacer.shared.released()
        #endif
        guard isInteracting, let context, let flight else {
            // A grab that armed but never got a transition to drive (the pop
            // was refused, or another driver took it). Left armed, this driver
            // refused every later pan (`!isInteracting` in its begin gate),
            // the pager stayed frozen, and `ZoomTransitionController` handed
            // this dead driver the NEXT pop of the feed, a chevron included,
            // which then waited forever for pan events.
            if isInteracting, context == nil { abandonUnstagedGrab() }
            return
        }
        isInteracting = false
        // The settle is watchable, not touchable — the tap-back's shield, which
        // the release lacked. The feed is hidden by now (alpha 0, skipped by
        // hit-testing), so for the whole spring a touch reached the screen
        // underneath: a tile tap, or a scroll or pan that moved the very
        // landing rect this release just froze. Topmost in the container,
        // removed when the transition finishes.
        //
        // ⚠️ ONE SHIELD PER TRANSITION, carrying the RE-GRAB PAN (#2362). A
        // grab during a cancel's spring lands on the shield, not on the feed
        // it covers, so the shield hears it (`catchSettlingCard`); the pan's
        // begin gate opens only while a cancel is settling, so a commit's
        // spring stays untouchable. A re-grab that is released again reuses
        // the shield it is tracking on: removing the view under a live
        // recognizer would cancel the very gesture being released.
        if releaseShield == nil {
            let shield = UIView(frame: context.containerView.bounds)
            shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let regrab = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            regrab.maximumNumberOfTouches = 1
            regrab.delegate = self
            shield.addGestureRecognizer(regrab)
            regrabPan = regrab
            context.containerView.addSubview(shield)
            releaseShield = shield
        }
        // Let go with the finger: the give eases out under the release spring.
        deformation?.release()
        deformation = nil
        destination?.setContentScrollEnabled(true)

        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: activeAxis.along(dragTranslation(fromPan: translation)),
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
        //
        // ⚠️ A COMMIT IS REPORTED ONE TURN LATER (#1950, measured on the
        // owner's device): finishing in the release's own turn ran UIKit's
        // alongside blocks — the bars' glass coming back, ~25 ms — in the
        // release's frame, the 61–65 ms hitch of most grabs. A turn later
        // the release spring has its first frame. Still the same transition
        // (checked by identity), still long before the spring ends.
        //
        // ⚠️ A CANCEL IS REPORTED WHEN ITS SPRING HAS SETTLED (#2362), in the
        // settle watch below, right before the teardown. Until then the
        // transition stays interactive — UIKit holds its percent where the
        // drag left it, which with the eased shrink is little for a drag
        // released short — so a grab during the spring can carry the same
        // transition on (`catchSettlingCard`). Reported here, UIKit could not
        // be re-entered before the completion, and a quick grab again waited
        // for the card to get home and then started over from full screen.
        // (The freeze recorded above came from RAMPING the percent during the
        // spring; nothing is ramped here, and the teardown follows the card's
        // presentation, not a completion block.)
        releaseGeneration += 1
        let generation = releaseGeneration
        if commit {
            let releasing = context
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.context, current === releasing else { return }
                current.finishInteractiveTransition()
            }
        } else {
            isCancelSettling = true
        }

        // Read once more at release, through the same function the drag used, so
        // the spring starts from the card's current shape and ends on the rect
        // the drag was already aiming at — nothing to correct. It matters that
        // this is not the stage-time value: a grab can hold for seconds, and on
        // the map it is taken on a view freshly re-attached after the navigation
        // controller unloaded it, before its restored camera settled.
        let landing = commit ? currentLanding(in: context.containerView) : flight.sourceFrame
        // A landing nobody can see fades out — see `ZoomAnimator.dismiss`.
        let landsOffScreen = commit && source?.zoomSourceIsOnScreen == false
        releasedOffScreen = landsOffScreen

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
                if landsOffScreen {
                    flight.card.alpha = 0
                    flight.shadow.alpha = 0
                }
                dim?.alpha = 0
                presentingView?.transform = .identity
            } else {
                flight.poseAsPage(cornerRadius: screenRadius)
                dim?.alpha = 1
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
        whenViewSettles(
            flight.card,
            settlingAt: commit ? landing : flight.pageFrame,
            ceiling: viewSettleCeiling
        ) {
            // Strong, as the reveal grab's (`RevealDismissInteractionController`):
            // this is the only call that completes the transition and lifts
            // the release shield, and the watcher's ceiling bounds the hold.
            //
            // Unless a re-grab caught this release (#2362): the card is in a
            // hand again, and the release that will end it has a watch of its
            // own.
            guard self.releaseGeneration == generation, !self.isInteracting else { return }
            if !commit {
                self.isCancelSettling = false
                self.context?.cancelInteractiveTransition()
            }
            self.finishTransition(cancelled: !commit)
        }
    }

    #if DEBUG
    /// What a test reads of the live stage.
    var debugFlightCard: UIView? { flight?.card }
    var debugPageFrame: CGRect? { flight?.pageFrame }
    var debugReleaseShield: UIView? { releaseShield }
    #endif

    /// Tears the stage down exactly like the non-interactive animator's
    /// completion, then reports the outcome to UIKit and drops all state.
    /// (A commit was reported at release; a cancel, right before this call —
    /// see `releaseGrab`.)
    /// The release's touch shield — see `releaseGrab`.
    private var releaseShield: UIView?
    /// Whether the committed release faded the card toward an off-screen
    /// landing (no hold then).
    private var releasedOffScreen = false
    /// Held from staging to the end of the transition; a landing hold takes
    /// its own.
    private var orientationLease: FlightOrientationLock.Lease?

    private func finishTransition(cancelled: Bool) {
        releaseShield?.removeFromSuperview()
        releaseShield = nil
        regrabPan = nil
        defer {
            orientationLease?.release()
            orientationLease = nil
        }
        // Whatever happens below, the staged frame-0 hide is stale from here.
        hasAbandonedContentHide = true
        deformation?.cancel()
        deformation = nil
        // The settlement is decided by `ZoomGrabSettlement.plan` — pure, so
        // the branch that only a cancelled grab with a donated surface reaches
        // is pinned by a unit test rather than by a device session.
        //
        // Commit: hand the card's live surface to the source, then hold the
        // card over the landing until that surface is actually drawing. This
        // path is the one a real finger takes, and it used to remove the card
        // on its first line — so whenever the landing tile was not already
        // rendering, the card vanished and the tile's COVER IMAGE was what
        // appeared.
        //
        // Cancel: give a donated surface BACK first (`zoomReclaimLiveMediaView`
        // — the same hand-back `ZoomAnimator`'s cancel branch performs; under
        // the `AVPlayerLayer` backing the donation physically removed the
        // page's render view from its cell, so a cancelled grab that only
        // dropped the card restored a page with a dead media area), then the
        // card goes outright — no landing to wait for.
        let card = flight?.card
        for action in ZoomGrabSettlement.plan(
            cancelled: cancelled,
            cardHasLiveSurface: card?.zoomLiveMediaSurface != nil
        ) {
            switch action {
            case .reclaimSurfaceToDestination:
                if let surface = card?.zoomLiveMediaSurface {
                    destination?.zoomReclaimLiveMediaView(surface)
                }
            case .adoptSurfaceToSource:
                if let surface = card?.zoomLiveMediaSurface {
                    source?.zoomAdoptLiveMediaView(surface)
                }
            case .holdCardOverLanding:
                guard let card else { break }
                // Nothing to hold over: the card faded out on its way to a
                // landing off screen.
                if releasedOffScreen {
                    card.removeFromSuperview()
                    break
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
            case .removeCardNow:
                card?.removeFromSuperview()
            case .restoreDestinationContent:
                // The page is staying: bring it back BEFORE anything is taken
                // from the card. It sits above the card, so this covers the
                // card in the same commit — see `ZoomGrabSettlement.Action`.
                destination?.setZoomDismissState(ZoomDismissState(
                    progress: 0, card: .zero, cornerRadius: 0, isSettling: false
                ))
                destination?.setZoomContentHidden(false)
            case .revealSource, .concealSource:
                source?.setZoomSourceHidden(action == .concealSource)
            }
        }
        flight?.shadow.removeFromSuperview()
        dim?.removeFromSuperview()
        presentingView?.transform = .identity
        ZoomFlight.clearRecededChrome(from: presentingView) // reset is covered either way
        // Idempotent on the cancel path — `.restoreDestinationContent` already
        // ran these, first, for the reason that action documents — and the
        // only place they run when the dismissal finished.
        destination?.setZoomDismissState(ZoomDismissState(
            progress: 0, card: .zero, cornerRadius: 0, isSettling: false
        ))
        destination?.setZoomContentHidden(false)
        // A committed grab pops the destination: it departs, and must not
        // reclaim the player the landing tile adopts.
        if cancelled {
            source?.zoomSourceDidAbandonDismissal()
            #if DEBUG
            // The stack through `.to`: a pop has already taken `.from` out of it.
            ArrivalInvariants.schedule(
                on: context?.viewController(forKey: .to)?.navigationController,
                path: "grabCancelled"
            )
            #endif
        } else {
            destination?.zoomTransitionWillDepart()
            #if DEBUG
            ArrivalInvariants.schedule(
                on: context?.viewController(forKey: .to)?.navigationController,
                path: "grabReturned"
            )
            #endif
        }
        destination?.zoomTransitionDidEnd()
        // ⚠️ THE SOURCE IS NOT TOUCHED HERE ANY MORE. It was un-hidden
        // unconditionally, cancel included, on the reasoning that a source left
        // concealed could be stranded — but a cancelled grab is a page that is
        // STAYING, so revealing the twin put the tapped marker back on a map
        // the viewer can see behind the very next grab. The verdict is now part
        // of the settlement plan (`.revealSource` / `.concealSource`), and the
        // stranding it guarded against cannot happen: every source surface
        // restores blanket-fashion when it becomes the screen again.
        #if DEBUG
        ZoomGeometrySampler.shared.stop()
        GrabFramePacer.shared.stop(outcome: cancelled ? "cancel" : "commit")
        #endif
        // A cancelled grab has to hand back the hidden state the owner undid
        // when the grab began; a completed one is reported through `didShow`.
        if cancelled {
            onCancelled?()
        }
        context?.completeTransition(!cancelled)
        context = nil
        flight = nil
        dim = nil
        isCancelSettling = false
        grabCatch = .none
        catchPanTranslation = .zero
        catchPercentOffset = 0
        reportedPercent = 0
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
        // ⚠️ THE SAME TWO AUTHORITIES A FINGER PASSES, or this script reports on
        // a transition the app would never have run.
        //
        // `gestureRecognizerShouldBegin` cannot be called here — it needs a real
        // recognizer with a velocity — so the two gates that decide whether this
        // driver claims a drag AT ALL are restated. Everything else in that
        // method is about touches and timing; these two are about the post.
        //
        // Without them the harness drove a hero over a landing the hero refuses,
        // filmed it, and called the result the product's behaviour. The card
        // close is what a finger gets there, and it was never once measured.
        guard DismissalArbiter.heroCarries(
            kind: destination?.zoomDismissalKind,
            landingAcceptsHero: source?.zoomLandingAcceptsHero
        ) else {
            print("[zoom-live] scripted grab DECLINED"
                + " kind=\(String(describing: destination?.zoomDismissalKind))"
                + " landingAcceptsHero=\(String(describing: source?.zoomLandingAcceptsHero))")
            return
        }
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
    /// outbound movement predominantly along one ARMED axis (rightward, or
    /// downward where the destination permits it — the feed's first post,
    /// #2056), so the paging the feed owns never sees a competitor — and when
    /// it does begin, the intent is unambiguous enough to claim on the spot.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // ⚠️ THE RE-GRAB (#2362) has a gate of its own: it is not a new
        // dismissal but the same one carried on, so the questions below —
        // which post, which landing, which axis, which tenant — were all
        // answered by the grab whose cancel it catches. It begins in ANY
        // direction (the card is already off the page; a hand pulling it back
        // toward the screen is holding it too), and only while a cancel is
        // still settling: a commit's spring stays untouchable.
        if gestureRecognizer === regrabPan {
            let open = isCancelSettling && !isInteracting && context != nil && flight != nil
            return grabLog("RE-GRAB during the cancel", open)
        }
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
        guard destination?.zoomDismissalKind == .hero
        else { return grabLog("post wants a card, not a hero", false) }
        // ⚠️ AND ONLY WHERE THERE IS SOMETHING TO FLY IT ONTO — see
        // `ZoomTransitionSource.zoomLandingAcceptsHero`.
        //
        // The gate above asks the DEPARTURE's half of the question. A close
        // that lands on the post it left from needs no second half, and one
        // that does not — a list keeps its order under a pager — can be
        // carrying a photograph home to a row made of words. Refusing leaves
        // the drag to the card close, exactly as the kind gate does.
        // Both halves together are `DismissalArbiter.heroCarries` — the one
        // rule the card close asks from the other side.
        guard DismissalArbiter.heroCarries(
            kind: destination?.zoomDismissalKind,
            landingAcceptsHero: source?.zoomLandingAcceptsHero
        ) else { return grabLog("landing cannot receive a hero", false) }
        // `context == nil` only covers OUR transitions. A pop of a screen
        // pushed above the feed (profile, comments) can still be settling —
        // the feed is already `topViewController` then, and beginning a grab
        // would start a second pop mid-transition. Refuse; the next grab retries.
        guard (destination as? UIViewController)?.transitionCoordinator == nil
        else { return grabLog("transition settling", false) }
        // `withUpward`: the swipe up past the list's last post (#628, #761)
        // rides with the vertical axis unless a sibling takes it
        // (`armsUpward`); the destination's gate below keeps it closed.
        guard let axis = ZoomDismissAxis.match(
            velocity: pan.velocity(in: view), axes: debugEffectiveAxes
        ) else { return grabLog("no axis v=\(pan.velocity(in: view))", false) }
        // And the destination's TENANTS: subsurfaces that own drags along this
        // axis — a scrolling rail or an open comments panel vertically, a
        // carousel with a photograph to its left horizontally (a rightward drag
        // there means "previous photo", not "dismiss"). The destination is the
        // only thing that knows which page it is on.
        //
        // ⚠️ Asked through the ONE predicate every dismissal driver shares
        // (`permitsDismissalGrab`), which also owns the origin-not-finger rule.
        // The card close's copy of this question was opt-in, and a window
        // opened from a text row stole a carousel's drag on every screen that
        // had not opted in.
        let origin = pan.dragOrigin(in: view)
        if destination?.permitsDismissalGrab(pan, along: axis, in: view) == false {
            return grabLog("\(axis) refused by a tenant at x=\(origin.x)", false)
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

/// The grab's pan, marked so a reused view can tell its dead ones from the
/// pans other code put there. A recognizer does not retain its target, so
/// `driver` going nil is exactly "nothing will ever handle this pan again".
final class ZoomDismissPan: UIPanGestureRecognizer, CustomBackPopper {
    weak var driver: ZoomDismissInteractionController?
}
