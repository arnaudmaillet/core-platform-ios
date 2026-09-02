import UIKit

/// Interactive rightward swipe-to-pop for a screen pushed WITHOUT a hero —
/// gesture parity with the pin feed's grab, minus the pin.
///
/// Shared by the menu-pushed timeline and by For You's TEXT posts, which push
/// natively because a text page has no media to fly. Both want the same thing
/// and it is worth having once: a full-surface pan that scrubs the pop 1:1,
/// releasing on the same contract every other dismissal in the app uses.
///
/// Deliberately NOT the native `interactivePopGestureRecognizer`: that is
/// edge-only (this pan covers the whole surface, like the grab), it is
/// disabled by the feed's custom back item, and it completes on UIKit's own
/// threshold — both dismissals must release on the one shared contract
/// (`ZoomTransitionGeometry.shouldCompleteDismissal`: 35% of width, or a
/// 900 pt/s flick).
///
/// Deliberately NOT the pin path's free-floating interaction controller:
/// with no pin to land on there is no 2D float, no detach dip, no clip-morph
/// — progress here is one scalar, which is exactly the rail
/// `UIPercentDrivenInteractiveTransition` scrubs. The slide stays strictly
/// horizontal and never touches the hero pipeline (`ZoomFlight`,
/// `poseAtSource`, live-player mirroring).
///
/// Owned by `FeedFlowCoordinator`; installed as the stack's delegate around
/// each push and self-uninstalled (restoring any prior delegate) when the
/// feed leaves the stack.
@MainActor
public final class InteractiveSlideDismissal: NSObject {
    private weak var feedViewController: UIViewController?
    private weak var navigationController: UINavigationController?
    /// Whatever delegate the stack had when the feed was pushed (e.g. a
    /// dormant `ZoomTransitionController`, when a deep link pushes the timeline
    /// above a pin-opened feed) — restored on teardown.
    private weak var savedDelegate: (any UINavigationControllerDelegate)?

    #if DEBUG
    /// Which axes this driver was armed for.
    ///
    /// Published because the property worth checking is not any one driver's
    /// but the SCREEN's: every axis needs a tenant for every dismissal kind, or
    /// a drag lands on nothing at all and the screen simply refuses to close.
    /// That is not observable from outside without knowing who is armed where —
    /// and it has now shipped twice, once on the map and once here.
    public var debugArmedAxes: Set<ZoomDismissAxis> { axes }

    /// Who this driver hands a pop it does not own back to. A driver that took
    /// the slot from a FLIGHT and saved nothing is a screen whose media pages
    /// have quietly lost their hero — visible only as a plain slide, which is
    /// a perfectly good animation.
    public var debugSavedDelegate: (any UINavigationControllerDelegate)? { savedDelegate }
    #endif
    /// Whether `savedDelegate` holds the delegate from BEFORE this screen —
    /// as opposed to whatever happened to be installed during a re-assert.
    private var hasCapturedSavedDelegate = false
    /// Whether a `didShow` has ever observed the feed ON the stack — the
    /// precondition for "not on the stack" meaning POPPED rather than "not
    /// pushed yet". See the note in `navigationController(_:didShow:)`.
    private var hasSeenFeedOnStack = false

    /// Non-nil exactly while a swipe drives a pop; the delegate vends the
    /// slide animator (and this driver) only then, so back-button pops and
    /// every other transition on the stack stay native.
    private var interaction: UIPercentDrivenInteractiveTransition?

    /// Fired when the feed has left the stack (completed pops only — swipe
    /// or back button; a cancelled swipe reports nothing). The owner restores
    /// the manually hidden tab bar here.
    public var onFeedPopped: ((UINavigationController) -> Void)?

    /// Fired at swipe-begin, after the drive is armed and BEFORE the pop is
    /// triggered — the one moment an owner can restage the pop's landing.
    /// Handed the live swipe's axis, because a restaging can be the axis's
    /// whole meaning: the same screen drops an intermediate for a horizontal
    /// escape and INSERTS one for a vertical dismissal into a place page.
    ///
    /// Exists for the cluster-gallery escape: a post opened from the place
    /// gallery swipes right past the gallery to the MAP, and UIKit's popTo
    /// commits its stack mutation at begin where a cancel cannot restore it
    /// (`InteractivePopToStackTests`) — so the recipe is the Case-B one: this
    /// hook drops the intermediate invisibly (`setViewControllers` without
    /// animation, no transition running yet) and installs this driver as the
    /// stack's delegate, and the ordinary, fully cancellable single pop that
    /// follows lands one screen deeper than the stack said a moment ago.
    public var onWillBeginPop: ((ZoomDismissAxis) -> Void)?

