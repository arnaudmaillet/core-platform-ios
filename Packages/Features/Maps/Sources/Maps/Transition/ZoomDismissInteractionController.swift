import CoreNavigation
import UIKit

/// Turns a rightward drag on the snap feed into a percent-driven dismissal —
/// the iOS back-swipe idiom. The horizontal axis is chosen deliberately: the
/// feed pages *vertically* (and pulls-to-refresh vertically), so a horizontal
/// grab has no scroll view to fight. Direction is vetted in
/// `gestureRecognizerShouldBegin` (rightward and predominantly horizontal),
/// which lets the grab claim the card at `.began` — frame 0 of the drag —
/// instead of waiting for translation to accumulate. Progress is bound
/// strictly to swipe distance (translation over the view's width); release
/// completes past 35% of the width or on a rightward flick, and otherwise
/// springs back.
@MainActor
final class ZoomDismissInteractionController: UIPercentDrivenInteractiveTransition {
    /// Whether a grab is currently driving the dismissal — the transitioning
    /// delegate returns this controller only while true.
    private(set) var isInteracting = false

    private weak var destination: (any ZoomTransitionDestination)?
    /// Kicks off `dismiss(animated:)` on the presented feed when a grab begins.
    private var onBeginDismiss: (() -> Void)?
    private weak var pannedView: UIView?

    /// Fraction of the view's *width* a drag must cover to complete on release.
    private let completionThreshold: CGFloat = 0.35
    /// A rightward flick above this speed completes regardless of distance.
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
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = pannedView else { return }
        let progress = ZoomTransitionGeometry.dismissProgress(
            translation: gesture.translation(in: view).x,
            span: view.bounds.width
        )
        switch gesture.state {
        case .began:
            // Direction was vetted by gestureRecognizerShouldBegin — claim
            // immediately so the card detaches under the finger at frame 0.
            beginGrab()
        case .changed:
            guard isInteracting else { return }
            update(progress)
        case .ended, .cancelled:
            guard isInteracting else { return }
            releaseGrab(
                progress: progress,
                velocityX: gesture.velocity(in: view).x,
                ended: gesture.state == .ended
            )
        default:
            break
        }
    }

    private func beginGrab() {
        isInteracting = true
        // Freeze the pager so a diagonal drag can't page mid-dismiss.
        destination?.setContentScrollEnabled(false)
        onBeginDismiss?()
    }

    private func releaseGrab(progress: CGFloat, velocityX: CGFloat, ended: Bool) {
        isInteracting = false
        destination?.setContentScrollEnabled(true)
        let shouldFinish = ended && ZoomTransitionGeometry.shouldCompleteDismissal(
            progress: progress,
            velocity: velocityX,
            progressThreshold: completionThreshold,
            flickVelocity: flickVelocity
        )
        // Speed must stay positive in BOTH directions: an earlier version set
        // it to 0 on cancel, which makes the rewind take forever — the
        // transition hangs mid-flight with the feed content hidden, and the
        // screen is dead until the app restarts. `.easeOut` gives the release
        // its settle.
        completionSpeed = 1
        completionCurve = .easeOut
        shouldFinish ? finish() : cancel()
    }

    #if DEBUG
    /// Scripted grab for sim recordings (`-maps-demo-grab`): touch injection
    /// is impossible in the simulator, so this walks the exact
    /// begin/update/release path a finger drives — ramps progress over ~half a
    /// second, holds, then releases. Whether it completes or springs back is
    /// decided by the same threshold logic as a real release.
    func debugPerformGrab(peakProgress: CGFloat) async {
        beginGrab()
        let steps = 30
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: 16_000_000)
            update(peakProgress * CGFloat(step) / CGFloat(steps))
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        releaseGrab(progress: peakProgress, velocityX: 0, ended: true)
    }
    #endif
}

// MARK: - Direction and coexistence

extension ZoomDismissInteractionController: UIGestureRecognizerDelegate {
    /// The whole conflict story lives here: the pan begins only for a
    /// rightward, predominantly horizontal movement, so vertical paging and
    /// pull-to-refresh never see a competitor — and when it does begin, the
    /// intent is unambiguous enough to claim on the spot.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let view = pannedView else { return false }
        guard destination?.isReadyForInteractiveDismissal == true else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true // coexist with the pager's pan; we self-gate by direction above
    }
}
