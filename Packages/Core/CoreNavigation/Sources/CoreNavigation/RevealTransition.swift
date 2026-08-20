import UIKit

/// **PROTOTYPE** (`-text-reveal`). A hero for a page that has no media to fly.
///
/// Every previous attempt at a text hero flew a *replica* of the row and made
/// it impersonate the destination, and all five of them died of the same
/// thing: a text page IS its comment stream — a hosted child controller with
/// its own self-sizing layout and its own safe area — and no stand-in can be
/// that. The artifacts were the symptoms (a skeleton in the photographed
/// still, a blank card, the wrong safe area, two captions, a caption floating
/// outside the card as it shrank); impersonation was the disease.
///
/// So this does not impersonate anything. The REAL destination is installed at
/// full size and laid out before the first frame, and what animates is the
/// *mask* it is seen through: a rounded rect that sweeps from the row's rect
/// to the whole screen. There is nothing to keep in step with the page,
/// because the thing on screen is the page.
///
/// ```
///   t=0                    t=0.5                  t=1
///   ┌───────────┐          ┌───────────────┐      ┌──────────────────┐
///   │ caption…  │  ──────► │ caption…      │ ───► │ caption…         │
///   └───────────┘          │ ▸ comment     │      │ ▸ comment        │
///    row-sized mask        └───────────────┘      │ ▸ comment        │
///    over the real page     the mask opens        └──────────────────┘
/// ```
///
/// Two channels ride one spring — the mask's `frame`/`cornerRadius`, and the
/// page's `transform`. Neither touches the page's layout, which is what keeps
/// the caption exactly where it was measured (see `RevealStage`).
///
@MainActor
public struct RevealGeometry {
    /// The rect the window opens from / closes onto, in the given space.
    /// `nil` means the source is not on screen — the reveal falls back to a
    /// centred window, the same concession the hero makes.
    public let sourceFrame: (UICoordinateSpace) -> CGRect?
    /// The source's own rounding, so the mask starts as the row's twin.
    public let sourceCornerRadius: CGFloat
    /// The source's own FILL, worn by the destination for the length of the
    /// reveal and cross-faded back to the page's own ground.
    ///
    /// Geometry alone does not make a handshake. The mask was measured exactly
    /// on the card's rect — 16pt in, 370 wide, 18pt corners — and the opening
    /// still read as a full-width band, because what showed through it was the
    /// PAGE's ground (`.systemBackground`) where the card's
    /// (`.secondarySystemBackground`) had been. Two tones, one rect, no edge:
    /// the card appeared to vanish at the instant it was supposed to grow.
    ///
    /// `nil` leaves the destination's ground alone, which is the behaviour for
    /// a source that has no fill of its own to lend.
    public let sourceFill: UIColor?
    /// Lends the destination a ground, or hands its own back with `nil`.
    ///
    /// Driven rather than composited, and that is deliberate: an overlay in
    /// the card's colour would have to sit ABOVE the page to tint it, which
    /// puts it above the caption too — and the caption is the one thing that
    /// must be legible from the first frame. Painting the page's own ground
    /// has no such problem, cross-fades natively (`backgroundColor` is
    /// animatable), and scrubs under a finger.
    public let setDestinationGround: (UIColor?) -> Void
    /// Where the destination's caption bubble sits on the FULL-SIZE page.
    /// Matched mode aligns this with the source rect at t=0; `nil` (or plain
    /// mode) leaves the page unmoved and the window simply opens over it.
    public let anchorFrame: (UICoordinateSpace) -> CGRect?
    /// How far below the window's top edge the anchor is aimed — the source
    /// row's own caption inset, so the two captions start on the same line.
    public let anchorTopInset: CGFloat
    /// The view the depth cue recedes: the content, not the chrome around it.
    /// Same rule (and same reason) as `ZoomTransitionSource.zoomPresenterDepthView`.
    public let depthView: () -> UIView?
    /// Last chance to move before a dismissal measures its landing — the grid
    /// scrolling the row back into view, or pinning its content inset.
    public let willStageDismissal: () -> Void
    /// The close is over, WHICHEVER WAY IT WENT — `true` committed, `false`
    /// sprung back.
    ///
    /// Paired with `willStageDismissal` and fired on both outcomes, because
    /// the thing it undoes (a pinned content inset) is set on every dismissal
    /// and a cancelled swipe reports through no other channel. The hero learnt
    /// this the same way: its thaw hangs off `setZoomSourceHidden(false)`,
    /// which is likewise called on every ending.
    ///
    /// The outcome is a parameter and not two hooks because the caller's two
    /// jobs differ by exactly one thing — a cancelled close has to put back
    /// the source chrome it restored at grab-begin, and a committed one must
    /// not.
    public let dismissalDidEnd: (Bool) -> Void
    /// Whether the page counter-translates to match its caption to the row's
    /// (`true`), or simply sits still while the window opens over it
    /// (`false`). The prototype exposes both because the choice is a matter of
    /// taste that no argument settles — see `-text-reveal-plain`.
    public let matchesAnchor: Bool

