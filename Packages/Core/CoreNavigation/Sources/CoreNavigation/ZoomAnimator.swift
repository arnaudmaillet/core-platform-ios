
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

    /// The card of the flight this animator currently has staged. A mid-air
    /// catch (`ZoomFlightInterruptor`) drives its transform directly — the
    /// free-position channel — while the percent driver scrubs everything
    /// else. Weak: the transition container owns the card for the flight's
    /// lifetime, and this seam only borrows it.
    private(set) weak var stagedFlightCard: (any ZoomFlightCard)?

    /// The staged flight's two endpoint rects in ANIMATION order — `start` is
    /// the pose the animator departs from (the tile on a present, the page on
    /// a dismiss), `end` where it lands. A mid-air catch recovers the caught
    /// fraction from the card's presentation size against these, because the
    /// percent driver's synced fraction is time-based and wrong for a spring.
    private(set) var stagedFlightEndpoints: (start: CGRect, end: CGRect)?

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
        super.init()
        #if DEBUG
        ZoomDebugCensus.increment(ZoomDebugCensus.Key.animator)
        #endif
    }

    #if DEBUG
    deinit {
        ZoomDebugCensus.decrement(ZoomDebugCensus.Key.animator)
    }
    #endif

    /// Drops everything this animator holds about a finished flight — the
    /// cached property animator above all. Its completion blocks capture
    /// `self` while `self` retains it, a cycle that is normally broken when
    /// the animator finishes and releases its blocks; a transition UIKit
    /// abandons never finishes, and the pair then keeps each other (and the
    /// staged card they capture) alive for the life of the process. Called in
    /// every terminal branch, where the cycle stops earning its keep.
    private func releaseFlightState() {
        interruptible = nil
        interruptibleContext = nil
        stagedFlightCard = nil
        stagedFlightEndpoints = nil
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        duration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        // Belt and braces: an interactive driver runs its own flight through
        // `startInteractiveTransition` and UIKit does not call this, but
        // building a second flight here would be silent and total.
        guard !isSupersededByInteractiveDriver else { return }
        // NOTE: UIKit does not take this path for an interruptible
        // transition — it asks for `interruptibleAnimator` and drives that
        // itself. Waypoints placed here to profile the flight never fired.
        interruptibleAnimator(using: context).startAnimation()
    }

    /// Fires when a PRESENT flight is REVERSED mid-air — the viewer caught the
    /// push and dragged it back to the grid, so the destination never showed.
    ///
    /// This is the one outcome `UINavigationControllerDelegate.didShow` cannot
    /// be relied on to report: it announces completed transitions, and a
    /// cancelled one completes nothing. Every owner-side teardown was keyed on
    /// the didShow pair (`onDestinationShown` / `onSourceReturned`), so a
    /// reversed push left the owner's per-flight state locked — the retained
    /// transition controller (which gates every future tap), the stale
    /// navigation delegate, the open playback-handoff scope, the hidden tab
    /// bar. Fired after `completeTransition(false)`, mirroring where didShow
    /// would have landed.
    var onPresentationReversed: (() -> Void)?

    /// Set when a grab that started from REST owns this transition.
    ///
    /// `ZoomDismissInteractionController` stages its OWN complete flight — card,
    /// shadow, dim, destination hidden — and drives it from pan events. This
    /// animator must then build nothing at all, or the two flights stack: two
    /// cards over one screen, the destination hidden twice, and a grab that
    /// looks dead because a second card is sitting on top of the one the finger
    /// is moving.
    var isSupersededByInteractiveDriver = false

    /// Both legs answer `interruptibleAnimator(using:)`, EXCEPT when an
    /// interactive driver has taken the transition.
    ///
    /// It used to be, and the reason is worth keeping: the method is OPTIONAL
    /// and one class serves both legs, so while only the dismissal was built
    /// here an unconditional implementation answered the PUSH too and ran the
    /// whole DISMISS setup against a present context — a page-posed card with
    /// the feed's chrome replica, inserted and never animated. Now that the
    /// build below branches on the leg, answering for both is correct; the
    /// branch is what makes it correct, not the selector.

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(interruptibleAnimator(using:)) {
            return !isSupersededByInteractiveDriver
        }
        return super.responds(to: aSelector)
    }

    /// The dismissal runs on a property animator so it can be interrupted.
    ///
    /// Only the dismiss leg. Interrupting a present means defining what a
    /// reversed push does to the pool loan and to a hoisted surface, which is
    /// its own change.
    func interruptibleAnimator(
        using context: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
            print("[anim] asked presenting=\(isPresenting) cached=\(interruptible != nil)"
                  + " sameCtx=\(interruptibleContext === (context as AnyObject))"
                  + " superseded=\(isSupersededByInteractiveDriver)")
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] interruptibleAnimator asked presenting=\(isPresenting) cached=\(interruptible != nil) sameCtx=\(interruptibleContext === (context as AnyObject))")
        }
        #endif
        if let interruptible, interruptibleContext === (context as AnyObject) {
            return interruptible
        }
        #if DEBUG
        // The watch starts BEFORE the build, or the build's own stall is
        // outside the window being measured — which is how the first pass of
        // this profile managed to report a gap that never included it.
        ZoomFlightProfiler.shared.flightWillBuild(presenting: isPresenting)
        let buildStart = CACurrentMediaTime()
        #endif
        let animator = isPresenting ? present(context) : dismiss(context)
        #if DEBUG
        ZoomFlightProfiler.shared.flightBuilt(
            buildMilliseconds: (CACurrentMediaTime() - buildStart) * 1000
        )
        #endif
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
        stagedFlightCard = flight.card
        stagedFlightEndpoints = (start: sourceFrame, end: pageFrame)
        container.insertSubview(flight.card, belowSubview: toView)
        container.insertSubview(flight.shadow, belowSubview: flight.card)
        // Resolve the chrome replica's full-screen layout (safe areas, text
        // wrapping) while the card still spans the page; its bounds never
        // change again, so nothing can relayout mid-flight.
        container.layoutIfNeeded()

        // The flight is watchable, not touchable. The presented container
        // stays visible and CLEAR above the card (that is what keeps the
        // navigation bar native), and the grid stays live beneath it — so
        // without this, every touch during the flight fell through to one of
        // them: a feed button on a screen that has not landed, a tile tap, or
        // a gallery scroll whose layout pass could even start a page fetch
        // mid-flight. The shield sits topmost in the container, so
        // hit-testing stops at it, while the mid-air catch keeps working —
        // its recognizers are attached to the container itself and see every
        // touch in its subtree. Removed on both completions; the container
        // outlives the transition.
        let shield = UIView(frame: container.bounds)
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(shield)

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
        // The hide therefore lands strictly AFTER the pose's commit — and
        // then waits one thing more, because commit ordering is necessary but
        // not sufficient on device: a video layer's content travels OUTSIDE
        // the transaction (sample buffers, layer acquisition), so a card can
        // be committed, in-tree, and still composite EMPTY for a pass. Every
        // signal this side can read is client-side, so the gate is the card's
        // own drawing report plus one display refresh — the only observable
        // proxy for "the render server has had a pass with the card in it".
        // Overlap is free either way: while the source is still up, a live
        // card is transparent beneath its surface and a cover-only card is a
        // pixel-identical twin, so no frame in the window can show a
        // mismatch. See `afterCurrentTransactionCommits` for why the commit
        // half is a transaction completion rather than the flush it was.
        flight.poseAtSource()
        Self.afterCurrentTransactionCommits {
            Self.whenReady(ceiling: Self.maximumFirstFrameHold, afterTicks: 1,
                           condition: { [weak card = flight.card] in
                               card?.zoomLiveMediaIsDrawing ?? true
                           }) {
                // A reversal that beat this gate has already restored the
                // source; hiding it now would strand it invisible.
                guard !self.hasAbandonedFirstFrameHandoff else { return }
                #if DEBUG
                Self.logFirstFrameHandoff("present", card: flight.card)
                #endif
                self.source.setZoomSourceHidden(true)
            }
        }

        let screenRadius = ZoomFlight.screenCornerRadius(behind: container)

        // Depth cue: the presenting map recedes to 0.95, so the feed reads as
        // lifting off a 3D canvas. (`view(forKey:)` is nil under an
        // over-full-screen present, so reach the root via the view controller.)
        // The depth cue rides the source-nominated view when there is one, so a
        // screen's own chrome stays grounded while its content recedes.
        let presentingView = source.zoomPresenterDepthView ?? context.viewController(forKey: .from)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)

        // A card that took off with nothing live keeps asking for the rest of
        // the flight. The tile it left may have been granted a player only as
        // the tap resolved, and its first decoded frame lands mid-air — so the
        // difference between a hero that shows video and one that shows a
        // poster is often a hundred milliseconds nobody can schedule around.
        // Retained by its own display link; it stops itself.
        ZoomLiveMediaRetry.arm(card: flight.card, pageSize: flight.pageFrame.size, source: source)

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
            #if DEBUG
            ZoomFlightProfiler.shared.note("pose block >")
            #endif
            flight.poseAsPage(cornerRadius: screenRadius)
            presentingView?.transform = CGAffineTransform(
                scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
            )
            #if DEBUG
            ZoomFlightProfiler.shared.note("pose block <")
            #endif
        }
        // The dim was a second, plainly-curved animation ("opacity should never
        // bounce"). A property animator carries one curve, and a separate
        // UIView animation would neither scrub nor reverse with the rest, so it
        // rides this one delayed instead — which keeps what the curve was FOR:
        // the map reads through for most of the flight and goes to black as the
        // card lands.
        animator.addAnimations({ dim.alpha = 1 }, delayFactor: 0.35)
        animator.addCompletion { _ in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
                print(String(format: "[zoom] present completion at +%.1f ms",
                             ZoomFlightProfiler.shared.elapsedMilliseconds))
            }
            #endif
            if context.transitionWasCancelled {
                // REVERSED push: the grid is staying. The card has already been
                // animated back onto the tile, so this only has to put the tile
                // back and drop everything the flight added.
                //
                // Nothing to hand back: under N-surface the card joined the
                // TILE's playback as an extra surface and the tile never stopped
                // rendering, so the surface is simply dropped. The destination
                // is not revealed — UIKit removes it on `completeTransition`.
                self.hasAbandonedFirstFrameHandoff = true
                shield.removeFromSuperview()
                flight.card.removeFromSuperview()
                flight.shadow.removeFromSuperview()
                dim.removeFromSuperview()
                presentingView?.transform = .identity
                ZoomFlight.clearRecededChrome(from: presentingView)
                self.destination?.zoomTransitionDidEnd()
                self.source.setZoomSourceHidden(false)
                self.releaseFlightState()
                context.completeTransition(false)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print("[zoom-live] present REVERSED, source restored")
                }
                #endif
                self.onPresentationReversed?()
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
            // BOTH halves of readiness, and the second is the device lesson:
            // data is not pixels. With posts present the reveal still swapped
            // the card for a page whose media area was compositing NOTHING
            // yet — measured on device (run 2, covers-only) as the card
            // vanishing into a black screen at the exact end of the present.
            // So the gate also asks whether the active page's media area is
            // actually rendering (surface or poster), plus one display tick
            // for the composite to land. Until then the card — the same
            // cover, full-bleed — stays on screen through the transparent
            // destination, which is strictly better content than the black
            // it was being traded for.
            //
            // Everything below stays in one block so the ordering note above
            // still holds: reveal, THEN adopt the surface, then drop the card.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
                let d = self.destination
                print(String(format: "[zoom] reveal gate armed at +%.1f ms (content=%@ media=%@)",
                             ZoomFlightProfiler.shared.elapsedMilliseconds,
                             d?.zoomDestinationContentIsReady.description ?? "-",
                             d?.zoomDestinationMediaIsRendering.description ?? "-"))
            }
            #endif
            Self.whenReady(ceiling: Self.maximumHydrationHold,
                           afterTicks: 1,
                           condition: { [weak destination = self.destination] in
                               guard let destination else { return true }
                               return destination.zoomDestinationContentIsReady
                                   && destination.zoomDestinationMediaIsRendering
                           }) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-profile") {
                    ZoomFlightProfiler.shared.note("card removed")
                    print(String(format: "[zoom] card removed at +%.1f ms",
                                 ZoomFlightProfiler.shared.elapsedMilliseconds))
                }
                #endif
                shield.removeFromSuperview()
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
                self.releaseFlightState()
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
        return animator
    }

    /// Runs `work` after the transaction currently being staged has been
    /// committed to the render server — so whatever `work` mutates lands one
    /// commit BEHIND everything staged so far.
    ///
    /// This replaces `CATransaction.flush()` at the frame-0 handshakes. The
    /// flush bought the right ordering — card committed first, its source
    /// hidden a commit later — but paid for it by committing the entire dirty
    /// layer tree synchronously, in the middle of the one turn that is already
    /// the flight's most expensive (staging layout passes, feed construction,
    /// player teardown). At 120Hz that turn has an 8ms budget, and blowing it
    /// is itself a dropped frame at frame 0 — a stall that varied with how
    /// much happened to be dirty, which is what made it read as random.
    ///
    /// A plain `DispatchQueue.main.async` is NOT a substitute, and was
    /// measured changing nothing when it was tried on the dismiss leg: the
    /// main queue can drain several blocks inside one runloop iteration, so a
    /// "next turn" hide can land in the SAME commit as the pose and the
    /// overlap frame never exists. An empty nested transaction's completion
    /// block has the one property that matters — Core Animation enqueues it
    /// only once the enclosing commit has gone to the render server, so what
    /// `work` changes is a strictly later commit. The ordering the flush
    /// guaranteed, without the synchronous cost.
    static func afterCurrentTransactionCommits(_ work: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            // Documented to arrive on the main thread; hop the isolation
            // boundary the CA API cannot express.
            MainActor.assumeIsolated(work)
        }
        CATransaction.commit()
    }

    /// Runs `work` as soon as `condition` is true, or at `ceiling`, whichever
    /// comes first. Polled on the display link, like the landing hold.
    ///
    /// With `afterTicks` 0 it fires SYNCHRONOUSLY when the condition already
    /// holds, so the common case — a destination whose data was ready before
    /// the flight ended — keeps the exact ordering and timing it had before
    /// this existed. A non-zero `afterTicks` always waits that many display
    /// refreshes first: every condition this gate can ask is a CLIENT-side
    /// fact, and a tick is the only observable proxy for "the render server
    /// has had a pass since then".
    static func whenReady(ceiling: CFTimeInterval,
                          afterTicks minimumTicks: Int = 0,
                          condition: @escaping () -> Bool,
                          then work: @escaping () -> Void) {
        if minimumTicks == 0, condition() {
            work()
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f gate holding (minTicks=%d ready=%@)",
                         CACurrentMediaTime(), minimumTicks, condition() ? "yes" : "no"))
        }
        #endif
        let deadline = CACurrentMediaTime() + ceiling
        let link = CADisplayLink(
            target: ReadyGate(condition: condition, deadline: deadline,
                              minimumTicks: minimumTicks, work: work),
            selector: #selector(ReadyGate.tick)
        )
        link.add(to: .main, forMode: .common)
    }

    private final class ReadyGate {
        private let condition: () -> Bool
        private let deadline: CFTimeInterval
        private let minimumTicks: Int
        private let work: () -> Void
        private var fired = false
        private var ticks = 0

        init(condition: @escaping () -> Bool, deadline: CFTimeInterval,
             minimumTicks: Int, work: @escaping () -> Void) {
            self.condition = condition
            self.deadline = deadline
            self.minimumTicks = minimumTicks
            self.work = work
        }

        @objc func tick(_ link: CADisplayLink) {
            guard !fired else { return }
            ticks += 1
            let timedOut = CACurrentMediaTime() >= deadline
            guard ticks >= minimumTicks, condition() || timedOut else { return }
            fired = true
            link.invalidate()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print(String(format: "[zoom-live] %.3f gate released t%d%@",
                             CACurrentMediaTime(), ticks, timedOut ? " (TIMEOUT)" : ""))
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

    /// Ceiling on the drawing-gated hide at frame 0. Generous next to the one
    /// or two render-server passes it normally waits, and small against the
    /// 420ms flight, so a surface that never reports drawing degrades to the
    /// old commit-ordered timing instead of stranding two live twins.
    /// Internal: the grab (`ZoomDismissInteractionController`) runs the same
    /// gate at its own staging.
    static let maximumFirstFrameHold: CFTimeInterval = 0.15

    /// Set when a REVERSED flight has already restored what the pending
    /// frame-0 hide would take away. The hide waits on a display-link gate,
    /// so a very fast reversal can land inside its window — and a hide that
    /// fires after the restore would leave the source (or the destination)
    /// invisible with nothing left to ever bring it back.
    private var hasAbandonedFirstFrameHandoff = false

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

        /// How long a "ready" answer is distrusted after the hold begins. The
        /// dip arrives via KVO roughly 8ms after the surface is installed, and
        /// this spans its delivery with margin. WALL CLOCK, deliberately: the
        /// old four-frame count was tuned at 60Hz (~66ms) and silently halved
        /// to 33ms on ProMotion, where ticks come twice as fast — the window's
        /// rationale is a delivery latency, which does not scale with the
        /// refresh rate. The GRACE step below stays tick-based on purpose: its
        /// unit genuinely is one compositor pass.
        private static let minimumSettleWindow: CFTimeInterval = 4.0 / 60.0
        private let began = CACurrentMediaTime()
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
            let settling = CACurrentMediaTime() - began < Self.minimumSettleWindow
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
        stagedFlightCard = flight.card
        stagedFlightEndpoints = (start: pageFrame, end: sourceFrame)
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
        // Same shield as the present leg, for the same reason: the departing
        // feed's view rides on top with its content hidden but its touch
        // handling alive, and the grid is live beneath it.
        let shield = UIView(frame: container.bounds)
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(shield)
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
        // anything; a transaction completion is enqueued only after the commit
        // itself. And commit is still only half: the surface's CONTENT rides
        // outside the transaction, so the hide additionally waits for the
        // card to report drawing plus one display refresh — the same gate,
        // for the same reason, as the present leg. The feed stays opaque over
        // the (already animating) card for those ticks, which shows as the
        // flight starting a frame late rather than as a frame of stale cover.
        Self.afterCurrentTransactionCommits { [weak destination = self.destination] in
            Self.whenReady(ceiling: Self.maximumFirstFrameHold, afterTicks: 1,
                           condition: { [weak card = flight.card] in
                               card?.zoomLiveMediaIsDrawing ?? true
                           }) {
                // A reversal that beat this gate has already restored the
                // destination; hiding it now would strand the feed invisible.
                guard !self.hasAbandonedFirstFrameHandoff else { return }
                #if DEBUG
                Self.logFirstFrameHandoff("dismiss", card: flight.card)
                #endif
                destination?.setZoomContentHidden(true)
            }
        }

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
            shield.removeFromSuperview()
            #if DEBUG
            Self.logTeardown("enter", context: context, card: flight.card, fromView: fromView)
            #endif
            if cancelled {
                // REVERSED mid-flight: the feed is staying, so everything the
                // flight took has to go back before it is handed control again.
                self.hasAbandonedFirstFrameHandoff = true
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
                self.releaseFlightState()
                context.completeTransition(false)
                #if DEBUG
                Self.logTeardown("reversed", context: context, card: flight.card, fromView: fromView)
                #endif
                return
            }
            // From here on the dismissal COMPLETED — the cancelled branch
            // returned above, and it is the one that gives donated surfaces
            // back. On a completed dismissal the destination is leaving and
            // its parked player belongs to the source that is landing;
            // reclaiming here would steal it back and restart the video at
            // zero.
            // Same handshake in reverse: the landing tile takes the surface
            // the card was flying, so it renders immediately instead of
            // starting a fresh layer that is blank for ~100ms.
            // Only when the surface was NOT hoisted. A hosted surface is landed
            // by its host, which deliberately does not re-parent it into the
            // cell — calling this would undo exactly that and reintroduce the
            // readiness drop the hoist exists to remove.
            if !hoisted, let surface = flight.card.zoomLiveMediaSurface {
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
            self.destination?.setZoomContentHidden(false)
            self.destination?.zoomTransitionDidEnd()
            self.source.setZoomSourceHidden(false)
            self.releaseFlightState()
            context.completeTransition(true)
            #if DEBUG
            Self.logTeardown("done", context: context, card: flight.card, fromView: fromView)
            #endif
        }
        return animator
    }
}