    /// **THE TEXT REVEAL**: swaps the slide for a clip-window
    /// reveal on BOTH legs — see `RevealGeometry`.
    ///
    /// An optional value rather than a pair of animator factories, because the
    /// two legs must never disagree about the geometry: one rect calculation,
    /// read forwards on the push and backwards on the pop. Left `nil` this
    /// class behaves exactly as it always has — native push, slide pop — which
    /// is what the timeline and the shipped text path keep getting.
    ///
    /// The gesture, the axes, the release contract, the delegate hand-back and
    /// the `onFeedPopped` bookkeeping are all unchanged and shared: a reveal is
    /// a different ANIMATION of the same dismissal, not a second dismissal.
    public var revealGeometry: RevealGeometry?

    /// Source chrome the reveal drives on BOTH legs — the app's tab bar: faded
    /// out as the page opens over it, faded back in as the page closes. Only
    /// consulted while `revealGeometry` is set; the slide leaves the bar to the
    /// owner's `onFeedPopped`, as before.
    public weak var revealReturningChrome: UIView?

    /// Which axes close as a WINDOW when `revealGeometry` is set. Both by
    /// default, and both is now the shipped case for the place page too: the
    /// rightward close lands on the map's marker and the downward one on the
    /// place page's own Activity card, each with its own geometry supplied by
    /// `prepareForDismissal`.
    ///
    /// The narrowing survives for an owner that has NOTHING to aim the
    /// excluded axis at — a window can only shrink onto a rect some screen is
    /// really showing, and an axis with no such rect must ride the plain
    /// slide instead.
    public var revealReturnAxes: Set<ZoomDismissAxis> = [.horizontal, .vertical]

    /// The axis the FALLBACK slide travels on, when it is not the axis the
    /// finger travelled on.
    ///
    /// ⚠️ A DELIBERATE TRANSPOSITION, not an oversight. The vertical grab on a
    /// cluster's feed exists because a downward flick is how this app closes a
    /// page — but when it falls back to a plain slide, sliding the screen DOWN
    /// reads as the page being dropped rather than left behind. The platform's
    /// own back-direction is horizontal, and that is what the fallback should
    /// look like whatever the hand did. Nil keeps the gesture's own axis,
    /// which is what every other surface wants.
    public var fallbackSlideAxis: ZoomDismissAxis?

    /// An extra veto the owner can impose, asked at begin-time.
    ///
    /// Exists for surfaces where a full-width swipe means something else some
    /// of the time. A profile pages between tabs on a horizontal drag, so the
    /// drag may only dismiss when there is no tab to the left of the current
    /// one; everywhere else the whole surface is always the gesture's.
    ///
    /// Nil means no veto, which is the behaviour every existing caller had.
    public var canBeginDismissal: (() -> Bool)?

    /// Whether a hero grab is attached to the same screen and the two must
    /// divide the work between them.
    ///
    /// Off by default, and that default is the whole of its safety: every
    /// surface that uses this driver alone — a profile, a detail, a timeline
    /// pushed with no flight — keeps claiming drags exactly as it did. Only a
    /// screen that installs BOTH turns it on, and there the two gate on the
    /// post's kind from opposite sides.
    public var arbitratesWithHeroGrab = false

    /// Whether the PUSH onto this screen is the reveal's.
    ///
    /// ⚠️ SEPARATE FROM HAVING A GEOMETRY, and the two came apart the moment
    /// both drivers began sharing a screen. The geometry is what a card-shaped
    /// CLOSE needs, and a media post now carries one too — for the case where
    /// the viewer pages onto a text post before closing. Deciding the push from
    /// its presence would put a reveal over an opening that is a hero flight.
    ///
    /// So the opening says so explicitly, and only a post that was opened AS
    /// text sets it.
    public var revealPresents = false

