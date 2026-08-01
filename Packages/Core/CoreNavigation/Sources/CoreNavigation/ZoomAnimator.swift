
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
    private let source: any ZoomTransitionSource
    private weak var destination: (any ZoomTransitionDestination)?
    /// The flight's spring is defined once on `ZoomFlight` and shared with the
    /// interactive grab, so present, tap-back, and released-swipe dismissals all
    /// settle with identical physics.
    private let duration = ZoomFlight.springDuration

    /// Source chrome that fades in over the dismiss spring; see
    /// `ZoomTransitionController.returningSourceChrome`.
    private weak var returningChrome: UIView?

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
        if isPresenting { present(context) } else { dismiss(context) }
    }

    // MARK: - Present

    private func present(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
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

        // Pose the card as the pin and swap the real pin for it inside this
        // same transaction: the twin is pixel-identical (same component, same
        // ring, same crop, live video mirrored), so no frame can render a
        // mismatch — or both pins, or neither.
        flight.poseAtSource()
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
        // Dim fades on a plain curve — opacity should never bounce.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        // Card and the map's depth ride ONE spring, so the lift-off and the
        // canvas receding stay locked together and land as a single settle.
        // The card lands flush with the device's own display corners, so the
        // reveal of the (screen-clipped) feed underneath is seamless.
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: ZoomFlight.springDamping,
                       initialSpringVelocity: ZoomFlight.springVelocity, options: []) {
            flight.poseAsPage(cornerRadius: screenRadius)
            presentingView?.transform = CGAffineTransform(
                scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
            )
        } completion: { _ in
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
        private let deadline: CFTimeInterval

        init(card: UIView, condition: @escaping () -> Bool,
             liveMediaIsDrawing: @escaping () -> Bool,
             liveMediaState: @escaping () -> String, deadline: CFTimeInterval) {
            self.card = card
            self.condition = condition
            self.liveMediaIsDrawing = liveMediaIsDrawing
            self.liveMediaState = liveMediaState
            self.deadline = deadline
        }

        /// Frames held before a "ready" answer is trusted. The dip arrives via
        /// KVO roughly 8ms after the surface is installed, so a few frames at
        /// 60Hz cover its delivery either way. Lives here, not on the animator,
        /// because the display-link callback is nonisolated.
        private static let minimumHoldFrames = 4
        private var frames = 0

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

    private func dismiss(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
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
            hoisted = source.zoomHoistLiveMedia(surface, at: pageFrame, in: container)
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
        // NOT the cause of the single black frame at dismissal start: deferring
        // this by a runloop turn was measured and changed nothing (5 flights,
        // 5 dark frames, before and after). Left synchronous rather than
        // carrying an unverified async edit through shared transition code that
        // Maps also rides.
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
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: ZoomFlight.springDamping,
                       initialSpringVelocity: ZoomFlight.springVelocity, options: []) {
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
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
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
        }
    }
}
