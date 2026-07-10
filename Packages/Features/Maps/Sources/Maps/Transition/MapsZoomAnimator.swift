import CoreNavigation
import UIKit

/// Drives one leg of the hero/zoom transition: a pin-sized thumbnail flies to
/// full-screen (present) or shrinks back into the pin (dismiss) over a *see-
/// through* feed canvas, so the map stays visible around the growing cell and
/// only a dedicated dim recedes it — never a global cross-fade of the opaque
/// feed. The presenting map recedes to a depth scale and the hero's corner
/// radius opens/closes with it. The same animator serves both directions via
/// `isPresenting` so the dismiss is a literal inverse of the present.
///
/// Percent-driven interactive dismissal scrubs this animator's implicit layer
/// animations; the completion block honours `transitionWasCancelled` so a
/// cancelled grab restores the feed and leaves the pin hidden.
@MainActor
final class MapsZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let source: any ZoomTransitionSource
    private weak var destination: (any ZoomTransitionDestination)?
    private let duration: TimeInterval = 0.42
    /// How far the presenting map recedes during the flight (depth cue).
    private static let mapDepthScale: CGFloat = 0.95
    /// The pin thumbnail's corner radius; the hero rounds to this on dismiss and
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
        // A dedicated dim sits *behind* the feed and dims only the map showing
        // through the (now transparent) canvas — never the hero or the info.
        let dim = Self.makeDimView(frame: container.bounds)
        container.addSubview(dim)

        toView.frame = container.bounds
        container.addSubview(toView)
        // Force the feed to lay out so its active-cell media frame is real.
        container.layoutIfNeeded()

        let startFrame = source.zoomHeroFrame(in: container)
        let targetFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        let hero = source.zoomHeroSnapshot()
        hero?.frame = startFrame
        if let hero { container.addSubview(hero) }

        destination?.prepareForZoomTransition()
        // The whole point: keep the feed opaque-content but its background clear,
        // so the map stays visible around the growing cell — no global cross-fade.
        destination?.setZoomCanvasTransparent(true)

        // Grow the info overlay (author, caption, engagement) *out of the pin* on
        // the same curve/duration/start as the flying media, so the whole cell
        // reads as expanding from the pin — not a flat fade over the top.
        destination?.setZoomHeroAnchor(startFrame)
        destination?.animateInfoOverlayExpandingIn(duration: duration)

        // Depth cue: the presenting map recedes to 0.95 with a gentle spring, so
        // the feed reads as lifting off a 3D canvas. (`view(forKey:)` is nil under
        // an over-full-screen present, so reach the root via the view controller.)
        let presentingView = context.viewController(forKey: .from)?.view
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0, options: [.curveEaseInOut]) {
            presentingView?.transform = CGAffineTransform(scaleX: Self.mapDepthScale, y: Self.mapDepthScale)
        }

        // Tail-weighted (ease-in): the map reads through for most of the flight
        // and only recedes to black as the cell lands.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            dim.alpha = 1
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            hero?.frame = targetFrame
            hero?.layer.cornerRadius = 0 // the pin's rounded square opens into full-bleed media
        } completion: { _ in
            hero?.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            self.destination?.setZoomCanvasTransparent(false)
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
        // make sure it sits behind the departing feed.
        if let toView = context.view(forKey: .to) {
            container.insertSubview(toView, at: 0)
        }

        let startFrame = destination?.zoomTargetFrame(in: container) ?? container.bounds
        let endFrame = source.zoomHeroFrame(in: container)
        let hero = source.zoomHeroSnapshot()
        hero?.frame = startFrame
        hero?.layer.cornerRadius = 0 // starts full-bleed; rounds back to the pin

        // Dim starts opaque (fully presented) and lifts to reveal the map as the
        // cell shrinks. It sits behind the feed so it dims only the map.
        let dim = Self.makeDimView(frame: container.bounds)
        dim.alpha = 1
        container.insertSubview(dim, belowSubview: fromView)
        if let hero { container.addSubview(hero) }

        destination?.prepareForZoomTransition()
        destination?.setZoomCanvasTransparent(true)
        destination?.setZoomHeroAnchor(endFrame)

        // Reverse depth cue: the map starts receded (0.95, covered) and scales
        // back to full as the feed shrinks — scrubs with the grab.
        let presentingView = context.viewController(forKey: .to)?.view
        presentingView?.transform = CGAffineTransform(scaleX: Self.mapDepthScale, y: Self.mapDepthScale)

        // Everything inside one block so the interactive grab scrubs it as a unit:
        // hero shrinks + rounds, dim lifts, map returns to full, info collapses.
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            hero?.frame = endFrame
            hero?.layer.cornerRadius = Self.pinCornerRadius
            dim.alpha = 0
            presentingView?.transform = .identity
            self.destination?.setInfoOverlayCollapsed(true)
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            hero?.removeFromSuperview()
            dim.removeFromSuperview()
            presentingView?.transform = .identity
            self.destination?.zoomTransitionDidEnd()
            if cancelled {
                // Returning to the feed: restore the overlay and the opaque canvas.
                self.destination?.setInfoOverlayCollapsed(false)
                self.destination?.setZoomCanvasTransparent(false)
            } else {
                self.source.zoomSourceDidReturn()
            }
            context.completeTransition(!cancelled)
        }
    }

    // MARK: - Dim

    /// A black view, initially transparent, that dims the source (map) behind the
    /// feed's see-through canvas during the flight — decoupled from the hero and
    /// info so each interpolates on its own terms.
    private static func makeDimView(frame: CGRect) -> UIView {
        let dim = UIView(frame: frame)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        return dim
    }
}