#if DEBUG
// MARK: - Poor-man's main-thread sampler
//
// The phase timeline can prove the main thread is busy inside ONE stack, but
// not whose code that stack is running — and when the answer turns out to be
// "UIKit's own transition machinery", there is no mark left to place. So we
// sample: `ITIMER_PROF` fires on the thread burning CPU, and the handler
// records a raw backtrace. Symbolisation happens later, on the main thread,
// because it allocates and a signal handler may not.
//
// Nothing here runs unless `-zoom-profile` is passed, and the whole block is
// DEBUG-only — this is a diagnostic instrument, not shipped behaviour.
private let zoomSampleMaxFrames = 96
private let zoomSampleMaxCount = 512
private nonisolated(unsafe) let zoomSampleFrames =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(
        capacity: zoomSampleMaxFrames * zoomSampleMaxCount
    )
private nonisolated(unsafe) let zoomSampleDepths =
    UnsafeMutablePointer<Int32>.allocate(capacity: zoomSampleMaxCount)
private nonisolated(unsafe) let zoomSampleTimes =
    UnsafeMutablePointer<UInt64>.allocate(capacity: zoomSampleMaxCount)
private nonisolated(unsafe) var zoomSampleCount: Int32 = 0

/// Async-signal-safe by construction: `backtrace` walks the stack and
/// `clock_gettime_nsec_np` reads the clock; neither allocates, and nothing
/// else is touched.
private let zoomSampleTick: @convention(c) (Int32) -> Void = { _ in
    let index = Int(zoomSampleCount)
    guard index < zoomSampleMaxCount else { return }
    let slot = zoomSampleFrames.advanced(by: index * zoomSampleMaxFrames)
    zoomSampleDepths[index] = backtrace(slot, Int32(zoomSampleMaxFrames))
    zoomSampleTimes[index] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    zoomSampleCount = Int32(index + 1)
}