    /// Called at the instant a dismissal is decided, before anything reads
    /// `revealGeometry` — from a swipe claiming the screen, and from a pop
    /// with no gesture behind it at all.
    ///
    /// Handed the axis the dismissal is travelling on, because on this screen
    /// the two axes go to DIFFERENT places: a text-faced cluster's feed closes
    /// rightward onto the map's marker and downward onto its place page's own
    /// card. One geometry cannot describe both, so the owner swaps it here —
    /// which is exactly early enough, `revealGeometry` being read three lines
    /// below the call. A pop with no gesture is told `.horizontal`, the
    /// platform's own direction and the one the back button means.
    ///
    /// ⚠️ MUST BE IDEMPOTENT. A swipe reaches it twice: once when the grab
    /// claims the screen, and again when the pop it triggers asks for an
    /// animator. What it does — moving a card into the slot the dismissal
    /// flies to — undoes itself if it runs a second time.
    public var prepareForDismissal: ((ZoomDismissAxis) -> Void)?

    /// The recognizer, so an owner can order a competing one behind it —
    /// `require(toFail:)` needs the object, and a caller that cannot see it
    /// has to duplicate the pan to get one.
    public private(set) weak var dismissalPan: UIPanGestureRecognizer?

    /// Which axes may begin a swipe, and the axis of the LIVE one (chosen per
    /// gesture from the hand's velocity, exactly like the zoom grab).
    ///
    /// Horizontal-only by default — the historical behaviour, and the right
    /// one for surfaces that own their vertical axis (a profile scrolls).
    /// The FEED surfaces opt into `.vertical` too now that the pager is
    /// forward-only: a text page dismisses downward the way a media page's
    /// hero does, so the two page kinds feel the same in the hand.
    private var axes: Set<ZoomDismissAxis> = [.horizontal]
    private var activeAxis: ZoomDismissAxis = .horizontal

    /// The reveal's own driver, live only while `revealGeometry` is set.
    ///
    /// Mutually exclusive with `interaction`: a percent driver scrubs one
    /// pre-baked animation, which is a rail, and the whole point of this one is
    /// that the window comes off the rail. See
    /// `RevealDismissInteractionController`.
    private var revealGrab: RevealDismissInteractionController?

    /// Installs the pan on the feed's view. Called once; the retained feed
    /// keeps its recognizer across pushes.
    public func attach(
        to feedViewController: UIViewController,
        axes: Set<ZoomDismissAxis> = [.horizontal]
    ) {
        guard self.feedViewController == nil else { return }
        self.feedViewController = feedViewController
        self.axes = axes
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        feedViewController.view.addGestureRecognizer(pan)
        dismissalPan = pan
    }

    /// Takes the stack's delegate slot for the feed's time on `nav`. The
    /// previous delegate is saved, not clobbered: `navigationController(_:didShow:)`
    /// hands the slot back the moment the feed is off the stack.
    /// Forgets everything the LAST presentation of this screen left behind.
    ///
    /// ⚠️ THIS DRIVER OUTLIVES THE SCREENS IT SERVES. It is one object, reused
    /// for every opening, and three separate defects have now come from a
    /// field surviving into the next one — each reported as a different broken
    /// animation, each traced back here:
    ///
    /// * the delegate capture. It is handed back by `didShow` when the screen
    ///   leaves the stack, and `didShow` does not always arrive: a live capture
    ///   shows a card-shaped close completing (`release commit=true`, row
    ///   restored) with none behind it. The next opening installed a fresh
    ///   flight this driver declined to notice, so a hero's pop tried to
    ///   forward to the PREVIOUS screen's controller, found nothing, and fell
    ///   through to its own animator — `kind=hero` and `reveal animate` on one
    ///   pop, the finger driving a grab while the window animated the close.
    /// * the preparation hook, which only the flight path sets. Left in place,
    ///   a WINDOW's close ran the flight path's preparation, which rebuilds the
    ///   geometry for a different post and clears it when it cannot — the trace
    ///   reads `kind=card geometry=false`, and a window closes as a flat slide.
    /// * the geometry and `revealPresents` alongside it, for the same reason.
    ///
    /// Called by whoever is about to PUSH, which is the one moment that is
    /// unambiguously a new life. A re-assert during the screen's life must NOT
    /// come through here: the capture is what makes a three-level unwind land
    /// on the right screen, and moving it there is its own bug.
    public func resetForNewPresentation() {
        hasCapturedSavedDelegate = false
        hasSeenFeedOnStack = false
        prepareForDismissal = nil
        revealGeometry = nil
        revealPresents = false
        revealReturnAxes = [.horizontal, .vertical]
        fallbackSlideAxis = nil
    }

