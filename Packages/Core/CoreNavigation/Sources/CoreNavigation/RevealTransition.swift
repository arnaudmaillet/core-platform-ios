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
    /// How far below the SOURCE's top its own caption ends, when that caption
    /// is truncated — `nil` when the source shows the whole thing.
    ///
    /// This is the number that makes a collapsed card openable without a cut.
    /// Measured on an iPhone SE: a card whose caption is capped at four lines
    /// is 145pt tall, while the page's caption row for the same post is 299 —
    /// so 154pt of the destination has no counterpart in the source at all,
    /// and the mask slices straight through it. Worse than the slicing, the
    /// source spends its last ~44pt on its metric line while the destination
    /// has text there, so the final frame swaps words for furniture.
    ///
    /// Below this offset the destination is VEILED for the length of the
    /// flight, so the window shows what the card shows — the same four lines —
    /// and the card's own closing line arrives into empty space rather than
    /// over a sentence.
    public let sourceCaptionEnd: CGFloat?
    /// Puts the veil on the destination at `cut` (in the destination's own
    /// coordinates), or takes it away with `nil`.
    public let installDestinationVeil: (CGFloat?, UIColor?) -> Void
    /// The veil's opacity. Driven inside the flight's animation block, so it
    /// lifts as the page opens and returns as it closes — and scrubs with a
    /// finger on the dismissal.
    public let setDestinationVeilOpacity: (CGFloat) -> Void
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
    /// The view the depth cue recedes: the content, not the chrome around it.
    /// Same rule (and same reason) as `ZoomTransitionSource.zoomPresenterDepthView`.
    public let depthView: () -> UIView?
    /// The opening is over, `true` landed and `false` reversed mid-air.
    ///
    /// Exists for chrome the opening FADED rather than dismissed: the source's
    /// bar is driven to alpha 0 by the flight, and the owner takes it down for
    /// real here — under the landed page, where the frame change cannot be
    /// seen. A reversed opening puts it back instead.
    public let presentationDidEnd: (Bool) -> Void
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
        sourceCaptionEnd: CGFloat? = nil,
        installDestinationVeil: @escaping (CGFloat?, UIColor?) -> Void = { _, _ in },
        setDestinationVeilOpacity: @escaping (CGFloat) -> Void = { _ in },
        setDestinationGround: @escaping (UIColor?) -> Void = { _ in },
        anchorFrame: @escaping (UICoordinateSpace) -> CGRect? = { _ in nil },
        depthView: @escaping () -> UIView? = { nil },
        presentationDidEnd: @escaping (Bool) -> Void = { _ in },
        willStageDismissal: @escaping () -> Void = {},
        dismissalDidEnd: @escaping (Bool) -> Void = { _ in },
        matchesAnchor: Bool = true
    ) {
        self.sourceFrame = sourceFrame
        self.sourceCornerRadius = sourceCornerRadius
        self.sourceFill = sourceFill
        self.sourceCaptionEnd = sourceCaptionEnd
        self.installDestinationVeil = installDestinationVeil
        self.setDestinationVeilOpacity = setDestinationVeilOpacity
        self.setDestinationGround = setDestinationGround
        self.anchorFrame = anchorFrame
        self.depthView = depthView
        self.presentationDidEnd = presentationDidEnd
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
        matchesAnchor: Bool
    ) -> Pose {
        // Matched: the page is pushed down so the caption row's CONTAINER
        // starts where the source row's does. Top to top, with nothing added —
        // the two are the same layout, so their captions land on the same line
        // by construction. `PostCaptionRowView` insets its caption by
        // `PostGridListRowCell.captionTopInset` because that is what the card
        // does, and a transition that re-applied the same inset on top would
        // be counting it twice.
        //
        // It did. Measured on the user's iPhone SE recording: the close
        // settled, held for two frames, then the row jumped — a single
        // frame-to-frame delta larger than any frame of the animation itself,
        // showing the caption doubled 33px apart. 33px at 2x is 16pt, which is
        // exactly `captionTopInset`. The parameter that carried it is gone
        // rather than set to zero, so nothing can re-introduce the double
        // count.
        //
        // Plain: no travel at all, and the mask is a hole opening onto a page
        // that never moves.
        let translation: CGFloat = if matchesAnchor, let anchor {
            sourceRect.minY - anchor.minY
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
    /// The TIMESTAMP is half the value of these lines, not decoration.
    ///
    /// The simulator's Slow Animations multiplies every duration by ten and is
    /// invisible from inside the process — the code is unchanged and only the
    /// wall clock knows. It cost a wrong diagnosis here: a chrome fade timed at
    /// 2.65s for a 0.25s animation read as "the fade never ran", and the frames
    /// backing that up read as a regression that did not exist. `xcodebuild
    /// test` relaunches Simulator.app and turns the slowdown back on, so a run
    /// that was headless when it started may not be by the time it is measured.
    /// Compare consecutive stamps against the durations asked for before
    /// believing any of it.
    static func log(_ leg: String, _ message: String) {
        guard ProcessInfo.processInfo.arguments.contains("-text-reveal-log") else { return }
        print(String(format: "[text-reveal] %.3f %@ %@", CACurrentMediaTime(), leg, message))
    }
    #endif
}

/// Places the veil, given the anchor the flight measured.
///
/// Nothing to do when the source shows its whole caption (`sourceCaptionEnd`
/// nil) or when there is no anchor to measure from — a plain reveal has no
/// overflow to hide, and veiling one would only dim a page that matches.
@MainActor
private func installVeil(geometry: RevealGeometry, anchor: CGRect?) {
    guard let end = geometry.sourceCaptionEnd, let anchor else {
        geometry.installDestinationVeil(nil, nil)
        return
    }
    geometry.installDestinationVeil(anchor.minY + end, geometry.sourceFill)
}

// MARK: - Present

/// The window opens. Non-interactive, and on the hero's own spring, so a text
/// post and a media post settle with identical physics.
@MainActor
final class RevealPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let geometry: RevealGeometry
    /// Source chrome that must LEAVE with the opening rather than before it —
    /// the app's floating tab bar.
    ///
    /// The bar draws OVER the grid without insetting it, so at rest it covers
    /// the bottom of the row a reveal departs from: measured on an iPhone 17
    /// Pro, the bar occupies y 791…874 and the row 741…817, so 26pt of the
    /// card — its whole metric line — is not on screen. Hidden before the push,
    /// as a plain push does it, that line SNAPS into existence one frame after
    /// the mask opens: the card the viewer tapped is not the card that starts
    /// growing.
    ///
    /// Driven here instead, the bar is fully in place on frame 0 — so the
    /// revealed rect is pixel-identical to what was there — and dissolves as
    /// the page grows past it.
    private weak var departingChrome: UIView?

    init(geometry: RevealGeometry, departingChrome: UIView?) {
        self.geometry = geometry
        self.departingChrome = departingChrome
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
            matchesAnchor: geometry.matchesAnchor
        )
        let open = RevealStage.open(container: container)
        RevealStage.apply(closed, mask: mask, page: toView)
        // The page wears the CARD before it wears itself. Set outside the
        // animation block so frame 0 is already the card's tone; the block
        // below hands the ground back, which cross-fades it.
        geometry.setDestinationGround(geometry.sourceFill)
        // …and shows no more of itself than the card did. The cut is measured
        // from the SOURCE's top, and the two tops are aligned by `closed`, so
        // it lands in the destination at the anchor's top plus that offset.
        installVeil(geometry: geometry, anchor: anchor)
        geometry.setDestinationVeilOpacity(1)

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
        // FRONT-LOADED, unlike the dim: the bar has to be gone by the time the
        // mask has grown past where it sits, or it stands over the opening
        // page (it is a sibling of the navigation controller and renders above
        // the whole transition). Fading over the first 60% clears it while the
        // mask is still below it.
        let chrome = departingChrome
        UIView.animate(withDuration: duration * 0.6, delay: 0, options: [.curveEaseIn]) {
            chrome?.alpha = 0
        } completion: { _ in
            #if DEBUG
            RevealStage.log("present", "chrome faded to \(chrome?.alpha ?? -1)")
            #endif
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
            self.geometry.setDestinationVeilOpacity(0)
            presenting?.transform = CGAffineTransform(
                scaleX: ZoomFlight.presenterDepthScale, y: ZoomFlight.presenterDepthScale
            )
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            // Idempotent close-out: the ground is already back by now, this
            // only guarantees it if the animation was interrupted.
            self.geometry.setDestinationGround(nil)
            self.geometry.installDestinationVeil(nil, nil)
            RevealStage.unwrap(toView, from: host, to: container, frame: pageFrame)
            dim.removeFromSuperview()
            // Cleared under the opaque page, where the reset cannot be seen.
            presenting?.transform = .identity
            ZoomFlight.clearRecededChrome(from: presenting)
            // The owner takes the chrome down for real (or puts it back on a
            // reversal); the alpha goes home either way, since the view is
            // shared with every other screen that shows it.
            #if DEBUG
            RevealStage.log("present", "landed")
            #endif
            chrome?.alpha = 1
            self.geometry.presentationDidEnd(!cancelled)
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
            matchesAnchor: geometry.matchesAnchor
        )
        RevealStage.apply(open, mask: mask, page: fromView)
        geometry.setDestinationGround(nil)
        installVeil(geometry: geometry, anchor: anchor)
        geometry.setDestinationVeilOpacity(0)

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
            // …and back to showing only what the card shows, so the mask never
            // slices a sentence on its way home.
            self.geometry.setDestinationVeilOpacity(1)
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
            self.geometry.installDestinationVeil(nil, nil)
            chrome?.alpha = cancelled ? 0 : chromeAlpha
            self.geometry.dismissalDidEnd(!cancelled)
            context.completeTransition(!cancelled)
        }
    }
}