    public init(
        sourceFrame: @escaping (UICoordinateSpace) -> CGRect?,
        sourceCornerRadius: CGFloat,
        sourceFill: UIColor? = nil,
        setDestinationGround: @escaping (UIColor?) -> Void = { _ in },
        anchorFrame: @escaping (UICoordinateSpace) -> CGRect? = { _ in nil },
        anchorTopInset: CGFloat = 0,
        depthView: @escaping () -> UIView? = { nil },
        willStageDismissal: @escaping () -> Void = {},
        dismissalDidEnd: @escaping (Bool) -> Void = { _ in },
        matchesAnchor: Bool = true
    ) {
        self.sourceFrame = sourceFrame
        self.sourceCornerRadius = sourceCornerRadius
        self.sourceFill = sourceFill
        self.setDestinationGround = setDestinationGround
        self.anchorFrame = anchorFrame
        self.anchorTopInset = anchorTopInset
        self.depthView = depthView
        self.willStageDismissal = willStageDismissal
        self.dismissalDidEnd = dismissalDidEnd
        self.matchesAnchor = matchesAnchor
    }
}

// MARK: - Shared staging

/// The mask and the two poses both legs interpolate between. Extracted so the
/// present and the pop are provably the same geometry read in opposite
/// directions, rather than two rect calculations that have to agree.
///
/// ## Why a mask, and why the page travels by TRANSFORM
///
/// The first build re-parented the page into a clipping wrapper whose frame
/// swept from the row to the screen. It measured correctly — the caption was
/// 16pt below the window's top edge by construction — and rendered wrongly:
/// at 60fps the opening window showed the page's COMMENT rows where its
/// caption should have been.
///
/// The cause is the one that killed the impersonation attempts, arriving by a
/// different door. **Safe area is computed from where a view actually is.** A
/// page re-parented into a 76pt window at the bottom of the screen resolves a
/// different safe area, `viewSafeAreaInsetsDidChange` fires, the comment
/// panel re-places itself, and the caption is no longer where it was
/// measured. Moving the page by `frame` does the same thing for the same
/// reason.
///
/// Both are avoided by never moving the page's LAYOUT:
///
/// * the host is full-screen and STATIC, so the page inside it resolves
///   exactly the safe area it would have resolved on its own;
/// * the clip is a `mask` on that host, so what changes is which part of the
///   page is drawn, not where the page is;
/// * the page's travel is a `transform`, which moves pixels and leaves bounds
///   — and therefore safe area, and therefore the caption — alone.
@MainActor
private enum RevealStage {
    /// `mask` is in container coordinates; `pageTranslation` is the page's
    /// vertical transform.
    struct Pose {
        let mask: CGRect
        let maskRadius: CGFloat
        let pageTranslation: CGFloat
    }

    /// The whole page, unmasked and untranslated — the landed pose, identical
    /// on both legs.
    static func open(container: UIView) -> Pose {
        Pose(
            mask: container.bounds,
            maskRadius: ScreenGeometry.cornerRadius(behind: container),
            pageTranslation: 0
        )
    }

    /// The page seen through the source's rect. `anchor` is the caption
    /// bubble's rect on the full-size page, in CONTAINER space.
    static func closed(
        sourceRect: CGRect,
        radius: CGFloat,
        anchor: CGRect?,
        anchorTopInset: CGFloat,
        matchesAnchor: Bool
    ) -> Pose {
        // Matched: the page is pushed down so its caption lands
        // `anchorTopInset` below the mask's top edge — where the row draws its
        // own caption, so the two occupy the same line at the handshake.
        // Plain: no travel at all, and the mask is a hole opening onto a page
        // that never moves.
        let translation: CGFloat = if matchesAnchor, let anchor {
            sourceRect.minY + anchorTopInset - anchor.minY
        } else {
            0
        }
        return Pose(mask: sourceRect, maskRadius: radius, pageTranslation: translation)
    }

