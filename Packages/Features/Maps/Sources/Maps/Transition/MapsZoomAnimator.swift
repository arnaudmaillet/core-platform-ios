import CoreNavigation
import UIKit

/// Drives one leg of the hero/zoom transition: a pin-sized thumbnail flies to
/// full-screen (present) or shrinks back into the pin (dismiss), while the snap
/// feed cross-fades. The same animator serves both directions via `isPresenting`
/// so the dismiss is a literal inverse of the present.
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
        toView.alpha = 0

        // Grow the info overlay (author, caption, engagement) into place on the
        // same curve/duration/start as the flying media, so the whole cell reads
        // as expanding out of the pin — not a flat fade over the top.
        destination?.animateInfoOverlayExpandingIn(duration: duration)

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            toView.alpha = 1
            hero?.frame = targetFrame
        } completion: { _ in
            hero?.removeFromSuperview()
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
        if let hero { container.addSubview(hero) }

        destination?.prepareForZoomTransition()

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            fromView.alpha = 0
            hero?.frame = endFrame
            // Collapse the info overlay back toward the pin inside the block, so
            // it scrubs in lockstep with the interactive grab (the percent-driven
            // controller drives this same animation).
            self.destination?.setInfoOverlayCollapsed(true)
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            hero?.removeFromSuperview()
            self.destination?.zoomTransitionDidEnd()
            if cancelled {
                // Returning to the feed: undo the fade and restore the overlay.
                fromView.alpha = 1
                self.destination?.setInfoOverlayCollapsed(false)
            } else {
                self.source.zoomSourceDidReturn()
            }
            context.completeTransition(!cancelled)
        }
    }
}
