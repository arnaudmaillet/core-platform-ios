import CoreNavigation
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
final class MapsZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let source: MapPinZoomSource
    private weak var destination: (any ZoomTransitionDestination)?
    private let duration: TimeInterval = 0.42
    /// The flight's spring. Damping just under 1 gives a hair of overshoot as
    /// the card lands — enough to read as "placed" rather than "switched to",
    /// never a visible bounce; the initial velocity gives it a lively push off
    /// the mark rather than a slow ease-in. Shared by both non-interactive legs
    /// so present and tap-back dismiss feel like the same physical object, and
    /// tuned to sit alongside the grab dismissal's own spring
    /// (`ZoomDismissInteractionController`).
    private static let springDamping: CGFloat = 0.82
    private static let springVelocity: CGFloat = 0.6

    init(isPresenting: Bool, source: MapPinZoomSource, destination: any ZoomTransitionDestination) {
        self.isPresenting = isPresenting
        self.source = source
        self.destination = destination
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

        let pinFrame = source.zoomHeroFrame(in: container)
        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds

        // The feed hides for the flight — the card is its stand-in. The
        // navigation bar needs no such care under a push: it belongs to the
        // navigation controller, above this container, and UIKit cross-fades
        // its items ("Maps" → back + author capsule) natively alongside this
        // animator. The card flies beneath it.
        destination?.setZoomContentHidden(true)

        let flight = ZoomFlight.build(
            source: source, destination: destination, pinFrame: pinFrame, pageFrame: pageFrame
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
        flight.poseAsPin()
        source.hideSourcePin()

        let screenRadius = ZoomFlight.screenCornerRadius(behind: container)

        // Depth cue: the presenting map recedes to 0.95, so the feed reads as
        // lifting off a 3D canvas. (`view(forKey:)` is nil under an
        // over-full-screen present, so reach the root via the view controller.)
        let presentingView = context.viewController(forKey: .from)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)

        // Dim fades on a plain curve — opacity should never bounce.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        // Card and the map's depth ride ONE spring, so the lift-off and the
        // canvas receding stay locked together and land as a single settle.
        // The card lands flush with the device's own display corners, so the
        // reveal of the (screen-clipped) feed underneath is seamless.
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: Self.springDamping,
                       initialSpringVelocity: Self.springVelocity, options: []) {
            flight.poseAsPage(cornerRadius: screenRadius)
            presentingView?.transform = CGAffineTransform(
                scaleX: ZoomFlight.mapDepthScale, y: ZoomFlight.mapDepthScale
            )
        } completion: { _ in
            self.destination?.setZoomContentHidden(false)
            flight.card.removeFromSuperview()
            flight.shadow.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            ZoomFlight.clearRecededChrome(from: presentingView) // covered by the opaque feed
            self.destination?.zoomTransitionDidEnd()
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    // MARK: - Dismiss

    private func dismiss(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
        }
        // Reinstall the map (`.to`) behind the departing card — a navigation
        // controller removes non-top views, so it isn't in the hierarchy yet.
        if let toView = context.view(forKey: .to) {
            if let toVC = context.viewController(forKey: .to) {
                toView.frame = context.finalFrame(for: toVC)
            }
            container.insertSubview(toView, at: 0)
        }

        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        let pinFrame = source.zoomHeroFrame(in: container)

        // Dim starts opaque (fully presented) and lifts to reveal the map as
        // the card shrinks.
        let dim = ZoomFlight.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let flight = ZoomFlight.build(
            source: source, destination: destination, pinFrame: pinFrame, pageFrame: pageFrame
        )
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
        destination?.setZoomContentHidden(true)

        // Reverse depth cue: the map starts receded (0.95, covered) and scales
        // back to full as the card shrinks.
        let presentingView = context.viewController(forKey: .to)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)
        presentingView?.transform = CGAffineTransform(
            scaleX: ZoomFlight.mapDepthScale, y: ZoomFlight.mapDepthScale
        )

        // The clip-morph home on one spring — card shrinks + rounds + regrows
        // its ring and shadow, chrome fades, dim lifts, and the map returns, all
        // settling onto the pin together. The same spring as the grab dismissal,
        // so a tap-back and a released grab land with the same physics; a hair
        // of overshoot reads as the card snapping into its pin socket.
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: Self.springDamping,
                       initialSpringVelocity: Self.springVelocity, options: []) {
            flight.poseAsPin()
            dim.alpha = 0
            presentingView?.transform = .identity
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            flight.card.removeFromSuperview()
            flight.shadow.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            ZoomFlight.clearRecededChrome(from: presentingView) // bezel-aligned again at scale 1
            // Restore the feed content for the cancel path; moot when finished.
            self.destination?.setZoomContentHidden(false)
            self.destination?.zoomTransitionDidEnd()
            if !cancelled {
                self.source.zoomSourceDidReturn()
            }
            context.completeTransition(!cancelled)
        }
    }
}