    /// The static full-screen host and its mask. The page keeps the frame the
    /// transition context gave it; only the mask and the transform ever move.
    static func makeHost(
        around page: UIView, in container: UIView, pageFrame: CGRect
    ) -> (host: UIView, mask: UIView) {
        let host = UIView(frame: container.bounds)
        container.addSubview(host)
        host.addSubview(page)
        page.frame = pageFrame
        // Opaque, because a mask reads its alpha channel — a clear view masks
        // everything away, which is a blank screen rather than a clipped one.
        let mask = UIView()
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        host.mask = mask
        return (host, mask)
    }

    static func apply(_ pose: Pose, mask: UIView, page: UIView) {
        mask.frame = pose.mask
        mask.layer.cornerRadius = pose.maskRadius
        page.transform = CGAffineTransform(translationX: 0, y: pose.pageTranslation)
    }

    /// Puts `page` back where the transition context expects to find it and
    /// retires the host. Called on every outcome — committed, cancelled, or
    /// failed — because a page left inside a removed host is a blank screen.
    static func unwrap(_ page: UIView, from host: UIView, to container: UIView, frame: CGRect) {
        page.transform = .identity
        page.frame = frame
        container.addSubview(page)
        host.removeFromSuperview()
    }

    /// The rect to fall back to when the source is off screen: a small centred
    /// mask, so the page collapses toward the middle instead of onto a row
    /// nobody can see.
    static func centredFallback(in container: UIView) -> CGRect {
        ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: 96)
    }

    #if DEBUG
    static func log(_ leg: String, _ message: String) {
        guard ProcessInfo.processInfo.arguments.contains("-text-reveal-log") else { return }
        print(String(format: "[text-reveal] %.3f %@ %@", CACurrentMediaTime(), leg, message))
    }
    #endif
}

// MARK: - Present

/// The window opens. Non-interactive, and on the hero's own spring, so a text
/// post and a media post settle with identical physics.
@MainActor
final class RevealPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let geometry: RevealGeometry

    init(geometry: RevealGeometry) {
        self.geometry = geometry
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        ZoomFlight.springDuration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to)
        else {
            context.completeTransition(false)
            return
        }
        let pageFrame = context.finalFrame(for: toVC)

        // THE WHOLE POINT, and the reason none of the impersonation defects
        // can occur here: the destination is installed at full size and laid
        // out BEFORE anything is measured or posed. Its safe area is the real
        // one, its comment stream is really mounted, and its caption is the
        // only caption in existence — and it stays that way, because nothing
        // below moves its layout again.
        toView.frame = pageFrame
        container.addSubview(toView)
        container.layoutIfNeeded()

        let anchor = geometry.anchorFrame(container)
        let sourceRect = geometry.sourceFrame(container) ?? RevealStage.centredFallback(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        container.insertSubview(dim, belowSubview: toView)

        let (host, mask) = RevealStage.makeHost(
            around: toView, in: container, pageFrame: pageFrame
        )
        let closed = RevealStage.closed(
            sourceRect: sourceRect,
            radius: geometry.sourceCornerRadius,
            anchor: anchor,
            anchorTopInset: geometry.anchorTopInset,
            matchesAnchor: geometry.matchesAnchor
        )
        let open = RevealStage.open(container: container)
        RevealStage.apply(closed, mask: mask, page: toView)
        // The page wears the CARD before it wears itself. Set outside the
        // animation block so frame 0 is already the card's tone; the block
        // below hands the ground back, which cross-fades it.
        geometry.setDestinationGround(geometry.sourceFill)

        #if DEBUG
        RevealStage.log("present", "source=\(NSCoder.string(for: sourceRect))"
            + " anchor=\(anchor.map(NSCoder.string(for:)) ?? "nil")"
            + " travel=\(Int(closed.pageTranslation)) matched=\(geometry.matchesAnchor)")
        #endif

        // The grid recedes behind the opening mask — the same depth cue a hero
        // applies, on the content only, so the screen's own chrome stays
        // grounded.
        let presenting = geometry.depthView() ?? context.viewController(forKey: .from)?.view
        let screenRadius = ScreenGeometry.cornerRadius(behind: container)
        ZoomFlight.applyRecededChrome(to: presenting, radius: screenRadius)

        let duration = transitionDuration(using: context)
        // TAIL-WEIGHTED, on its own clock — the hero's `delayFactor: 0.35`,
        // reproduced here because the first capture showed why it exists: run
        // linearly with the mask, the dim had the grid at half black before
        // the page was a third open, so the surface the reveal is supposed to
        // be growing OUT of was gone by the time it had grown.
        UIView.animate(withDuration: duration * 0.65, delay: duration * 0.35, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: ZoomFlight.springDamping,
            initialSpringVelocity: ZoomFlight.springVelocity,
            options: [.allowUserInteraction]
        ) {
            RevealStage.apply(open, mask: mask, page: toView)
            // On the SAME spring as the mask, so the card does not become the
            // page a beat before or after it becomes the screen.
            self.geometry.setDestinationGround(nil)
            presenting?.transform = CGAffineTransform(
                scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
            )
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            // Idempotent close-out: the ground is already back by now, this
            // only guarantees it if the animation was interrupted.
            self.geometry.setDestinationGround(nil)
            RevealStage.unwrap(toView, from: host, to: container, frame: pageFrame)
            dim.removeFromSuperview()
            // Cleared under the opaque page, where the reset cannot be seen.
            presenting?.transform = .identity
            ZoomFlight.clearRecededChrome(from: presenting)
            context.completeTransition(!cancelled)
        }
    }
}

