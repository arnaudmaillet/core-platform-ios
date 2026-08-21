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
/// ## What the window does NOT do
///
/// It never scales its contents. The media grab shrinks a card and the picture
/// inside it shrinks too, which is right for a picture; doing that to text
/// would shrink the type on the way down and then have to restore it at the
/// landing, against a card whose type is at 1:1 — the exact class of last-frame
/// pop this transition spent five rounds eliminating. The window's WIDTH goes
/// to the card's width and its HEIGHT collapses, the type stays put, and the
/// veil covers what no longer fits. Same reason the close has always worked.
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

    init(geometry: RevealGeometry, returningChrome: UIView?, axis: ZoomDismissAxis) {
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
        RevealStage.apply(open, mask: mask, page: fromView)
        openRect = open.mask
        openCentre = CGPoint(x: open.mask.midX, y: open.mask.midY)
        screenRadius = open.maskRadius

        geometry.setDestinationGround(nil)
        installVeil(geometry: geometry, anchor: anchor)
        geometry.setDestinationVeilOpacity(0)

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
            ? ZoomTransitionGeometry.rubberBand(along, limit: ZoomTransitionGeometry.forwardDragLimit)
            : ZoomTransitionGeometry.rubberBand(along, limit: ZoomTransitionGeometry.backDragLimit)
        let bandedAcross = ZoomTransitionGeometry.rubberBand(
            axis.across(translation), limit: ZoomTransitionGeometry.crossDriftLimit
        )
        let offset = axis.offset(along: bandedAlong, across: bandedAcross)

        // Morph: toward the card's own size and rounding.
        let size = CGSize(
            width: openRect.width + (stagedLanding.width - openRect.width) * progress,
            height: openRect.height + (stagedLanding.height - openRect.height) * progress
        )
        let centre = CGPoint(x: openCentre.x + offset.x, y: openCentre.y + offset.y)
        let rect = CGRect(
            x: centre.x - size.width / 2, y: centre.y - size.height / 2,
            width: size.width, height: size.height
        )
        let radius = screenRadius + (geometry.sourceCornerRadius - screenRadius) * progress
        let staged = RevealStage.Pose(
            mask: rect,
            maskRadius: radius,
            pageTranslation: RevealStage.pageTranslation(
                carrying: rect,
                anchor: geometry.matchesAnchor ? anchor : nil,
                progress: progress
            )
        )
        return (staged, progress)
    }

    func update(translation: CGPoint, in view: UIView) {
        guard isInteracting, let context, let windowMask, let page else { return }
        // Re-read the target every event; see `stagedLanding`.
        stagedLanding = currentLanding(in: context.containerView)

        let staged = self.pose(for: translation, in: view)
        RevealStage.apply(staged.pose, mask: windowMask, page: page)

        let pose = staged
        dim?.alpha = 1 - pose.progress
        // The veil closes on the same channel as the dim: the further home the
        // window is, the less of itself the page may show past what the card
        // shows.
        geometry.setDestinationVeilOpacity(pose.progress)
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
            matchesAnchor: geometry.matchesAnchor
        )
        let target = commit
            ? closed
            : RevealStage.Pose(
                mask: openRect, maskRadius: screenRadius, pageTranslation: .zero
            )

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
            withDuration: ZoomFlight.springDuration, delay: 0,
            usingSpringWithDamping: ZoomFlight.springDamping,
            initialSpringVelocity: springVelocity,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            RevealStage.apply(target, mask: windowMask, page: page)
            dim?.alpha = commit ? 0 : 1
            chrome?.alpha = commit ? 1 : 0
            self.geometry.setDestinationVeilOpacity(commit ? 1 : 0)
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
