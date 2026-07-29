
import UIKit

/// Wires the hero/zoom transition to a *navigation push*: it acts as the
/// map's navigation controller delegate while the snap feed is on the stack,
/// vending the push/pop animators and, while a grab is in flight, the
/// interactive pop driver — scoped strictly to the map↔feed pair, so any
/// other push on this stack (e.g. the comments detail) stays native.
///
/// A push means ONE `UINavigationBar` owns the header: UIKit cross-fades
/// "Maps" into the back item + author capsule natively, coordinated (and,
/// for interactive pops, scrubbed) with our transition. The modal era's two
/// overlapping bars — the frame-0 pop-in over the map's own title — are
/// structurally impossible here.
///
/// Owned (retained) by the map VC for the lifetime of the push.
@MainActor
public final class ZoomTransitionController: NSObject, UINavigationControllerDelegate {
    private let source: any ZoomTransitionSource
    private weak var destination: (any ZoomTransitionDestination)?
    /// The pushed feed — the only view controller whose push/pop this
    /// delegate customizes.
    private weak var feedViewController: UIViewController?
    private let interaction = ZoomDismissInteractionController()

    /// Completed-transition hooks, set by the map VC. `didShow` only reports
    /// *completed* transitions, so a cancelled interactive pop fires neither —
    /// exactly the teardown guard the modal path needed a
    /// `presentedViewController` check to approximate.
    public var onDestinationShown: (() -> Void)?
    public var onSourceReturned: (() -> Void)?

    public init(source: any ZoomTransitionSource, destination: any ZoomTransitionDestination) {
        self.source = source
        self.destination = destination
        self.feedViewController = destination as? UIViewController
        super.init()
    }

    /// Installs the grab-to-dismiss gesture on the pushed feed's view. Called
    /// by the presenter once it holds the feed VC.
    public func attachInteractiveDismissal(to view: UIView, onDismiss: @escaping () -> Void) {
        guard let destination else { return }
        interaction.attach(to: view, source: source, destination: destination, onBeginDismiss: onDismiss)
    }

    #if DEBUG
    /// `-maps-demo-grab`: drives the interactive dismissal without touches
    /// (the sim can't inject pans) — one diagonal grab below the completion
    /// threshold (floats down-right, then springs back to full screen from
    /// its 2D position), then one past it (completes the clip-morph home).
    /// Exercises the exact begin/update/release path a finger does.
    public func debugScriptedGrab() {
        Task { @MainActor [weak self] in
            await self?.interaction.debugPerformGrab(peakProgress: 0.22, verticalDrift: 180)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self?.interaction.debugPerformGrab(peakProgress: 0.55, verticalDrift: 70)
        }
    }
    #endif

    // MARK: - UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        guard let destination, let feed = feedViewController else { return nil }
        switch operation {
        case .push where toVC === feed:
            return ZoomAnimator(isPresenting: true, source: source, destination: destination)
        case .pop where fromVC === feed:
            return ZoomAnimator(isPresenting: false, source: source, destination: destination)
        default:
            return nil // e.g. comments detail above the feed — native
        }
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        interaction.isInteracting ? interaction : nil
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        if viewController === feedViewController {
            onDestinationShown?()
            return
        }
        // The feed left the stack (popped, or already deallocated): the map —
        // or whatever remains — is back. A detail pushed above the feed keeps
        // the feed on the stack and reports nothing here.
        let feedStillOnStack = feedViewController.map {
            navigationController.viewControllers.contains($0)
        } ?? false
        if !feedStillOnStack {
            onSourceReturned?()
        }
    }
}
