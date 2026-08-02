
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

    /// Chrome of the SOURCE screen that is down while the destination is up and
    /// must come back with the return — the app's tab bar. Assign it and the
    /// grab drives its alpha 1:1 with the drag, and the non-interactive pop
    /// fades it in on the flight's own spring, so it is never seen to pop in
    /// after the card has landed. The owner is responsible for its hidden
    /// state; this only drives alpha.
    public var returningSourceChrome: UIView? {
        didSet { interaction.setReturningChrome(returningSourceChrome) }
    }

    /// Fires when an interactive grab is CANCELLED — the destination stays up,
    /// so anything the owner undid at grab-begin (the tab bar's hidden state)
    /// has to go back. A completed return reports through `onSourceReturned`.
    public var onDismissalCancelled: (() -> Void)? {
        didSet { interaction.onCancelled = onDismissalCancelled }
    }

    /// Fires when the PUSH itself is reversed mid-air — the flight was caught
    /// and dragged back, so the destination never showed and never will.
    ///
    /// `didShow` reports neither side of a cancelled transition, so without
    /// this the owner's per-flight state (its retained controller, the hidden
    /// tab bar, an open playback handoff) stayed locked until the next
    /// completed transition — which could never come, because the retained
    /// controller is exactly what gates starting one. The owner should tear
    /// down here as it does in `onSourceReturned`; both are idempotent
    /// close-outs of the same flight.
    public var onPresentationCancelled: (() -> Void)?

    public init(source: any ZoomTransitionSource, destination: any ZoomTransitionDestination) {
        self.source = source
        self.destination = destination
        self.feedViewController = destination as? UIViewController
        super.init()
        // Before the destination is pushed, and so before it lays out and
        // activates its first page — the only point early enough for it to
        // suppress its own playback for the duration of the flight.
        destination.zoomTransitionWillBegin()
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
            let animator = ZoomAnimator(isPresenting: true, source: source, destination: destination)
            animator.onPresentationReversed = { [weak self] in self?.onPresentationCancelled?() }
            return animator
        case .pop where fromVC === feed:
            return ZoomAnimator(
                isPresenting: false, source: source, destination: destination,
                returningChrome: returningSourceChrome
            )
        default:
            return nil // e.g. comments detail above the feed — native
        }
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        // A grab that started from REST owns the transition outright, and the
        // animator has to stand down completely: it stages its own flight, so
        // an animator that also built one would put a second card over the one
        // under the finger.
        if interaction.isInteracting {
            (animationController as? ZoomAnimator)?.isSupersededByInteractiveDriver = true
            return interaction
        }
        // Otherwise the flight gets a dormant interruptor — either leg. It
        // starts the transition non-interactively, exactly as a tap always did,
        // and holds the right to catch the flight mid-air.
        guard let zoom = animationController as? ZoomAnimator else { return nil }
        let interruptor = ZoomFlightInterruptor(advancesOnDownwardDrag: zoom.isDismissing)
        flightInterruptor = interruptor
        return interruptor
    }

    /// Retains the interruptor for the length of a flight; UIKit holds its
    /// interaction controller weakly.
    private var flightInterruptor: ZoomFlightInterruptor?

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
