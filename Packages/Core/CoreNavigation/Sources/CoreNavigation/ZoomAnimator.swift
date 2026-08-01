
import UIKit

/// Drives the *non-interactive* legs of the hero/zoom transition with a
/// single flying card (`ZoomFlight`): a `PinCardView` — the very component
/// the map pin renders — carrying the media plus a live replica of the
/// destination's UI chrome. The card's **frame** animates between the pin's
/// rect and full screen, so both endpoints are exact by construction: at the
/// pin end the card *is* a pin (56pt square, 12pt round corners, 2pt ring,
/// square aspect-fill crop, drop shadow), at the screen end it *is* the page
/// (full-bleed, display-corner radius). Between them the crop morphs — no
/// anisotropic squash, no elliptical corners.
///
/// A live-previewing pin flies *live*: its pooled player is mirrored onto the
/// card's own render surface (two `AVPlayerLayer`s, one player, one clock),
/// so tapping an animating pin never freezes it. The video layer is laid out
/// once at destination size and driven by a uniform-scale transform, because
/// an `AVPlayerLayer` does not track a bounds animation smoothly.
///
/// The destination's *content* hides during the flight and is revealed only
/// at landing, when the card covers the screen exactly (same chrome scaffold,
/// same layout), so the swap is invisible — while the presented container
/// stays visible and clear so the real navigation bar keeps its native
/// screen-space layout above the flight from frame 0 (bar chrome is rigid; it
/// never scales, morphs, or pops). Nothing mutates the live feed mid-flight.
///
/// A grabbed dismissal is driven by `ZoomDismissInteractionController`
/// instead, which stages the same `ZoomFlight` and lands on the same poses.
@MainActor
final class ZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    /// Whether this instance is the dismiss leg — the interruptible one.
    var isDismissing: Bool { !isPresenting }
    private let source: any ZoomTransitionSource
    private weak var destination: (any ZoomTransitionDestination)?
    /// The flight's spring is defined once on `ZoomFlight` and shared with the
    /// interactive grab, so present, tap-back, and released-swipe dismissals all
    /// settle with identical physics.
    private let duration = ZoomFlight.springDuration

    /// Source chrome that fades in over the dismiss spring; see
    /// `ZoomTransitionController.returningSourceChrome`.
    private weak var returningChrome: UIView?

    /// The dismissal's animator, kept so it can be paused and scrubbed.
    ///
    /// Cached against the CONTEXT that built it, and never cleared while that
    /// context is alive. UIKit may ask for the interruptible animator more than
    /// once, and each unmatched ask used to run the whole dismissal setup
    /// again: a second flight card, posed full screen with its chrome replica,
    /// inserted into the container, and never animated because nothing started
    /// its animator. That is a page-sized replica of the feed left sitting over
    /// the grid — the artifact that made the first attempt at this look like a
    /// teardown bug.
    private var interruptible: UIViewPropertyAnimator?
    private weak var interruptibleContext: AnyObject?

    init(
        isPresenting: Bool,
        source: any ZoomTransitionSource,
        destination: any ZoomTransitionDestination,
        returningChrome: UIView? = nil
    ) {
        self.isPresenting = isPresenting
        self.source = source
        self.destination = destination
        self.returningChrome = returningChrome
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        duration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: context).startAnimation()
    }

    /// Both legs now answer `interruptibleAnimator(using:)`, so the selector is
    /// no longer hidden from UIKit.
    ///
    /// It used to be, and the reason is worth keeping: the method is OPTIONAL
    /// and one class serves both legs, so while only the dismissal was built
    /// here an unconditional implementation answered the PUSH too and ran the
    /// whole DISMISS setup against a present context — a page-posed card with
    /// the feed's chrome replica, inserted and never animated. Now that the
    /// build below branches on the leg, answering for both is correct; the
    /// branch is what makes it correct, not the selector.

    /// The dismissal runs on a property animator so it can be interrupted.
    ///
    /// Only the dismiss leg. Interrupting a present means defining what a
    /// reversed push does to the pool loan and to a hoisted surface, which is
    /// its own change.
    func interruptibleAnimator(
        using context: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] interruptibleAnimator asked presenting=\(isPresenting) cached=\(interruptible != nil) sameCtx=\(interruptibleContext === (context as AnyObject))")
        }
        #endif
        if let interruptible, interruptibleContext === (context as AnyObject) {
            return interruptible
        }
        let animator = isPresenting ? present(context) : dismiss(context)
        interruptible = animator
        interruptibleContext = context as AnyObject
        return animator
    }

    // MARK: - Present

    private func present(_ context: any UIViewControllerContextTransitioning) -> UIViewPropertyAnimator {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] BUILD present flight (presenting=\(isPresenting))")
        }
        #endif
        let container = context.containerView
        guard let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return UIViewPropertyAnimator(duration: duration, curve: .linear)
        }
        // Dims the map around the flying card; tail-weighted so the map reads
        // through for most of the flight and recedes to black as the card lands.
        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        container.addSubview(dim)

        if let toVC = context.viewController(forKey: .to) {
            toView.frame = context.finalFrame(for: toVC)
        } else {
            toView.frame = container.bounds
        }
        container.addSubview(toView)
        // Lay the feed out now: it kicks content hydration and settles the safe
        // areas the card's chrome replica bakes in below.
        container.layoutIfNeeded()

        let sourceFrame = source.zoomHeroFrame(in: container)
        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds

        // The feed hides for the flight — the card is its stand-in. The
        // navigation bar needs no such care under a push: it belongs to the
        // navigation controller, above this container, and UIKit cross-fades
        // its items ("Maps" → back + author capsule) natively alongside this
        // animator. The card flies beneath it.
        destination?.setZoomContentHidden(true)

        let flight = ZoomFlight.build(
            source: source, destination: destination, sourceFrame: sourceFrame, pageFrame: pageFrame
        )
        container.insertSubview(flight.card, belowSubview: toView)
        container.insertSubview(flight.shadow, belowSubview: flight.card)
        // Resolve the chrome replica's full-screen layout (safe areas, text
        // wrapping) while the card still spans the page; its bounds never
        // change again, so nothing can relayout mid-flight.
        container.layoutIfNeeded()

        // Pose the card as the pin, COMMIT it, and only then hide the real one.
        //
        // These used to sit in one transaction, on the reasoning that a single
        // commit cannot render a mismatch. That is true of the model and says
        // nothing about content: a media layer with no frame enqueued yet
        // composites EMPTY on that commit, while the pin it stands in for is
        // already hidden. One frame of nothing, on both legs, and only when the
        // card loses the race — which is why it reads as a random flash rather
        // than a reproducible one.
        //
        // `flush` commits the card to the render server here; the hide lands in
        // the next transaction, so the two overlap by a frame instead of
        // leaving a gap. Overlap is free: the card is a pixel-identical twin
        // posed exactly over the source, so a frame showing both is
        // indistinguishable from a frame showing either.
        flight.poseAtSource()
        CATransaction.flush()
        #if DEBUG
        Self.logFirstFrameHandoff("present", card: flight.card)
        #endif
        source.setZoomSourceHidden(true)

        let screenRadius = ZoomFlight.screenCornerRadius(behind: container)

        // Depth cue: the presenting map recedes to 0.95, so the feed reads as
        // lifting off a 3D canvas. (`view(forKey:)` is nil under an
        // over-full-screen present, so reach the root via the view controller.)
        // The depth cue rides the source-nominated view when there is one, so a
        // screen's own chrome stays grounded while its content recedes.
        let presentingView = source.zoomPresenterDepthView ?? context.viewController(forKey: .from)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)

        #if DEBUG
        Self.debugTrackFlightGeometry(card: flight.card)
        #endif
        // One property animator, so the push can be caught mid-air and scrubbed.
        // Card and the map's depth ride ONE spring, so the lift-off and the
        // canvas receding stay locked together and land as a single settle.
        // The card lands flush with the device's own display corners, so the
        // reveal of the (screen-clipped) feed underneath is seamless.
        let spring = UISpringTimingParameters(
            dampingRatio: ZoomFlight.springDamping,
            initialVelocity: CGVector(dx: 0, dy: ZoomFlight.springVelocity)
        )
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
        animator.addAnimations {
            flight.poseAsPage(cornerRadius: screenRadius)
            presentingView?.transform = CGAffineTransform(
                scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
            )
        }
        // The dim was a second, plainly-curved animation ("opacity should never
        // bounce"). A property animator carries one curve, and a separate
        // UIView animation would neither scrub nor reverse with the rest, so it
        // rides this one delayed instead — which keeps what the curve was FOR:
        // the map reads through for most of the flight and goes to black as the
        // card lands.
        animator.addAnimations({ dim.alpha = 1 }, delayFactor: 0.35)
        animator.addCompletion { _ in
            if context.transitionWasCancelled {
                // REVERSED push: the grid is staying. The card has already been
                // animated back onto the tile, so this only has to put the tile
                // back and drop everything the flight added.
                //
                // Nothing to hand back: under N-surface the card joined the
                // TILE's playback as an extra surface and the tile never stopped
                // rendering, so the surface is simply dropped. The destination
                // is not revealed — UIKit removes it on `completeTransition`.
                flight.card.removeFromSuperview()
                flight.shadow.removeFromSuperview()
                dim.removeFromSuperview()
                presentingView?.transform = .identity
                ZoomFlight.clearRecededChrome(from: presentingView)
                self.destination?.zoomTransitionDidEnd()
                self.source.setZoomSourceHidden(false)
                context.completeTransition(false)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print("[zoom-live] present REVERSED, source restored")
                }
                #endif
                return
            }
            // Reveal the page FIRST, then move the surface into it — order that
            // matters for a measured reason. An `AVPlayerLayer` only renders
            // inside a visible hierarchy, so installing it into still-hidden
            // content stops it and drops `isReadyForDisplay` for ~165ms, which
            // was the flash at the END of the flight. The card is still on top
            // and still rendering through both steps, so nothing shows in
            // between.
            // Wait for the destination to HAVE content before revealing it.
            //
            // Holding the card cannot help here: it is inserted BELOW the
            // destination view, so the moment `setZoomContentHidden(false)`
            // runs the destination covers it regardless. What has to wait is
            // the reveal itself. A screen pushed cold has nothing to lay out —
            // measured at 1000ms injected latency as 2.18s of empty feed
            // against a 0.42s flight — and revealing it on schedule is what put
            // the cell's black floor on screen.
            //
            // Everything below stays in one block so the ordering note above
            // still holds: reveal, THEN adopt the surface, then drop the card.
            Self.whenReady(ceiling: Self.maximumHydrationHold,
                           condition: { [weak destination = self.destination] in
                               destination?.zoomDestinationContentIsReady ?? true
                           }) {
                self.destination?.setZoomContentHidden(false)
                if let surface = flight.card.zoomLiveMediaSurface {
                    self.destination?.zoomAdoptLiveMediaView(surface)
                }
                flight.card.removeFromSuperview()
                flight.shadow.removeFromSuperview()
                dim.removeFromSuperview()
                presentingView?.transform = .identity
                ZoomFlight.clearRecededChrome(from: presentingView)
                self.destination?.zoomTransitionDidEnd()
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
        return animator
    }

    /// Runs `work` as soon as `condition` is true, or at `ceiling`, whichever
    /// comes first. Polled on the display link, like the landing hold.
    ///
    /// Fires SYNCHRONOUSLY when the condition already holds, so the common case
    /// — a destination whose data was ready before the flight ended — keeps the
    /// exact ordering and timing it had before this existed.
    static func whenReady(ceiling: CFTimeInterval,
                          condition: @escaping () -> Bool,
                          then work: @escaping () -> Void) {
        if condition() {
            work()
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f destination NOT ready — holding reveal",
                         CACurrentMediaTime()))
        }
        #endif
        let deadline = CACurrentMediaTime() + ceiling
        let link = CADisplayLink(target: ReadyGate(condition: condition, deadline: deadline, work: work),
                                 selector: #selector(ReadyGate.tick))
        link.add(to: .main, forMode: .common)
    }

    private final class ReadyGate {
        private let condition: () -> Bool
        private let deadline: CFTimeInterval
        private let work: () -> Void
        private var fired = false

        init(condition: @escaping () -> Bool, deadline: CFTimeInterval, work: @escaping () -> Void) {
            self.condition = condition
            self.deadline = deadline
            self.work = work
        }

        @objc func tick(_ link: CADisplayLink) {
            guard !fired else { return }
            let timedOut = CACurrentMediaTime() >= deadline
            guard condition() || timedOut else { return }
            fired = true
            link.invalidate()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print(String(format: "[zoom-live] %.3f reveal released%@",
                             CACurrentMediaTime(), timedOut ? " (TIMEOUT)" : ""))
            }
            #endif
            work()
        }
    }

    #if DEBUG
    /// Samples the card's and its live surface's PRESENTATION bounds every
    /// frame of a flight.
    ///
    /// The reported artifact is the surface sitting at full-screen size while
    /// the card's clip expands around it, which looks like an unveil rather
    /// than a zoom. Model bounds cannot show that — they hold the final value
    /// from the moment the animation is scheduled — so this reads the
    /// presentation layer, which is what is actually on screen.
    static func debugTrackFlightGeometry(card: any ZoomFlightCard) {
        guard ProcessInfo.processInfo.arguments.contains("-zoom-live-log") else { return }
        let surface = card.zoomLiveMediaSurface
        let probe = GeometryProbe(card: card, surface: surface,
                                  deadline: CACurrentMediaTime() + ZoomFlight.springDuration)
        let link = CADisplayLink(target: probe, selector: #selector(GeometryProbe.tick))
        link.add(to: .main, forMode: .common)
    }

    private final class GeometryProbe {
        private let card: UIView
        private let surface: UIView?
        private let deadline: CFTimeInterval
        private var frames = 0
        private var grace = 0

        init(card: UIView, surface: UIView?, deadline: CFTimeInterval) {
            self.card = card
            self.surface = surface
            self.deadline = deadline
        }

        @objc func tick(_ link: CADisplayLink) {
            frames += 1
            guard CACurrentMediaTime() < deadline else { link.invalidate(); return }
            guard frames % 6 == 1 else { return }
            let cardSize = card.layer.presentation()?.bounds.size ?? card.bounds.size
            let surfaceSize = surface?.layer.presentation()?.bounds.size ?? surface?.bounds.size
            print(String(format: "[zoom-live] flight f%02d card=%.0fx%.0f surface=%@",
                         frames, cardSize.width, cardSize.height,
                         surfaceSize.map { String(format: "%.0fx%.0f", $0.width, $0.height) } ?? "none"))
        }
    }
    #endif

    /// Keeps `card` on screen while `condition` holds, up to a hard ceiling.
    ///
    /// Polled on the display link rather than after a fixed delay: the wait is
    /// however long the layer actually needs, usually a frame or two, and the
    /// ceiling only exists so a surface that never reports ready cannot strand
    /// the card over the screen.
    static func holdCard(_ card: UIView,
                         ceiling: CFTimeInterval = maximumLandingHold,
                         liveMediaIsDrawing: @escaping () -> Bool = { true },
                         liveMediaState: @escaping () -> String = { "" },
                         finalizeLanding: @escaping () -> Void = {},
                         path: String = "?",
                         while condition: @escaping () -> Bool) {
        // No early-out on `condition()`. The dip is delivered by KVO a few
        // milliseconds after the surface is installed, so a single check taken
        // at landing still reads ready and the card would leave just in time to
        // expose it. The hold therefore always runs, spans a minimum number of
        // frames, and only then starts asking.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            // Which dismissal is being held. The two paths are separate
            // implementations, and a measurement of one says nothing about the
            // other — worth naming rather than inferring from a harness flag.
            print(String(format: "[zoom-live] %.3f landing hold BEGIN [%@]",
                         CACurrentMediaTime(), path))
        }
        #endif
        let deadline = CACurrentMediaTime() + ceiling
        let link = CADisplayLink(target: LandingHold(card: card, condition: condition,
                                                     liveMediaIsDrawing: liveMediaIsDrawing,
                                                     liveMediaState: liveMediaState,
                                                     finalizeLanding: finalizeLanding,
                                                     deadline: deadline),
                                 selector: #selector(LandingHold.tick))
        link.add(to: .main, forMode: .common)
    }

    /// Ceiling on the landing hold. Sized against the measured worst case
    /// (~600ms was the re-parent dip) with room to spare, while staying short
    /// enough that a stuck surface is a brief pause rather than a frozen card.
    private static let maximumLandingHold: CFTimeInterval = 0.75

    /// Ceiling on the hold that waits for a destination's CONTENT rather than
    /// its decoded frames. Longer than the landing hold because it waits on a
    /// network round trip, not a decode — and short enough that a screen whose
    /// data never arrives becomes a normal empty state rather than a card
    /// frozen over it indefinitely.
    private static let maximumHydrationHold: CFTimeInterval = 3.0


    private final class LandingHold {
        private let card: UIView
        private let condition: () -> Bool
        private let liveMediaIsDrawing: () -> Bool
        private let liveMediaState: () -> String
        private let finalizeLanding: () -> Void
        private let deadline: CFTimeInterval

        init(card: UIView, condition: @escaping () -> Bool,
             liveMediaIsDrawing: @escaping () -> Bool,
             liveMediaState: @escaping () -> String,
             finalizeLanding: @escaping () -> Void, deadline: CFTimeInterval) {
            self.card = card
            self.condition = condition
            self.liveMediaIsDrawing = liveMediaIsDrawing
            self.liveMediaState = liveMediaState
            self.finalizeLanding = finalizeLanding
            self.deadline = deadline
        }

        /// Frames held before a "ready" answer is trusted. The dip arrives via
        /// KVO roughly 8ms after the surface is installed, so a few frames at
        /// 60Hz cover its delivery either way. Lives here, not on the animator,
        /// because the display-link callback is nonisolated.
        private static let minimumHoldFrames = 4
        private var frames = 0
        private var grace = 0

        @objc func tick(_ link: CADisplayLink) {
            frames += 1
            #if DEBUG
            // Is the card we are "holding" actually on screen? The hold is
            // scheduled and then `completeTransition` runs, and UIKit tears
            // down the transition container — which is the card's superview.
            // A hold over a card UIKit has already removed protects nothing,
            // and its duration would look perfectly healthy in a log.
            if frames == 1 || frames == 3,
               ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                // `drawing=NO` is the answer that explains a pop while every
                // other signal reads healthy: the card is present and opaque,
                // but its cover is what is on screen.
                print(String(format: "[zoom-live] %.3f hold f%d card window=%@ alpha=%.2f drawing=%@",
                             CACurrentMediaTime(), frames,
                             card.window == nil ? "NIL" : "yes",
                             card.alpha, liveMediaIsDrawing() ? "yes" : "NO")
                      + "  surface[" + liveMediaState() + "]")
            }
            #endif
            // Span the window in which the dip can still arrive before
            // believing a "ready" answer.
            let settling = frames < Self.minimumHoldFrames
            // One extra frame after the landing first reports ready.
            //
            // "Ready" is sampled at the top of a frame; the tile has not
            // COMPOSITED that frame yet when we answer. Removing the card in
            // the same tick therefore uncovers a tile whose first frame is
            // still one pass away — a flash at the very end of the landing,
            // which is where it was reported. Holding one more tick costs
            // 16ms of a card that is already showing the same pixels.
            if !settling, !condition(), grace < 1 {
                // Make the landing finish its layout, THEN spend the grace
                // frame — so the extra tick is the cell composing, not just
                // time passing.
                finalizeLanding()
                grace += 1
                return
            }
            guard settling || condition(), CACurrentMediaTime() < deadline else {
                link.invalidate()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    let timedOut = CACurrentMediaTime() >= deadline
                    print(String(format: "[zoom-live] %.3f landing hold END%@",
                                 CACurrentMediaTime(), timedOut ? " (TIMEOUT)" : ""))
                }
                #endif
                card.removeFromSuperview()
                return
            }
        }
    }

    // MARK: - Dismiss

    #if DEBUG
    /// Reports whether the flight card had content at the instant the view it
    /// replaces was hidden. `drawing=false` here IS the flash — the frame where
    /// the source is gone and the card has nothing to show yet. Under
    /// `-zoom-live-log`, and on both legs, because the race is symmetric.
    private static func logFirstFrameHandoff(_ leg: String, card: any ZoomFlightCard) {
        guard ProcessInfo.processInfo.arguments.contains("-zoom-live-log") else { return }
        print(String(format: "[zoom-live] %.3f %@ hide-source drawing=%@ %@",
                     CACurrentMediaTime(), leg,
                     card.zoomLiveMediaIsDrawing ? "yes" : "NO",
                     card.zoomLiveMediaDebugState))
    }
    #endif

    #if DEBUG
    /// Teardown state, so a dismissal that "completes" cleanly in the logs but
    /// leaves something on screen is visible as data rather than only in a
    /// screenshot. `card=parented` after `done`, or a from-view still in a
    /// window, is the whole class of bug this exists to catch.
    private static func logTeardown(
        _ stage: String, context: any UIViewControllerContextTransitioning,
        card: any ZoomFlightCard, fromView: UIView
    ) {
        guard ProcessInfo.processInfo.arguments.contains("-zoom-live-log") else { return }
        print(String(format: "[zoom-live] teardown %@ cancelled=%@ card=%@ cardFrame=%@ fromView=%@",
                     stage,
                     context.transitionWasCancelled ? "yes" : "no",
                     card.superview == nil ? "detached" : "PARENTED",
                     NSCoder.string(for: card.frame),
                     fromView.superview == nil ? "detached" : "PARENTED"))
    }
    #endif

    private func dismiss(_ context: any UIViewControllerContextTransitioning) -> UIViewPropertyAnimator {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] BUILD dismiss flight (presenting=\(isPresenting))")
        }
        #endif
        let container = context.containerView
        guard let fromView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return UIViewPropertyAnimator(duration: duration, curve: .linear)
        }
        // Reinstall the presenter (`.to`) behind the departing card — a
        // navigation controller removes non-top views, so it isn't in the
        // hierarchy yet.
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
        // Read the page rect AFTER that layout, not before it.
        //
        // `ZoomFlight.build` assigns this straight to `card.frame`, and the
        // card is what the live surface is sized against — so an empty rect
        // here produces a zero-sized card flying a zero-sized surface, which is
        // a view at the origin with no size. Measured on the tap-back path:
        // `cardBounds={{0,0},{0,0}}` at adopt, against `{{0,0},{402,874}}` on
        // the grab, which stages its own layout before building.
        //
        // The empty check is belt and braces: whatever leaves the rect empty,
        // the container's own bounds are a truthful full-screen fallback and
        // strictly better than zero.
        let measuredPage = destination?.zoomTargetFrame(in: container) ?? .zero
        let pageFrame = measuredPage.isEmpty ? container.bounds : measuredPage
        source.zoomSourceWillStageDismissal()
        let sourceFrame = source.zoomHeroFrame(in: container)

        // Dim starts opaque (fully presented) and lifts to reveal the map as
        // the card shrinks.
        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let flight = ZoomFlight.build(
            source: source, destination: destination, sourceFrame: sourceFrame, pageFrame: pageFrame
        )
        // The card now renders the destination's player. Hand that player over
        // to whoever plays the same asset next — the source it is flying home
        // to — so the landing adopts a running item instead of starting a fresh
        // one at zero. Strictly after `build`, or the card would have nothing
        // left to mirror.
        // Hoist the live surface above the navigation controller for the whole
        // return, so the video never leaves the render tree and the flight is
        // pure geometry. The card keeps flying its chrome; the two ride the
        // same spring and stay aligned because they are posed from the same
        // rects.
        var hoisted = false
        if let surface = flight.card.zoomLiveMediaSurface {
            hoisted = source.zoomHoistLiveMedia(
                surface, at: pageFrame, in: container,
                cornerRadius: ZoomFlight.screenCornerRadius(behind: container)
            )
        }
        if flight.card.zoomLiveMediaSurface != nil || hoisted {
            destination?.zoomParkLiveMediaForHandoff()
            // NOT warmed here, deliberately. Warming the landing tile mid-flight
            // works on its own terms — the tile's layer reaches ready — but it
            // becomes the most recently attached layer for that player and
            // blanks the CARD while it is still flying:
            //
            //   437.091 tile readyForDisplay=true    <- tile warmed
            //   437.111 tile readyForDisplay=false
            //   437.111 feed readyForDisplay=false   <- card blanked, mid-flight
            //
            // That trades a landing flash for a worse one during the flight.
            // The present leg does not hit this because the destination warms a
            // layer the card is not competing with. `zoomWarmLiveMediaForLanding`
            // stays available for a dismissal fix that attaches inside the
            // landing transaction instead of ahead of it.
        }
        container.insertSubview(flight.card, belowSubview: fromView)
        container.insertSubview(flight.shadow, belowSubview: flight.card)
        container.layoutIfNeeded()
        // Starts flush with the device's own display corners (visually identical
        // to the screen-clipped feed it replaces); rounds back to the pin.
        let screenRadius = ZoomFlight.screenCornerRadius(behind: container)
        flight.poseAsPage(cornerRadius: screenRadius)
        // The card (same chrome scaffold, same layout) replaces the feed —
        // pixel-invisible swap. The navigation bar is the stack's own, above
        // this container; UIKit runs its item back-transition natively over
        // the shrinking card.
        //
        // Same first-frame rule as the present leg: commit the card, THEN hide
        // what it replaces, so the two overlap by a frame instead of leaving a
        // gap where neither has content.
        //
        // Deferring this by a runloop TURN was tried earlier and changed
        // nothing, which is consistent rather than contradictory — the problem
        // was never when the hide is scheduled, it is whether the card has been
        // committed by the time it happens. A turn's delay does not commit
        // anything; `flush` does.
        CATransaction.flush()
        #if DEBUG
        Self.logFirstFrameHandoff("dismiss", card: flight.card)
        #endif
        destination?.setZoomContentHidden(true)

        // Reverse depth cue: the map starts receded (0.95, covered) and scales
        // back to full as the card shrinks.
        let presentingView = source.zoomPresenterDepthView ?? context.viewController(forKey: .to)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)
        presentingView?.transform = CGAffineTransform(
            scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
        )

        // The clip-morph home on one spring — card shrinks + rounds + regrows
        // its ring and shadow, chrome fades, dim lifts, and the map returns, all
        // settling onto the pin together. The same spring as the grab dismissal,
        // so a tap-back and a released grab land with the same physics; a hair
        // of overshoot reads as the card snapping into its pin socket.
        // A property animator rather than `UIView.animate`, so the flight can be
        // paused and scrubbed mid-air. Same spring — the damping ratio and the
        // initial velocity are the shared constants — so an uninterrupted
        // dismissal is physically what it was.
        let spring = UISpringTimingParameters(
            dampingRatio: ZoomFlight.springDamping,
            initialVelocity: CGVector(dx: 0, dy: ZoomFlight.springVelocity)
        )
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
        animator.addAnimations {
            flight.poseAtSource()
            if hoisted {
                self.source.zoomPoseHoistedMedia(
                    at: sourceFrame, in: container,
                    cornerRadius: flight.card.zoomRestingCornerRadius
                )
            }
            dim.alpha = 0
            // Arrives on the flight's own spring rather than after it, so a
            // tap-back and a released grab reveal the bar the same way.
            self.returningChrome?.alpha = 1
            presentingView?.transform = .identity
        }
        animator.addCompletion { _ in
            let cancelled = context.transitionWasCancelled
            #if DEBUG
            Self.logTeardown("enter", context: context, card: flight.card, fromView: fromView)
            #endif
            if cancelled {
                // REVERSED mid-flight: the feed is staying, so everything the
                // flight took has to go back before it is handed control again.
                //
                // The hoisted surface is the piece that cannot be reached the
                // usual way — `zoomLiveMediaSurface` is nil once it has been
                // hoisted — so without an explicit release it would stay
                // parented above the navigation controller, drawing at the grid
                // cell's rect over the feed.
                if hoisted {
                    if let surface = self.source.zoomReleaseHoistedMedia() {
                        self.destination?.zoomReclaimLiveMediaView(surface)
                    }
                } else if let surface = flight.card.zoomLiveMediaSurface {
                    self.destination?.zoomReclaimLiveMediaView(surface)
                }
                // No landing hold: nothing is landing. The card goes outright.
                flight.card.removeFromSuperview()
                flight.shadow.removeFromSuperview()
                dim.removeFromSuperview()
                presentingView?.transform = .identity
                ZoomFlight.clearRecededChrome(from: presentingView)
                self.destination?.setZoomContentHidden(false)
                self.destination?.zoomTransitionDidEnd()
                // Undoes `zoomSourceWillStageDismissal`, which hid the tile and
                // froze the grid's inset for a landing that is not coming.
                self.source.setZoomSourceHidden(false)
                context.completeTransition(false)
                #if DEBUG
                Self.logTeardown("reversed", context: context, card: flight.card, fromView: fromView)
                #endif
                return
            }
            // A donated surface goes back ONLY when the viewer abandoned the
            // dismissal. On a completed one the destination is leaving and its
            // parked player belongs to the source that is landing — reclaiming
            // there would steal it back and restart the video at zero.
            if cancelled, let surface = flight.card.zoomLiveMediaSurface {
                self.destination?.zoomReclaimLiveMediaView(surface)
            }
            // Same handshake in reverse: the landing tile takes the surface
            // the card was flying, so it renders immediately instead of
            // starting a fresh layer that is blank for ~100ms.
            // Only when the surface was NOT hoisted. A hosted surface is landed
            // by its host, which deliberately does not re-parent it into the
            // cell — calling this would undo exactly that and reintroduce the
            // readiness drop the hoist exists to remove.
            if !cancelled, !hoisted, let surface = flight.card.zoomLiveMediaSurface {
                self.source.zoomAdoptLiveMediaView(surface)
            }
            flight.shadow.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            ZoomFlight.clearRecededChrome(from: presentingView) // bezel-aligned again at scale 1
            // The card is posed exactly over the source and showing the same
            // frames, so hold it until the source's own surface is rendering.
            // Re-binding a player layer costs a decode round-trip that no
            // ordering avoids; holding the twin over it for those few frames is
            // what keeps the dip off screen.
            Self.holdCard(flight.card,
                          liveMediaIsDrawing: { [weak card = flight.card] in
                              card?.zoomLiveMediaIsDrawing ?? true
                          },
                          liveMediaState: { [weak card = flight.card] in
                              card?.zoomLiveMediaDebugState ?? "card gone"
                          },
                          finalizeLanding: { [weak sourceRef = self.source] in
                              sourceRef?.zoomFinalizeLanding()
                          },
                          path: "animator/tap-back",
                          while: { [weak sourceRef = self.source] in
                              sourceRef.map { !$0.zoomLandingMediaIsReady } ?? false
                          })
            // Restore the feed content for the cancel path; moot when finished.
            self.destination?.setZoomContentHidden(false)
            self.destination?.zoomTransitionDidEnd()
            if !cancelled {
                self.source.setZoomSourceHidden(false)
            }
            context.completeTransition(!cancelled)
            #if DEBUG
            Self.logTeardown("done", context: context, card: flight.card, fromView: fromView)
            #endif
        }
        return animator
    }
}