    public func install(on nav: UINavigationController) {
        guard nav.delegate !== self else { return }
        // CAPTURED ONCE, and that distinction is the whole of a three-level
        // unwind working.
        //
        // Owners re-assert this on every appearance, because a child pushed
        // above them can take the delegate. But a re-assert happens while some
        // OTHER transition is still holding it — the one that presented the
        // child, moments from finishing — and capturing that as the delegate
        // to restore means handing back a controller whose screen is already
        // gone. Two levels hid it; on the third the restored controller drove
        // nothing and the grab froze, with the stack's delegate reading as a
        // perfectly healthy `ZoomTransitionController`.
        //
        // The first capture is the one that matters: whoever owned the stack
        // before this screen existed is who should own it again afterwards.
        if !hasCapturedSavedDelegate {
            savedDelegate = nav.delegate
            hasCapturedSavedDelegate = true
        }
        nav.delegate = self
        navigationController = nav
    }

    private func teardown() {
        if let nav = navigationController, nav.delegate === self {
            nav.delegate = savedDelegate
        }
        savedDelegate = nil
        hasCapturedSavedDelegate = false
        hasSeenFeedOnStack = false
        navigationController = nil
    }

    // MARK: - Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = feedViewController?.viewIfLoaded else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            // Direction was vetted in gestureRecognizerShouldBegin — claim
            // immediately so the screen is under the finger at frame 0.
            //
            // The touch's own position goes with it: how far this gesture CAN
            // travel is the distance from here to the edge, and a grab that
            // starts mid-screen has half the room of one that starts at the
            // bezel. See `RevealDismissInteractionController.sourceFade`.
            beginSwipe(from: gesture.location(in: view))
        case .changed:
            if let revealGrab {
                revealGrab.update(translation: translation, in: view)
            } else {
                interaction?.update(ZoomTransitionGeometry.dismissProgress(
                    translation: activeAxis.along(translation),
                    span: activeAxis.span(of: view.bounds.size)
                ))
            }
        case .ended, .cancelled:
            releaseSwipe(
                translation: translation,
                velocity: gesture.velocity(in: view),
                ended: gesture.state == .ended,
                in: view
            )
        default:
            break
        }
    }

    private func beginSwipe(from origin: CGPoint = .zero) {
        guard interaction == nil, revealGrab == nil,
              let nav = navigationController,
              let feed = feedViewController, nav.topViewController === feed else { return }
        // ⚠️ THE GEOMETRY IS ASKED FOR HERE, not carried from the opening.
        //
        // What a card-shaped close carries — the row's rect, the caption's cut,
        // the band, the stand-in — belongs to the post being DISMISSED, and on
        // a pager that is not always the post this screen opened with. The host
        // rebuilds it for whatever is on screen now; a host with nothing to
        // rebuild leaves it alone.
        //
        // Before the geometry is read three lines down, and that ordering is
        // the whole point: `onWillBeginPop` fires after the grab exists, which
        // is too late to decide what the grab is carrying.
        prepareForDismissal?(activeAxis)
        // Freeze the pager so a diagonal drag can't page mid-pop.
        (feed as? any ZoomTransitionDestination)?.setContentScrollEnabled(false)
        if let revealGeometry, revealReturnAxes.contains(activeAxis) {
            // A reveal is GRABBED, not scrubbed — the window floats free under
            // the finger the way a media hero's card does, and a percent driver
            // cannot express that.
            revealGrab = RevealDismissInteractionController(
                geometry: revealGeometry,
                returningChrome: revealReturningChrome,
                axis: activeAxis,
                grabOrigin: origin
            )
        } else {
            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            self.interaction = interaction
        }
        // The restaging window — see `onWillBeginPop`. Before the pop, so a
        // stack edit here is a plain transaction, not a mid-transition one.
        onWillBeginPop?(activeAxis)
        // Triggers the pop; the delegate below vends the slide animator and
        // this driver because `interaction` is now non-nil.
        nav.popViewController(animated: true)
    }

    private func releaseSwipe(translation: CGPoint, velocity: CGPoint, ended: Bool, in view: UIView) {
        // The retained feed outlives every pop — always thaw its scrolling.
        defer {
            (feedViewController as? any ZoomTransitionDestination)?.setContentScrollEnabled(true)
        }
        if let grab = revealGrab {
            revealGrab = nil
            // The grab owns its own threshold call: it is holding the pose the
            // spring starts from, so the decision and the animation belong
            // together rather than being taken here and posted across.
            grab.release(
                translation: translation, velocity: velocity, ended: ended, in: view
            )
            return
        }
        guard let interaction else { return }
        self.interaction = nil

        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: activeAxis.along(translation),
            span: activeAxis.span(of: view.bounds.size)
        )
        // The shared release contract — identical to the pin grab's, on
        // whichever axis this swipe travelled.
        let commit = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: progress, velocity: activeAxis.along(velocity)
        )
        commit ? interaction.finish() : interaction.cancel()
    }

    #if DEBUG
    /// Scripted swipe for sim recordings (`-feed-swipe-demo`): touch injection
    /// is impossible in the simulator, so this walks the exact
    /// begin/update/release path a finger drives. Whether it completes or
    /// springs back is decided by the same threshold logic as a real release.
    /// Returns whether the pop it started is actually being DRIVEN by the
    /// gesture, which is a different question from whether the screen went
    /// away.
    ///
    /// With no navigation delegate — or one that does not vend this driver —
    /// `popViewController` still pops, on UIKit's own animation. Depth changes,
    /// the screen leaves, and the harness sees success while a real finger
    /// would have watched the page jump instead of following. Checking
    /// `transitionCoordinator?.isInteractive` is what tells the two apart.
    @discardableResult
    public func debugPerformSwipe(
        peakProgress: CGFloat, axis: ZoomDismissAxis = .horizontal
    ) async -> Bool {
        guard let view = feedViewController?.viewIfLoaded else { return false }
        // Honour the owner's veto, exactly as a real touch would. Calling
        // `beginSwipe` straight through made this harness answer a different
        // question from the one a thumb asks: it dismissed a profile from a
        // tab whose drag belongs to the pager, and reported success.
        guard canBeginDismissal?() != false else { return false }
        // A real touch picks the axis in `gestureRecognizerShouldBegin`; this
        // harness has no velocity to be matched, so it says so directly — and
        // only for an axis the attach allowed, exactly like the begin gate.
        guard axes.contains(axis) else { return false }
        activeAxis = axis
        beginSwipe()
        let isDriven = feedViewController?.transitionCoordinator?.isInteractive == true
        let peak = peakProgress * axis.span(of: view.bounds.size)
        let steps = 30
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: 16_000_000)
            let t = CGFloat(step) / CGFloat(steps)
            let translation = axis.offset(along: peak * t, across: 0)
            if let revealGrab {
                revealGrab.update(translation: translation, in: view)
            } else {
                interaction?.update(ZoomTransitionGeometry.dismissProgress(
                    translation: peak * t, span: axis.span(of: view.bounds.size)
                ))
            }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        releaseSwipe(
            translation: axis.offset(along: peak, across: 0),
            velocity: .zero, ended: true, in: view
        )
        return isDriven
    }
    #endif
}