// MARK: - Pop

/// The window closes. Linear on purpose: this leg is what a finger scrubs, and
/// a percent driver tracks 1:1 only against a linear curve — the release
/// spring is the driver's own completion curve, not this one's.
@MainActor
final class RevealPopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let geometry: RevealGeometry
    /// Source chrome that comes back with the return (the app's tab bar), so
    /// it is revealed by the hand rather than switched on after the landing.
    private weak var returningChrome: UIView?

    init(geometry: RevealGeometry, returningChrome: UIView?) {
        self.geometry = geometry
        self.returningChrome = returningChrome
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        ZoomFlight.springDuration
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to)
        else {
            context.completeTransition(false)
            return
        }
        let pageFrame = fromView.frame
        toView.frame = context.finalFrame(for: toVC)
        container.insertSubview(toView, belowSubview: fromView)

        // The landing measured LAST: the grid may have scrolled, or may need
        // to pin its content inset so the row holds still for the length of
        // the close. Asked before the rect is read, never after.
        geometry.willStageDismissal()
        container.layoutIfNeeded()
        let anchor = geometry.anchorFrame(container)
        let sourceRect = geometry.sourceFrame(container) ?? RevealStage.centredFallback(in: container)

        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let (host, mask) = RevealStage.makeHost(
            around: fromView, in: container, pageFrame: pageFrame
        )
        let open = RevealStage.open(container: container)
        let closed = RevealStage.closed(
            sourceRect: sourceRect,
            radius: geometry.sourceCornerRadius,
            anchor: anchor,
            anchorTopInset: geometry.anchorTopInset,
            matchesAnchor: geometry.matchesAnchor
        )
        RevealStage.apply(open, mask: mask, page: fromView)
        geometry.setDestinationGround(nil)

        #if DEBUG
        RevealStage.log("pop", "landing=\(NSCoder.string(for: sourceRect))"
            + " anchor=\(anchor.map(NSCoder.string(for:)) ?? "nil")"
            + " travel=\(Int(closed.pageTranslation))")
        #endif

        let presenting = geometry.depthView() ?? toView
        let screenRadius = ScreenGeometry.cornerRadius(behind: container)
        ZoomFlight.applyRecededChrome(to: presenting, radius: screenRadius)
        presenting.transform = CGAffineTransform(
            scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
        )
        let chrome = returningChrome
        let chromeAlpha: CGFloat = 1
        chrome?.alpha = 0

        // LINEAR, and that is not a style choice: this leg is what a finger
        // scrubs, and `UIPercentDrivenInteractiveTransition` tracks 1:1 only
        // against a linear curve. The release spring is the driver's own
        // completion curve, not this one's.
        UIView.animate(
            withDuration: transitionDuration(using: context),
            delay: 0,
            options: [.curveLinear]
        ) {
            RevealStage.apply(closed, mask: mask, page: fromView)
            // Back into the card's tone as the mask closes onto it, so the
            // last frame of the close and the row underneath are one colour.
            self.geometry.setDestinationGround(self.geometry.sourceFill)
            dim.alpha = 0
            presenting.transform = .identity
            chrome?.alpha = chromeAlpha
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            RevealStage.unwrap(fromView, from: host, to: container, frame: pageFrame)
            dim.removeFromSuperview()
            presenting.transform = .identity
            ZoomFlight.clearRecededChrome(from: presenting)
            // The page is staying or going; either way it must carry no mask
            // into its life on the stack — the feed is retained and pushed
            // again.
            fromView.layer.mask = nil
            // A cancelled close leaves the page on screen, so it must own its
            // ground again; a committed one is leaving, and the retained feed
            // must not carry a borrowed colour into its next push.
            self.geometry.setDestinationGround(nil)
            chrome?.alpha = cancelled ? 0 : chromeAlpha
            self.geometry.dismissalDidEnd(!cancelled)
            context.completeTransition(!cancelled)
        }
    }
}