/// Stamps the hero flight's phase timeline from outside `CoreNavigation` —
/// the push's CALLER, which is the only place that can say when
/// `pushViewController` returned. No-op unless `-zoom-profile` is set.
@MainActor
public func zoomProfilerNote(_ label: String) {
    ZoomFlightProfiler.shared.note(label)
}

/// Frame-gap and build-cost watch for the hero flight, behind `-zoom-profile`.
///
/// The same two numbers the comments engagement is profiled with, for the same
/// reason: a "stutter" report needs the synchronous cost AND how long the
/// screen actually went without an update, because those are different
/// questions and only one of them is usually the answer.
///
/// # What this found, so the next reader starts where it left off
/// The flight's build is ~22 ms, but no frame reaches the screen for ~120 ms.
/// Four instruments, each answering what the previous one could not:
///
///  1. A main-queue hop: it waited 85-108 ms, so the main thread is BUSY. The
///     wait is work, not the render server being slow.
///  2. Run-loop observers: NOTHING fires for that whole window — no
///     `beforeWaiting`, so CoreAnimation's commit cannot even have run. The
///     stall is one uninterrupted UIKit stack, and layout/display is not it.
///  3. Marks inside the animation blocks: our own pose work is 4 ms and ends
///     at +27 ms. Everything after it is UIKit's.
///  4. `ITIMER_PROF` stack sampling of the remainder: `-[UINavigationBar
///     _setItems:transition:]` and `-[UINavigationItem
///     _accumulateViewsFromItems:]`, Auto Layout engine churn as each custom
///     bar view moves in, `_UIVisualEffectHost` filter configuration, and —
///     dominating it — SwiftUI AttributeGraph type/conformance resolution and
///     `SDFLayer`/`DisplayList` updates. That last pair is iOS 26 Liquid Glass
///     being materialised, by UIKit, inside the push.
///
/// About HALF of it is one-time, and the split only shows up if you push more
/// than once per process (`-zoom-repeat`): the first push waits ~93 ms and
/// drops to a ~142 ms gap, while the second and third wait ~46-49 ms for a
/// ~65 ms gap. So the SwiftUI/glass machinery is warming up on first use, and
/// what remains after it is warm is the per-push half — a fresh destination
/// controller per tap, whose chrome's glass is built from scratch every time.
///
/// Two consequences worth keeping. Measure this on a warm push unless you
/// mean to measure launch, or you will attribute one-time cost to the flight.
/// And the per-push half is only reachable by not rebuilding the destination:
/// everything above runs inside UIKit's bar transition, where nothing outside
/// can pre-pay it (`prepareForHeroPresentation` tried, and its comment records
/// what that cost).
///
/// One caveat on the numbers: 54 of 79 samples in the window were the
/// SOFTWARE H.264 codec on worker threads. The simulator has no hardware
/// decode, so the main thread is fighting it for CPU and the wall-clock here
/// is inflated relative to a device.
@MainActor
final class ZoomFlightProfiler: NSObject {
    static let shared = ZoomFlightProfiler()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var watchStart: CFTimeInterval = 0
    private var buildEndedAt: CFTimeInterval = 0
    private var gaps: [(offset: Double, gap: Double)] = []
    private var leg = ""
    private var generation = 0

