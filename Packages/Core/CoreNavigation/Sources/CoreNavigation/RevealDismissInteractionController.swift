import UIKit

/// Turns a drag on a text page into a *free-floating* grab of the reveal's
/// window — the same hand-feel the media hero has, on a page that has no media
/// to fly.
///
/// ## Why not the percent driver it replaces
///
/// The reveal's close was scrubbed by `UIPercentDrivenInteractiveTransition`,
/// which plays ONE pre-baked animation forwards and backwards. Everything it
/// touches is therefore a function of a single scalar — the window's size, its
/// position, its rounding, all locked to each other on a rail. You can move it
/// along the rail, you cannot hold it. A media post, grabbed on the same
/// screen, floats free in two dimensions. Two page kinds, two different hands.
///
/// So this implements `UIViewControllerInteractiveTransitioning` directly and
/// splits the drag the way `ZoomDismissInteractionController` does:
///
/// - **Position** (2D, free): the window's CENTRE is set on every pan event —
///   rubber-banded along the axis and across it — so it floats under the finger
///   with no lag and no animation in flight.
/// - **Morph** (progress-driven): the window's SIZE and rounding interpolate
///   toward the card's, and dim, veil, presenter depth and returning chrome are
///   pure functions of `translation / span`.
///
/// Release then springs from the window's exact current pose to the card's rect
/// (commit) or back to the whole screen (cancel), seeded with the hand's
/// velocity, so the window is visibly caught rather than restarted.
///
/// ## What the window does NOT do — with one exception
///
/// It does not scale its contents when it is landing on a CARD. The media grab
/// shrinks a card and the picture inside it shrinks too, which is right for a
/// picture; doing that to text would shrink the type on the way down and then
/// have to restore it at the landing, against a card whose type is at 1:1 — the
/// exact class of last-frame pop this transition spent five rounds eliminating.
/// The window's WIDTH goes to the card's width and its HEIGHT collapses, the
/// type stays put, and the veil covers what no longer fits.
///
/// ⚠️ THE EXCEPTION IS A LANDING THAT IS NOT A CARD. A 44pt map marker draws
/// none of the page's type, so there is no 1:1 type to pop against and the
/// argument above has nothing to protect: what it protects instead is a
/// keyhole, a full-size page clipped down to a disc showing one corner of
/// itself. Such a landing sets `RevealGeometry.pageFit` and the page
/// travels whole, scaled — see `RevealStage.pageCovering`. Everywhere there IS
/// a card to pop against, the rule above still holds, and it is the default.
@MainActor
final class RevealDismissInteractionController: NSObject,
                                                UIViewControllerInteractiveTransitioning {
    private let geometry: RevealGeometry
    private weak var returningChrome: UIView?
    /// The axis this grab travels, chosen from the hand's velocity before the
    /// gesture began and fixed for its lifetime — as the zoom grab does.
    private let axis: ZoomDismissAxis

    /// Whether a grab is currently driving; the delegate vends this controller
    /// only while true.
    private(set) var isInteracting = false

    // Live state, populated by startInteractiveTransition and dropped when the
    // release animation has settled.
    private var context: (any UIViewControllerContextTransitioning)?
    private var host: UIView?
    private var windowMask: UIView?
    private weak var page: UIView?
    private var pageFrame: CGRect = .zero
    private var dim: UIView?
    private weak var presentingView: UIView?
    private var screenRadius: CGFloat = 0
    private var openRect: CGRect = .zero
    private var openCentre: CGPoint = .zero
    /// The page's caption row on the full-size page, in container space. The
    /// window's content registration is derived from it; `nil` in plain mode,
    /// where the page never moves.
    private var anchor: CGRect?
    /// The rect the window is flying at, re-read on every pan event for the
    /// reason the zoom grab re-reads its own: a grab can be held for seconds,
    /// and anything that moves the row underneath is then absorbed
    /// continuously instead of surfacing as a correction at release.
    private var stagedLanding: CGRect = .zero
    /// The card the window carries home — see
    /// `RevealGeometry.makeDismissStandIn`.
    private var standIn: UIView?

    /// The row's rect in the container, read with the presenter momentarily at
    /// IDENTITY — which is the space the window's own mask lives in.
    ///
    /// The presenter is part-way through its depth recede for most of a grab,
    /// and reading through that transform hands back a rect skewed by whatever
    /// scale the finger happens to be at. Measured: a 343x145 row came back as
    /// 325.85x137.75 mid-drag and 335.28x141.74 at release — so the window was
    /// morphing toward a target that shrank as the grab deepened, and the
    /// spring landed on a rect 8pt narrower than the card it was supposed to
    /// become. The spring returns the presenter to identity by landing time, so
    /// identity is the only frame of reference that is true at the end.
    ///
    /// The toggle is confined to one transaction, so nothing can render it.
    private func currentLanding(in container: UIView) -> CGRect {
        let recede = presentingView?.transform ?? .identity
        presentingView?.transform = .identity
        defer { presentingView?.transform = recede }
        return geometry.sourceFrame(container) ?? RevealStage.centredFallback(in: container)
    }

    init(
        geometry: RevealGeometry,
        returningChrome: UIView?,
        axis: ZoomDismissAxis
    ) {
        self.geometry = geometry
        self.returningChrome = returningChrome
        self.axis = axis
    }

    // MARK: - UIViewControllerInteractiveTransitioning

    /// Stages exactly what `RevealPopAnimator` stages — host, mask, dim, veil,
    /// ground, receded presenter — and then starts NOTHING. The drag owns the
    /// pose frame by frame from here.
    func startInteractiveTransition(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to)
        else {
            context.completeTransition(false)
            return
        }
        pageFrame = fromView.frame
        toView.frame = context.finalFrame(for: toVC)
        container.insertSubview(toView, belowSubview: fromView)

        // The landing measured LAST, after the owner has had its chance to
        // scroll the row back or pin the grid's inset. Asked before the rect is
        // read, never after.
        geometry.willStageDismissal()
        container.layoutIfNeeded()
        anchor = geometry.anchorFrame(container)
        stagedLanding = geometry.sourceFrame(container)
            ?? RevealStage.centredFallback(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let (host, mask) = RevealStage.makeHost(
            around: fromView, in: container, pageFrame: pageFrame
        )
        let open = RevealStage.open(container: container)
        // See `RevealGeometry.makeDismissStandIn`: what a dismissal carries
        // home is the card, not the page it was read from.
        let standIn = geometry.makeDismissStandIn()
        if let standIn {
            host.addSubview(standIn)
            standIn.alpha = RevealStage.fill(at: 0, covering: geometry.pageFit == .covering)
            (standIn as? RevealStandInShaping)?.setContentOpacity(
                RevealStage.contentOpacity(at: 0, covering: geometry.pageFit == .covering)
            )
        }
        self.standIn = standIn
        // ⚠️ THE LANDING GOES AWAY FOR THE WHOLE CLOSE, exactly as the opening
        // hides the row it grew out of. The window is bigger than the cell for
        // most of the trip, so a cell left showing is a SECOND copy of the post
        // sitting beside the one under the finger. Only the opening leg used to
        // do this; the close set the flag back at `finish` and never set it in
        // the first place, so on a grid landing the tile stayed visible the
        // whole way down. Filmed.
        //
        // Released in `finish(cancelled:)`, which already runs
        // `setSourceConcealed(cancelled)` in the same transaction as the
        // unwrap — the cell and the window are identical at the landing rect,
        // so swapping them there is invisible.
        geometry.setSourceConcealed(true)
        RevealStage.apply(open, mask: mask, page: fromView, standIn: standIn)
        openRect = open.mask
        openCentre = CGPoint(x: open.mask.midX, y: open.mask.midY)
        screenRadius = open.maskRadius

        geometry.setDestinationGround(nil)
        installVeil(geometry: geometry, anchor: anchor)
        installAuthorBand(geometry: geometry, anchor: anchor)
        geometry.setDestinationVeilOpacity(0)
        geometry.setDestinationAuthorBandOpacity(0)

        let presenting = geometry.depthView() ?? toView
        ZoomFlight.applyRecededChrome(to: presenting, radius: screenRadius)
        presenting.transform = CGAffineTransform(
            scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
        )
        returningChrome?.alpha = 0

        self.context = context
        self.host = host
        self.windowMask = mask
        self.page = fromView
        self.dim = dim
        self.presentingView = presenting

        #if DEBUG
        RevealStage.log("grab", "staged landing=\(NSCoder.string(for: stagedLanding))"
            + " anchor=\(anchor.map(NSCoder.string(for:)) ?? "nil")"
            + " axis=\(axis)")
        #endif

        isInteracting = true
        context.updateInteractiveTransition(0)
    }

    // MARK: - Drag

    /// The window's pose for a translation. Both channels, one function, so
    /// the release can ask for the pose it is springing FROM by the same rule
    /// the drag has been applying.
    private func pose(for translation: CGPoint, in view: UIView) -> (pose: RevealStage.Pose, progress: CGFloat) {
        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: axis.along(translation), span: axis.span(of: view.bounds.size)
        )
        // Position: free 2D float, decomposed along the LIVE axis. Travel and
        // back-drag rubber-band along it, drift rubber-bands across it — so the
        // window follows the hand but resists leaving the dismissal axis.
        let along = axis.along(translation)
        let bandedAlong = along >= 0
            ? ZoomTransitionGeometry.rubberBand(
                along,
                limit: ZoomTransitionGeometry.forwardDragLimit(
                    forSpan: axis.span(of: view.bounds.size)
                )
            )
            : ZoomTransitionGeometry.rubberBand(along, limit: ZoomTransitionGeometry.backDragLimit)
        let bandedAcross = ZoomTransitionGeometry.rubberBand(
            axis.across(translation), limit: ZoomTransitionGeometry.crossDriftLimit
        )
        let offset = axis.offset(along: bandedAlong, across: bandedAcross)

        // Morph: toward the card's own size and rounding — or, against a
        // landing that is not a card, not at all: see the note below.
        // A held window keeps the screen's SHAPE and its opacity, and only its
        // size and position answer the finger — see `RevealStage.heldWindow`.
        let size = CGSize(
            width: openRect.width + (stagedLanding.width - openRect.width) * progress,
            height: openRect.height + (stagedLanding.height - openRect.height) * progress
        )
        let centre = CGPoint(x: openCentre.x + offset.x, y: openCentre.y + offset.y)
        let rect = geometry.pageFit == .clipped
            ? CGRect(
                x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                width: size.width, height: size.height
            )
            : RevealStage.heldWindow(openRect, displacedBy: offset, at: progress)
        // The screen's own corner at the screen's own proportion — see
        // `RevealStage.heldRadius`. The landing's arrives on the release
        // spring, which already carries it.
        let radius = geometry.pageFit == .clipped
            ? screenRadius + (geometry.sourceCornerRadius - screenRadius) * progress
            : RevealStage.heldRadius(screenRadius, at: progress)
        // ⚠️ THE LIVE RECT, not a progress-derived size — the same rect the
        // window is being given, so the page cannot separate from it under a
        // rubber-banded or back-dragged finger.
        if geometry.pageFit != .clipped {
            let covering = RevealStage.pageFitting(rect, from: openRect, fit: geometry.pageFit)
            return (
                RevealStage.Pose(
                    mask: rect,
                    maskRadius: radius,
                    pageTranslation: covering.translation,
                    pageScale: covering.scale
                ),
                progress
            )
        }
        let staged = RevealStage.Pose(
            mask: rect,
            maskRadius: radius,
            // A stand-in changes what the page is FOR: it is no longer what
            // the window shows, it is what the window is carrying. So it rides
            // — moving with the window, rigidly — rather than registering
            // against a caption nobody is going to see. Registering was the
            // "scroll" artifact; holding still would have been a worse one,
            // the window travelling under the finger while its contents stay
            // nailed to the screen. See `RevealStage.pageRiding`.
            pageTranslation: standIn != nil
                ? RevealStage.pageRiding(rect, from: openRect)
                : RevealStage.pageTranslation(
                    carrying: rect,
                    anchor: geometry.matchesAnchor ? anchor : nil,
                    progress: progress,
                    captionTop: geometry.sourceCaptionTop
                )
        )
        return (staged, progress)
    }

    func update(translation: CGPoint, in view: UIView) {
        guard isInteracting, let context, let windowMask, let page else { return }
        // Re-read the target every event; see `stagedLanding`.
        stagedLanding = currentLanding(in: context.containerView)

        let staged = self.pose(for: translation, in: view)
        RevealStage.apply(staged.pose, mask: windowMask, page: page, standIn: standIn)
        // The swap, on the finger's own channel and with an empty beat in the
        // middle of it — see `RevealStage.swapFractions`. Direct sets, like
        // every other value the drag owns: an interactive transition's start
        // runs where `UIView.animate` applies without animating, and the timed
        // version this replaces lost its second half to exactly that.
        if let standIn {
            standIn.alpha = RevealStage.fill(
                at: staged.progress, covering: geometry.pageFit == .covering
            )
            (standIn as? RevealStandInShaping)?.setContentOpacity(
                RevealStage.contentOpacity(
                    at: staged.progress, covering: geometry.pageFit == .covering
                )
            )
        }

        let pose = staged
        dim?.alpha = 1 - pose.progress
        // The veil closes on the same channel as the dim: the further home the
        // window is, the less of itself the page may show past what the card
        // shows.
        geometry.setDestinationVeilOpacity(pose.progress)
        // The borrowed band arrives on the same channel: the closer the window
        // is to being the card, the more of the card it has to be showing.
        geometry.setDestinationAuthorBandOpacity(pose.progress)
        // And the source's own chrome arrives on the mirror of it, revealed by
        // the hand rather than switched on after the landing.
        returningChrome?.alpha = pose.progress
        let depth = ZoomFlight.presenterDepthScale
            + (1 - ZoomFlight.presenterDepthScale) * pose.progress
        presentingView?.transform = CGAffineTransform(scaleX: depth, y: depth)
        context.updateInteractiveTransition(pose.progress)
    }

    // MARK: - Release

    func release(translation: CGPoint, velocity: CGPoint, ended: Bool, in view: UIView) {
        guard isInteracting, let context, let windowMask, let page else { return }
        isInteracting = false

        let held = self.pose(for: translation, in: view)
        let pose = held
        // The shared release contract, so a text page and a media page commit
        // on the same fraction of span and the same flick.
        let commit = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: pose.progress, velocity: axis.along(velocity)
        )
        // Reported NOW, at release — the framework's contract for the end of
        // the user-driven phase, and what lets UIKit run its own coordinated
        // choreography on its own clock.
        commit ? context.finishInteractiveTransition() : context.cancelInteractiveTransition()

        // Read once more at release, so the spring ends on the rect the drag
        // was already aiming at and there is nothing left to correct.
        let container = context.containerView
        let landing = commit ? currentLanding(in: container) : openRect
        let closed = RevealStage.closed(
            sourceRect: landing,
            radius: geometry.sourceCornerRadius,
            anchor: anchor,
            matchesAnchor: geometry.matchesAnchor,
            captionTop: geometry.sourceCaptionTop,
            ridingFrom: standIn != nil ? openRect : nil,
            fit: geometry.pageFit
        )
        let target = commit
            ? closed
            : RevealStage.Pose(
                mask: openRect, maskRadius: screenRadius, pageTranslation: .zero
            )
        // (An abandoned grab returns the window to the whole screen, where
        // riding and still are the same thing: zero displacement.)

        // ⚠️ THE ARRIVAL WAITS FOR THE PAGE TO FINISH LEAVING.
        //
        // On a fit that carries the page, the release is the FIRST moment
        // anything of the destination may be seen — that is the whole of what
        // the drag's silence buys. Even here the two may not overlap: a card's
        // text over a page's caption is the "two half-drawn runs" this
        // transition has paid for four times. So the page's own fade rides the
        // spring below and the arrival is a second, delayed block over the tail
        // of it, on the same schedule the chevron leg uses.
        if let standIn, geometry.pageFit != .clipped {
            let span = RevealStage.springDuration * RevealStage.springVisibleFraction
            UIView.animate(
                withDuration: span * (1 - RevealStage.cardFadeStart),
                delay: span * RevealStage.cardFadeStart,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                standIn.alpha = commit ? 1 : 0
            }
        }

        let springVelocity = ZoomTransitionGeometry.springVelocity(
            of: velocity,
            from: CGPoint(x: held.pose.mask.midX, y: held.pose.mask.midY),
            to: CGPoint(x: target.mask.midX, y: target.mask.midY)
        )
        #if DEBUG
        RevealStage.log("release", "commit=\(commit) progress=\(String(format: "%.2f", pose.progress))"
            + " from=\(NSCoder.string(for: held.pose.mask)) to=\(NSCoder.string(for: target.mask))")
        #endif

        let dim = dim
        let chrome = returningChrome
        let presenting = presentingView
        let depth = ZoomFlight.presenterDepthScale
        // The SAME spring the tap-back close now wears, so a released grab and
        // a chevron land with identical physics; only the seeded velocity
        // differs, which is what makes the window feel caught.
        UIView.animate(
            withDuration: RevealStage.springDuration, delay: 0,
            usingSpringWithDamping: RevealStage.springDamping,
            initialSpringVelocity: springVelocity,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            RevealStage.apply(target, mask: windowMask, page: page, standIn: self.standIn)
            // The release finishes whatever fraction the drag reached: a
            // committed grab lands on the card whole, an abandoned one hands
            // the page back and the stand-in goes, fill and card together.
            //
            // ⚠️ The COMMITTED branch is not optional. Leaving it out was the
            // abrupt last frame: nothing set the card's opacity on a commit, so
            // it stayed at whatever the drag had reached — often zero — and the
            // card appeared only when the stand-in was retired.
            // ⚠️ NOT IN THIS BLOCK on a fit that carries the page — see the
            // scheduled fade below. The page is still leaving here, and running
            // the arrival up on the same clock cross-fades two drawings that
            // both have text on them, which is the one thing this transition
            // may never do.
            if self.geometry.pageFit == .clipped { self.standIn?.alpha = commit ? 1 : 0 }
            // Pinned under a carried page: only the view's alpha may move, so
            // an abandoned grab leaves the face at 0 with its content still 1.
            (self.standIn as? RevealStandInShaping)?.setContentOpacity(
                self.geometry.pageFit == .clipped ? (commit ? 1 : 0) : 1
            )
            dim?.alpha = commit ? 0 : 1
            chrome?.alpha = commit ? 1 : 0
            self.geometry.setDestinationVeilOpacity(commit ? 1 : 0)
            self.geometry.setDestinationAuthorBandOpacity(commit ? 1 : 0)
            // Into the card's tone on the way home, so the last frame of the
            // close and the row underneath are one colour; back to the page's
            // own if the grab is abandoned.
            self.geometry.setDestinationGround(commit ? self.geometry.sourceFill : nil)
            presenting?.transform = commit
                ? .identity
                : CGAffineTransform(scaleX: depth, y: depth)
        }
        // Teardown follows the ANIMATION, not the wall clock — see
        // `whenViewSettles`.
        whenViewSettles(windowMask, ceiling: viewSettleCeiling) { [weak self] in
            self?.finish(cancelled: !commit)
        }
    }

    /// Tears the stage down exactly as `RevealPopAnimator`'s completion does,
    /// then reports to UIKit and drops all state.
    private func finish(cancelled: Bool) {
        #if DEBUG
        RevealStage.log("grab", "finish cancelled=\(cancelled)")
        #endif
        // FIRST, and the order is the whole of it: the row and the window are
        // identical at the landing rect, so swapping them inside one
        // transaction is invisible — while restoring after the unwrap is a
        // frame of empty grid where the card should be.
        geometry.setSourceConcealed(cancelled)
        standIn?.removeFromSuperview()
        standIn = nil
        if let page, let host, let container = context?.containerView {
            RevealStage.unwrap(page, from: host, to: container, frame: pageFrame)
        }
        dim?.removeFromSuperview()
        presentingView?.transform = .identity
        ZoomFlight.clearRecededChrome(from: presentingView)
        // The page is staying or going; either way it must carry no mask into
        // its life on the stack — the feed is retained and pushed again.
        page?.layer.mask = nil
        // A cancelled close leaves the page on screen, so it owns its ground
        // again; a committed one is leaving, and the retained feed must not
        // carry a borrowed colour into its next push.
        geometry.setDestinationGround(nil)
        geometry.installDestinationVeil(nil, nil)
        geometry.installDestinationAuthorBand(nil)
        returningChrome?.alpha = cancelled ? 0 : 1
        geometry.dismissalDidEnd(!cancelled)
        context?.completeTransition(!cancelled)
        context = nil
        host = nil
        windowMask = nil
        page = nil
        dim = nil
        presentingView = nil
    }

    #if DEBUG
    /// Scripted grab for sim recordings (`-text-grab-demo`): touch injection is
    /// impossible in the simulator, so this walks the exact
    /// begin/update/release path a finger drives — a drag to (`peakProgress` ×
    /// span, `drift` across it), a hold, then a release decided by the same
    /// threshold logic a real one is.
    func debugPerformGrab(
        peakProgress: CGFloat, drift: CGFloat, in view: UIView, steps: Int = 24
    ) async {
        let span = axis.span(of: view.bounds.size)
        let peak = axis.offset(along: peakProgress * span, across: drift)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            update(
                translation: CGPoint(x: peak.x * fraction, y: peak.y * fraction), in: view
            )
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        release(translation: peak, velocity: .zero, ended: true, in: view)
    }
    #endif
}