// MARK: - UINavigationControllerDelegate

extension InteractiveSlideDismissal: UINavigationControllerDelegate {
    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        // Every pop of OUR feed rides the slide animator — swipe-driven or
        // back-button. Not only for visual consistency: the manual tab-bar
        // restore in `didShow` is stomped by a NATIVE pop's own end-of-
        // transition bar bookkeeping (verified: the bar stayed hidden after a
        // back-button pop, while the same restore call held after custom
        // pops). The feed's push, and everything else on this stack, stay
        // native.
        // PROTOTYPE: the reveal is the only thing here that customizes a PUSH.
        // The slide never did — a text post arrived on UIKit's own slide —
        // which is exactly the gap this is measuring.
        if operation == .push, toVC === feedViewController, revealPresents,
           let revealGeometry {
            return RevealPresentAnimator(
                geometry: revealGeometry, departingChrome: revealReturningChrome
            )
        }
        guard operation == .pop, fromVC === feedViewController else { return nil }
        // ⚠️ A POP WITH NO GESTURE BEHIND IT still has to be prepared.
        //
        // A swipe passes through `beginSwipe`, which asks for this first. The
        // back button does not: it goes straight to the stack, and this is the
        // earliest moment anything of ours hears about it — still early enough,
        // since the animator below is built from the geometry it produces.
        // Idempotent by contract, because a swipe arrives here as well.
        //
        // `.horizontal` for a pop with no gesture: the back button means the
        // platform's own direction, and a swipe re-asks with its real axis a
        // moment earlier in `beginSwipe`.
        prepareForDismissal?(interaction != nil || revealGrab != nil ? activeAxis : .horizontal)
        // ⚠️ A POST THAT FLIES GOES BACK TO WHOEVER HELD THIS SLOT BEFORE US.
        //
        // This driver holds the delegate slot for the whole of the screen's
        // life, and it is no longer the only thing that can animate the screen
        // away: a pager's post may want a hero, whose driver is the delegate
        // this one displaced. Forwarding is how one slot serves two, and it is
        // asked of the POST rather than of who happens to be driving — a
        // back-button pop has no driver at all, and it must still leave as the
        // right kind.
        //
        // ⚠️ A DECLINED FORWARD IS NOT AN ANSWER — WHEN A GRAB IS LIVE.
        //
        // Forwarding used to return whatever the saved delegate said INCLUDING
        // nil, and nil is not "no opinion": it is UIKit's own default pop,
        // which is not interactive. A grab was created moments earlier in
        // `beginSwipe`, so the finger then drove nothing and the screen slid
        // away as if there had been no gesture at all. Filmed on a post opened
        // as a REVEAL from a place page and paged onto a photograph: that
        // screen has no flight behind it, so the delegate it displaced is the
        // page's own return to the MAP — a controller with nothing to say
        // about this pop, saying so, and being taken at its word.
        //
        // Narrowed to the live-driver case on purpose. A pop with no gesture —
        // the back button — keeps forwarding exactly as it did, nil included,
        // because there is nothing being driven that a decline could strand
        // and because the animator this would fall through to is chosen from a
        // geometry that a back-button pop never re-staged.
        if (fromVC as? any ZoomTransitionDestination)?.zoomDismissalKind == .hero,
           let savedDelegate {
            let forwarded = savedDelegate.navigationController?(
                navigationController, animationControllerFor: operation, from: fromVC, to: toVC
            )
            if forwarded != nil || (revealGrab == nil && interaction == nil) {
                return forwarded
            }
        }
        #if DEBUG
        // `-grab-log`: which animator a pop got, and why.
        //
        // A close that looks wrong on screen has three candidate causes that
        // are indistinguishable from the outside — the wrong driver answered,
        // the right one answered with no geometry, or the geometry was built
        // for the wrong post — and this names which.
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            let kind = (fromVC as? any ZoomTransitionDestination)?.zoomDismissalKind
            print("[pop] kind=\(kind.map(String.init(describing:)) ?? "none")"
                + " grab=\(revealGrab != nil) geometry=\(revealGeometry != nil)"
                + " interaction=\(interaction != nil)")
        }
        #endif
        // A live grab is the animation; anything with geometry in it would
        // stage a second flight over the same page. See `RevealGrabAnimator`.
        if revealGrab != nil { return RevealGrabAnimator() }
        // `interaction == nil` scopes the window-shaped close to pops with no
        // live slide behind them (the back button): a scrubbed swipe on an
        // axis `revealReturnAxes` excludes is a SLIDE by decision, and giving
        // it the window here would overrule the begin-time choice.
        if let revealGeometry, interaction == nil {
            return RevealPopAnimator(
                geometry: revealGeometry, returningChrome: revealReturningChrome
            )
        }
        // The axis is the live swipe's — unless the owner transposed it (see
        // `fallbackSlideAxis`). A back-button pop (no interaction) exits
        // horizontally, the platform's own direction.
        guard interaction != nil else { return TimelineSlidePopAnimator(axis: .horizontal) }
        return TimelineSlidePopAnimator(axis: fallbackSlideAxis ?? activeAxis)
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        // Ours only when one of ours is driving. An animator that came from the
        // saved delegate carries the saved delegate's interaction — pairing it
        // with this driver's would scrub someone else's flight.
        if let grab = revealGrab { return grab }
        if let interaction { return interaction }
        // ⚠️ AND AN ANIMATOR THIS DRIVER BUILT IS NEVER DRIVEN BY ANYONE ELSE.
        //
        // Forwarding unconditionally asks the displaced delegate to drive OUR
        // animation, and a flight controller answers that question about its
        // own flights: it can hand back an interaction controller which then
        // stages a hero of its own and waits for a finger that does not exist.
        // The pop starts, nothing advances it, and it never completes — a dim
        // left over the grid, the closed post's navigation bar still up, and
        // the row this driver concealed for the close hidden for good.
        //
        // Measured on a back-button close of a text post reached by paging: the
        // animator was ours, the interaction was not, and neither `animate` nor
        // any completion ever ran.
        if animationController is RevealPopAnimator
            || animationController is RevealPresentAnimator
            || animationController is TimelineSlidePopAnimator {
            return nil
        }
        return savedDelegate?.navigationController?(
            navigationController, interactionControllerFor: animationController
        )
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // ⚠️ FORWARDED FIRST, and unconditionally: this is a NOTIFICATION, not
        // a choice.
        //
        // Displacing a delegate takes its `animationControllerFor` — which this
        // driver answers or forwards — and silently takes its news as well. The
        // driver it displaced keeps its own bookkeeping on this call (a flight
        // controller releases the interruptor that served the flight just
        // ended), and losing it leaks that state for the life of the screen.
        //
        // Before the teardown below, which hands the slot back and forgets who
        // to forward to.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-grab-log") {
            print("[pop] didShow \(type(of: viewController))")
        }
        #endif
        savedDelegate?.navigationController?(
            navigationController, didShow: viewController, animated: animated
        )
        // Completed transitions only (a cancelled swipe reports nothing): once
        // the feed is off the stack, hand the delegate slot back.
        let feedStillOnStack = feedViewController.map {
            navigationController.viewControllers.contains($0)
        } ?? false
        // ⚠️ ONLY A FEED THAT HAS BEEN SEEN ON THE STACK CAN BE POPPED OFF IT.
        //
        // `didShow` for an EARLIER, unrelated transition can be delivered in
        // the window between this driver taking the delegate slot and its feed
        // actually being pushed — measured with a gallery pushed
        // `animated:false` whose deferred `didShow` landed during the very
        // `presentSnapFeedHero` that was arming the escape. "Not on the stack"
        // then meant "not YET", but this read it as "popped": it tore down,
        // fired `onFeedPopped`, and that closure wiped the flight's retainer —
        // the transition controller deallocated before its push even began,
        // leaving the pushed post with no grab and the tab bar restored over
        // it. Seen-then-gone is the only sequence that means a pop.
        if feedStillOnStack {
            hasSeenFeedOnStack = true
        } else if hasSeenFeedOnStack {
            teardown()
            onFeedPopped?(navigationController)
        }
    }
}

