import CoreNavigation
import UIKit

/// Turns a downward drag on the snap feed into a percent-driven dismissal. It
/// coexists with the feed's own vertical paging: it only *begins* when the feed
/// says it's at its scroll-top boundary (`isReadyForInteractiveDismissal`) and
/// the drag is downward, and freezes the feed's scroll for the duration so the
/// two don't fight.
@MainActor
final class ZoomDismissInteractionController: UIPercentDrivenInteractiveTransition {
    /// Whether a grab is currently driving the dismissal — the transitioning
    /// delegate returns this controller only while true.
    private(set) var isInteracting = false

    private weak var destination: (any ZoomTransitionDestination)?
    /// Kicks off `dismiss(animated:)` on the presented feed when a grab begins.
    private var onBeginDismiss: (() -> Void)?
    private weak var pannedView: UIView?

    /// Threshold of progress (or a fast downward flick) that completes rather
    /// than cancels on release.
    private let completionThreshold: CGFloat = 0.3
    private let flickVelocity: CGFloat = 900

    /// Installs the pan on the presented feed's view. `onBeginDismiss` should
    /// call `dismiss(animated: true)` on the presented view controller.
    func attach(
        to view: UIView,
        destination: any ZoomTransitionDestination,
        onBeginDismiss: @escaping () -> Void
    ) {
        self.destination = destination
        self.onBeginDismiss = onBeginDismiss
        self.pannedView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = pannedView else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let progress = ZoomTransitionGeometry.dismissProgress(translationY: translation.y, viewHeight: view.bounds.height)

        switch gesture.state {
        case .began, .changed:
            if !isInteracting {
                // Only claim the gesture at the top boundary, dragging down.
                guard translation.y > 0, destination?.isReadyForInteractiveDismissal == true else { return }
                isInteracting = true
                destination?.setContentScrollEnabled(false)
                onBeginDismiss?()
                return
            }
            update(progress)
        case .ended, .cancelled:
            guard isInteracting else { return }
            isInteracting = false
            destination?.setContentScrollEnabled(true)
            let shouldFinish = gesture.state == .ended && (progress >= completionThreshold || velocity.y > flickVelocity)
            completionSpeed = shouldFinish ? 1 : 0
            shouldFinish ? finish() : cancel()
        default:
            break
        }
    }
}

// MARK: - Coexist with the feed's scroll

extension ZoomDismissInteractionController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true // recognize alongside the collection view's pan; we self-gate on begin
    }
}
