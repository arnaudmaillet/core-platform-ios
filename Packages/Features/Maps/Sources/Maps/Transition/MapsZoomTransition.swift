import CoreNavigation
import UIKit

/// Wires the hero/zoom transition to a modal present: it vends the present and
/// dismiss animators and, while a grab is in flight, the interactive dismissal
/// controller. Owned (retained) by the presenting map VC for the lifetime of
/// the presentation — it is the presented feed's `transitioningDelegate`.
@MainActor
final class MapsZoomTransition: NSObject, UIViewControllerTransitioningDelegate {
    private let source: MapPinZoomSource
    private weak var destination: (any ZoomTransitionDestination)?
    private let interaction = ZoomDismissInteractionController()

    init(source: MapPinZoomSource, destination: any ZoomTransitionDestination) {
        self.source = source
        self.destination = destination
        super.init()
    }

    /// Installs the grab-to-dismiss gesture on the presented feed's view. Called
    /// by the presenter once it holds the feed VC.
    func attachInteractiveDismissal(to view: UIView, onDismiss: @escaping () -> Void) {
        guard let destination else { return }
        interaction.attach(to: view, destination: destination, onBeginDismiss: onDismiss)
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        guard let destination else { return nil }
        return MapsZoomAnimator(isPresenting: true, source: self.source, destination: destination)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        guard let destination else { return nil }
        return MapsZoomAnimator(isPresenting: false, source: source, destination: destination)
    }

    func interactionControllerForDismissal(
        using animator: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        interaction.isInteracting ? interaction : nil
    }
}