// MARK: - Direction and coexistence

extension InteractiveSlideDismissal: UIGestureRecognizerDelegate {
    /// Mirrors the pin grab's conflict story: begin only for a rightward,
    /// predominantly horizontal movement, so the feed's vertical paging and
    /// pull-to-refresh never see a competitor.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard interaction == nil,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let feed = feedViewController, let view = feed.viewIfLoaded,
              let nav = navigationController, nav.topViewController === feed,
              // `topViewController` is already the feed while a pop ABOVE it is
              // still animating (reachable since the native edge swipe works on
              // pushed profiles/details): beginning here would call
              // `popViewController` mid-transition — undefined, and it can
              // strand the percent driver. Refuse; the next swipe retries.
              nav.transitionCoordinator == nil
        else { return false }
        if let destination = feed as? any ZoomTransitionDestination,
           !destination.isReadyForInteractiveDismissal { return false }
        // ⚠️ AND ONLY FOR A POST THAT TRAVELS AS A CARD — the mirror of the
        // hero grab's gate, asked of the same authority.
        //
        // Both drivers can be attached to one screen now, because a pager's
        // post may not be the kind the tap installed for. Each refuses the
        // other's half, so exactly one claims any given grab. A destination
        // with no opinion answers `.hero`, which is why this asks for `.card`
        // rather than "not hero": this driver also serves screens that fly
        // nothing at all, and they must keep claiming drags as they did.
        if arbitratesWithHeroGrab,
           (feed as? any ZoomTransitionDestination)?.zoomDismissalKind != .card {
            return false
        }
        if let canBeginDismissal, !canBeginDismissal() { return false }
        guard let axis = ZoomDismissAxis.match(velocity: pan.velocity(in: view), axes: axes)
        else { return false }
        // Same extra gate as the zoom grab's vertical leg: subsurfaces that
        // own their vertical gestures (a text page's comment stream, the
        // shortcut rail) keep their touches.
        if axis == .vertical,
           let destination = feed as? any ZoomTransitionDestination,
           !destination.zoomVerticalDismissalPermitted(at: pan.location(in: view), in: view) {
            return false
        }
        activeAxis = axis
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true // coexist with the pager's pan; we self-gate by direction above
    }
}

