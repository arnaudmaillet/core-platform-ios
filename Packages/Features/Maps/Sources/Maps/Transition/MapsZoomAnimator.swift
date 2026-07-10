import CoreNavigation
import UIKit

/// Drives one leg of the hero/zoom transition with a single *flying card*: one
/// view holding both the media thumbnail and a live replica of the
/// destination's UI chrome, animated by one transform from the pin's rect to
/// full screen (present) or back (dismiss). Because media and chrome share
/// that one matrix, they are geometrically incapable of drifting — "lockstep"
/// is a property of the hierarchy, not of synchronized clocks.
///
/// The destination view itself stays fully hidden during the flight and is
/// revealed only at landing, when the card covers the screen exactly (same
/// chrome scaffold, same layout), so the swap is invisible. Nothing mutates
/// the live feed mid-flight. The same animator serves both directions via
/// `isPresenting`, and percent-driven interactive dismissal scrubs its single
/// animation block; the completion honours `transitionWasCancelled`.
@MainActor
final class MapsZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let source: any ZoomTransitionSource
    private weak var destination: (any ZoomTransitionDestination)?
    private let duration: TimeInterval = 0.42
    /// How far the presenting map recedes during the flight (depth cue).
    private static let mapDepthScale: CGFloat = 0.95
    /// The pin thumbnail's corner radius; the card rounds to this on dismiss and
    /// opens from it on present (matches `MapAnnotationView`/`MapPinZoomSource`).
    private static let pinCornerRadius: CGFloat = 12

    init(isPresenting: Bool, source: any ZoomTransitionSource, destination: any ZoomTransitionDestination) {
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
        let dim = Self.makeDimView(frame: container.bounds)
        container.addSubview(dim)

        toView.frame = container.bounds
        container.addSubview(toView)
        // Lay the feed out now: it kicks content hydration and settles the safe
        // areas the card's chrome replica bakes in below.
        container.layoutIfNeeded()

        let startFrame = source.zoomHeroFrame(in: container)
        let targetFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds

        // The feed stays invisible for the whole flight — the card is its
        // stand-in — and is revealed at landing, when the card covers the
        // screen exactly, so the swap is invisible.
        toView.alpha = 0

        let card = Self.makeFlightCard(
            frame: targetFrame,
            media: source.zoomHeroSnapshot(),
            chrome: destination?.zoomFlightChrome()
        )
        container.addSubview(card.view)
        // Resolve the replica's full-screen layout (safe areas, text wrapping)
        // while the card is still untransformed, then freeze it: from here the
        // flight is transform-only, so nothing can relayout mid-flight.
        container.layoutIfNeeded()
        card.view.transform = ZoomTransitionGeometry.collapseTransform(of: targetFrame, onto: startFrame)
        card.chrome?.alpha = 0

        // Depth cue: the presenting map recedes to 0.95 with a gentle spring, so
        // the feed reads as lifting off a 3D canvas. (`view(forKey:)` is nil under
        // an over-full-screen present, so reach the root via the view controller.)
        let presentingView = context.viewController(forKey: .from)?.view
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: [.curveEaseInOut]) {
            presentingView?.transform = CGAffineTransform(scaleX: Self.mapDepthScale, y: Self.mapDepthScale)
        }

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            card.view.transform = .identity
            card.view.layer.cornerRadius = 0 // the pin's rounded square opens full-bleed
            card.chrome?.alpha = 1
        } completion: { _ in
            toView.alpha = 1
            card.view.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
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

        let startFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        let endFrame = source.zoomHeroFrame(in: container)

        // Dim starts opaque (fully presented) and lifts to reveal the map as
        // the card shrinks.
        let dim = Self.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)

        let card = Self.makeFlightCard(
            frame: startFrame,
            media: source.zoomHeroSnapshot(),
            chrome: destination?.zoomFlightChrome()
        )
        card.view.layer.cornerRadius = 0 // starts full-bleed; rounds back to the pin
        container.addSubview(card.view)
        container.layoutIfNeeded()
        // The card (same chrome scaffold, same layout) replaces the feed for
        // the flight; the swap is pixel-invisible. Restored on a cancelled grab.
        fromView.alpha = 0

        // Reverse depth cue: the map starts receded (0.95, covered) and scales
        // back to full as the card shrinks — scrubs with the grab.
        let presentingView = context.viewController(forKey: .to)?.view
        presentingView?.transform = CGAffineTransform(scaleX: Self.mapDepthScale, y: Self.mapDepthScale)

        // Everything inside one block so the interactive grab scrubs it as a
        // unit: card shrinks + rounds, its chrome fades, dim lifts, map returns.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            card.view.transform = ZoomTransitionGeometry.collapseTransform(of: startFrame, onto: endFrame)
            card.view.layer.cornerRadius = Self.pinCornerRadius
            card.chrome?.alpha = 0
            dim.alpha = 0
            presentingView?.transform = .identity
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            card.view.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            fromView.alpha = 1 // restore the feed for the cancel path; moot when finished
            self.destination?.zoomTransitionDidEnd()
            if !cancelled {
                self.source.zoomSourceDidReturn()
            }
            context.completeTransition(!cancelled)
        }
    }

    // MARK: - Flight card

    /// The single flying unit: `view` clips and rounds like a physical card;
    /// `chrome` is retained separately only so the animator can fade it.
    private struct FlightCard {
        let view: UIView
        let chrome: UIView?
    }

    /// Builds the card: black backing (letterboxing), the media thumbnail
    /// full-bleed, and the destination's chrome replica full-bleed above it —
    /// the same z-order as the landed page.
    private static func makeFlightCard(frame: CGRect, media: UIView?, chrome: UIView?) -> FlightCard {
        let card = UIView(frame: frame)
        card.backgroundColor = .black
        card.clipsToBounds = true
        card.layer.cornerRadius = pinCornerRadius
        card.layer.cornerCurve = .continuous
        card.isUserInteractionEnabled = false
        if let media {
            media.frame = card.bounds
            media.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            media.layer.cornerRadius = 0 // the card owns the rounding
            card.addSubview(media)
        }
        if let chrome {
            chrome.frame = card.bounds
            chrome.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            card.addSubview(chrome)
        }
        return FlightCard(view: card, chrome: chrome)
    }

    // MARK: - Dim

    /// A black view, initially transparent, that dims the source (map) behind
    /// the flying card — decoupled from the card so each interpolates on its
    /// own terms.
    private static func makeDimView(frame: CGRect) -> UIView {
        let dim = UIView(frame: frame)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        return dim
    }
}