    private var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-zoom-profile")
    }

    func flightWillBuild(presenting: Bool) {
        guard isEnabled else { return }
        leg = presenting ? "present" : "dismiss"
        link?.invalidate()
        watchStart = CACurrentMediaTime()
        last = watchStart
        buildEndedAt = 0
        gaps = []
        marks = []
        removeRunLoopProbe()
        installRunLoopProbe()
        armSampler()
        mark("build >")
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        // Tagged, because legs overlap: a pop 3 s after a push starts its own
        // watch, and the earlier leg's pending report would then describe the
        // NEW leg's freshly-cleared state — which reads as a clean flight
        // rather than as a report that outlived its subject. (It did: repeat
        // pushes appeared to drop 0 frames.)
        generation += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == token else { return }
            self.report()
        }
    }

    func flightBuilt(buildMilliseconds: Double) {
        guard isEnabled else { return }
        buildEndedAt = CACurrentMediaTime()
        print(String(format: "[zoom] %@ flight built %6.2f ms", leg, buildMilliseconds))
        // IS THE MAIN THREAD BUSY, or is the wait render-side? A main-queue
        // hop answers without depending on display timing at all: it runs the
        // instant the main thread is free. A display-link tick can be late for
        // either reason, which is not good enough to attribute a stall.
        let queuedAt = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mark("main-queue hop ran")
            let now = CACurrentMediaTime()
            print(String(format: "[zoom]   main-queue hop waited %6.2f ms (at +%.1f ms)",
                         (now - queuedAt) * 1000, (now - self.watchStart) * 1000))
        }
    }

    // MARK: - Where the busy window actually goes

    /// The main thread being BUSY narrows a stall to "work", not "waiting on
    /// the render server" — but not to WHICH work. These observers split the
    /// run loop's own phases apart, and in particular bracket CoreAnimation's
    /// commit: CA installs its commit as a `beforeWaiting` observer at order
    /// 2_000_000, so a mark either side of that order measures layout+display
    /// of everything the flight just added, separately from the UIKit source
    /// work that queued it. Those are the two candidates, and they are not
    /// distinguishable from the outside.
    private var probes: [CFRunLoopObserver] = []
    private var marks: [(label: String, at: CFTimeInterval)] = []

    private func mark(_ label: String) {
        guard marks.count < 400 else { return }
        marks.append((label, CACurrentMediaTime()))
    }

    /// Lets the CALLER of the push stamp the same timeline — the window opens
    /// inside `pushViewController`, so "did the push return yet" is the seam
    /// that splits UIKit's own transition work from the tap handler's.
    func note(_ label: String) {
        guard isEnabled else { return }
        mark(label)
    }

    /// Milliseconds since the current flight's watch opened.
    var elapsedMilliseconds: Double { (CACurrentMediaTime() - watchStart) * 1000 }

    private func installRunLoopProbe() {
        let loop = CFRunLoopGetMain()
        func add(_ activity: CFRunLoopActivity, order: CFIndex, label: String) {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, activity.rawValue, true, order
            ) { _, _ in
                MainActor.assumeIsolated { self.mark(label) }
            }
            guard let observer else { return }
            CFRunLoopAddObserver(loop, observer, .commonModes)
            probes.append(observer)
        }
        add(.afterWaiting, order: 0, label: "woke")
        add(.beforeSources, order: 0, label: "sources")
        add(.beforeWaiting, order: 1_999_999, label: "CA commit >")
        add(.beforeWaiting, order: 2_000_001, label: "CA commit <")
        add(.beforeWaiting, order: CFIndex.max - 1, label: "sleeping")
    }

    private func removeRunLoopProbe() {
        let loop = CFRunLoopGetMain()
        for observer in probes { CFRunLoopRemoveObserver(loop, observer, .commonModes) }
        probes = []
    }

    /// 4 ms of CPU time per sample — fine enough to resolve an 85 ms stall
    /// into distinct phases, coarse enough that the sampler is not itself the
    /// thing being measured.
    private static let sampleIntervalMicroseconds: Int32 = 4000

    private func armSampler() {
        zoomSampleCount = 0
        signal(SIGPROF, zoomSampleTick)
        let tick = timeval(tv_sec: 0, tv_usec: Self.sampleIntervalMicroseconds)
        var timer = itimerval(it_interval: tick, it_value: tick)
        setitimer(ITIMER_PROF, &timer, nil)
    }

    private func disarmSampler() {
        var off = itimerval()
        setitimer(ITIMER_PROF, &off, nil)
        signal(SIGPROF, SIG_IGN)
    }

    /// Prints the sampled stacks that landed in the stall, innermost frame
    /// first, with each sample's offset into the flight. Frames from this
    /// file's own instrumentation are kept — seeing where the sampler itself
    /// lands is how you tell a real stack from an artefact.
    private func reportSamples(from windowStart: Double, to windowEnd: Double) {
        let taken = Int(zoomSampleCount)
        guard taken > 0 else { return print("[zoom]   sampler: no samples") }
        print(String(format: "[zoom]   sampler: %d samples, stacks inside +%.0f..%.0f ms",
                     taken, windowStart, windowEnd))
        for index in 0..<taken {
            let offset = (Double(zoomSampleTimes[index]) / 1_000_000) - (watchStart * 1000)
            guard offset >= windowStart, offset <= windowEnd else { continue }
            let depth = Int(zoomSampleDepths[index])
            let slot = zoomSampleFrames.advanced(by: index * zoomSampleMaxFrames)
            guard depth > 1, let symbols = backtrace_symbols(slot, Int32(depth)) else { continue }
            print(String(format: "[zoom]   --- sample at +%6.1f ms", offset))
            // Frame 0 is the handler itself; start past it, and stop before
            // the run loop's own boilerplate at the base of every stack.
            for frame in 1..<min(depth, 26) {
                guard let symbol = symbols[frame] else { continue }
                print("[zoom]       \(String(cString: symbol))")
            }
            free(symbols)
        }
    }

    /// Every dropped frame WITH ITS OFFSET, and where the build ended, so a
    /// gap can be attributed instead of guessed at. A total alone cannot say
    /// whether the stall is the setup or the first frames after it.
    private func report() {
        link?.invalidate()
        link = nil
        removeRunLoopProbe()
        let buildOffset = (buildEndedAt - watchStart) * 1000
        // The phase timeline, with each phase's DURATION (mark to next mark) —
        // the gap between two marks is the cost of whatever ran between them,
        // which is the only way a "CA commit <" 90 ms after "CA commit >"
        // reads as "the commit took 90 ms" rather than as a bare timestamp.
        var previous = watchStart
        var widestGap = (start: 0.0, end: 0.0, cost: 0.0)
        for (label, at) in marks where (at - watchStart) < 0.4 {
            let cost = (at - previous) * 1000
            print(String(format: "[zoom]   %-16@ at +%6.1f ms  (+%5.1f ms since last)",
                         label as NSString, (at - watchStart) * 1000, cost))
            if cost > widestGap.cost {
                widestGap = ((previous - watchStart) * 1000, (at - watchStart) * 1000, cost)
            }
            previous = at
        }
        // Sample the WIDEST unexplained span, whichever it turns out to be —
        // hardcoding the span found today would stop reporting the moment a
        // change moves the stall somewhere else.
        disarmSampler()
        if widestGap.cost > 20 {
            reportSamples(from: widestGap.start, to: widestGap.end)
        }
        let worst = gaps.map(\.gap).max() ?? 0
        print(String(format: "[zoom] %@ frames: worst %5.1f ms, %d dropped; build ended at +%.1f ms",
                     leg, worst * 1000, gaps.count, buildOffset))
        for (offset, gap) in gaps {
            let side = offset * 1000 < buildOffset ? "during build" : "AFTER build"
            print(String(format: "[zoom]     drop at +%6.1f ms  gap %5.1f ms  (%@)",
                         offset * 1000, gap * 1000, side))
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = now - last
        last = now
        if gap > 0.025 { gaps.append((offset: now - watchStart, gap: gap)) }
    }
}
#endif
