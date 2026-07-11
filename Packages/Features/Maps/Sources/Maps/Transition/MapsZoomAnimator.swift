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
    /// Fraction of the dismissal spent on the detach dip. Front-loaded so the
    /// flight reads as "picked up, then flown home".
    private static let detachPhase: Double = 0.15

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

        toView.frame = container.bounds
        container.addSubview(toView)
        // Lay the feed out now: it kicks content hydration and settles the safe
        // areas the card's chrome replica bakes in below.
        container.layoutIfNeeded()

        let pinFrame = source.zoomHeroFrame(in: container)
        let pageFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds

        // The feed's *content* hides for the flight — the card is its
        // stand-in — but the presented container stays visible and clear, so
        // the real navigation bar keeps its native screen-space layout from
        // frame 0 and never pops or morphs. The card flies beneath it.
        destination?.setZoomContentHidden(true)
        toView.backgroundColor = .clear

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

        // Depth cue: the presenting map recedes to 0.95 with a gentle spring, so
        // the feed reads as lifting off a 3D canvas. (`view(forKey:)` is nil under
        // an over-full-screen present, so reach the root via the view controller.)
        let presentingView = context.viewController(forKey: .from)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: [.curveEaseInOut]) {
            presentingView?.transform = CGAffineTransform(
                scaleX: ZoomFlight.mapDepthScale, y: ZoomFlight.mapDepthScale
            )
        }

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            // Lands flush with the device's own display corners, so the reveal
            // of the (screen-clipped) feed underneath is seamless.
            flight.poseAsPage(cornerRadius: screenRadius)
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
        // The map (`.to`) stays visible under an over-full-screen present, but
        // make sure it sits behind the departing card.
        if let toView = context.view(forKey: .to) {
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
        // The card (same chrome scaffold, same layout) replaces the feed's
        // *content* — pixel-invisible swap — while the presented container
        // stays visible and clear, so the real navigation bar keeps rendering
        // natively above the shrinking card.
        destination?.setZoomContentHidden(true)
        fromView.backgroundColor = .clear

        // Reverse depth cue: the map starts receded (0.95, covered) and scales
        // back to full as the card shrinks.
        let presentingView = context.viewController(forKey: .to)?.view
        ZoomFlight.applyRecededChrome(to: presentingView, radius: screenRadius)
        presentingView?.transform = CGAffineTransform(
            scaleX: ZoomFlight.mapDepthScale, y: ZoomFlight.mapDepthScale
        )

        // Phase 1 (front-loaded): the card dips to 0.95 — "picked up". Phase
        // 2: the clip-morph home — card shrinks + rounds + regrows its ring
        // and shadow, chrome fades, while dim lifts and the map returns
        // across the whole flight.
        UIView.animateKeyframes(withDuration: duration, delay: 0, options: []) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: Self.detachPhase) {
                flight.poseDetached(scale: ZoomFlight.detachScale, cornerRadius: screenRadius)
            }
            UIView.addKeyframe(withRelativeStartTime: Self.detachPhase, relativeDuration: 1 - Self.detachPhase) {
                flight.poseAsPin()
            }
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                dim.alpha = 0
                presentingView?.transform = .identity
            }
        } completion: { _ in
            // Unlike UIView.animate, the keyframe API's completion isn't
            // @MainActor-annotated in the SDK; UIKit still delivers it on main.
            MainActor.assumeIsolated {
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
}