// MARK: - Animator

/// The pop leg the swipe scrubs: a native-style slide — the feed exits along
/// the swipe's axis (rightward, or downward for the forward-only feed's
/// vertical swipe) at 1:1 while the underlying screen advances from its
/// parallax offset under a fading dim. Linear inside, so scrubbed progress
/// tracks the finger; the percent driver's completion curve eases the
/// remainder on release.
private final class TimelineSlidePopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// How far (fraction of the travel span) the underlying screen sits
    /// shifted against the exit direction before the pop reveals it — the
    /// native parallax depth, applied on whichever axis the exit travels.
    private let parallax: CGFloat = 0.3
    private let axis: ZoomDismissAxis

    init(axis: ZoomDismissAxis = .horizontal) {
        self.axis = axis
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0.35
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let fromView = context.view(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        toView.frame = context.finalFrame(for: toVC)
        container.insertSubview(toView, belowSubview: fromView)

        let dim = UIView(frame: toView.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        toView.addSubview(dim)

        // Bezel-matched corner rounding, SET (not animated) at frame 0: at
        // rest the clipped corners sit exactly behind the device's own
        // rounded bezel, so the mask is invisible until the slide carries the
        // view away from it — no entry animation to jump, and (crucially)
        // nothing for the percent driver's frozen layer clock to strand
        // mid-value during a scrub. The radius is a static model value for
        // the transition's whole life. A plain cornerRadius clip with no
        // shadow composites on the GPU without an offscreen pass, so the
        // 1:1 tracking stays cheap.
        let radius = ScreenGeometry.cornerRadius(behind: fromView)
        if radius > 0 {
            fromView.layer.cornerCurve = .continuous
            fromView.layer.cornerRadius = radius
            fromView.layer.masksToBounds = true
        }

        let span = axis.span(of: container.bounds.size)
        let entry = axis.offset(along: -span * parallax, across: 0)
        let exit = axis.offset(along: span, across: 0)
        toView.transform = CGAffineTransform(translationX: entry.x, y: entry.y)
        UIView.animate(
            withDuration: transitionDuration(using: context),
            delay: 0,
            options: [.curveLinear]
        ) {
            fromView.transform = CGAffineTransform(translationX: exit.x, y: exit.y)
            toView.transform = .identity
            dim.alpha = 0
        } completion: { _ in
            dim.removeFromSuperview()
            fromView.transform = .identity
            toView.transform = .identity
            if context.transitionWasCancelled {
                // The feed is back at full screen, where the rounding hides
                // behind the bezel again — animate it off anyway so the
                // retained view carries no mask outside dismissals.
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
                    fromView.layer.cornerRadius = 0
                } completion: { _ in
                    fromView.layer.masksToBounds = false
                }
            } else {
                // Committed: the view held the bezel radius to its last
                // on-screen frame; it is unparented now, so reset silently
                // for the retained feed's next push.
                fromView.layer.cornerRadius = 0
                fromView.layer.masksToBounds = false
            }
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}
