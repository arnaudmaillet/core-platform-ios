
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
    /// Extra grab drivers with their OWN pop targets — the cluster-gallery
    /// shape, where a vertical grab lands on the gallery beneath while the
    /// horizontal one escapes to the map. Each is attached with its own
    /// source and dismissal closure; the delegate answers for whichever is
    /// interacting.
    private var extraInteractions: [ZoomDismissInteractionController] = []

    /// Per-pop-target flight sources. A pop from the feed normally flies to
    /// `source` (the screen that presented it), but a stack that carries an
    /// intermediate — map, gallery, feed — dismisses to DIFFERENT screens
    /// depending on the gesture, and the card must fly to whichever screen
    /// the pop actually lands on.
    private struct DismissTarget {
        weak var target: UIViewController?
        let source: any ZoomTransitionSource
    }
    private var dismissTargets: [DismissTarget] = []

    /// Registers `source` as the flight target for pops landing on `target`.
    public func setDismissSource(_ source: any ZoomTransitionSource, for target: UIViewController) {
        dismissTargets.append(DismissTarget(target: target, source: source))
    }

    /// A pop landed on a REGISTERED intermediate (see `setDismissSource`) —
    /// the feed is gone but the flow's origin screen has not returned.
    /// `onSourceReturned` deliberately does not fire for this landing; the
    /// owner uses this hook for the intermediate's chrome instead.
    public var onDismissedToIntermediate: ((UIViewController) -> Void)?

    private func dismissSource(for toVC: UIViewController) -> any ZoomTransitionSource {
        dismissTargets.first { $0.target === toVC }?.source ?? source
    }

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
        didSet {
            interaction.setReturningChrome(returningSourceChrome)
            extraInteractions.forEach { $0.setReturningChrome(returningSourceChrome) }
        }
    }

    /// Fires when an interactive grab is CANCELLED — the destination stays up,
    /// so anything the owner undid at grab-begin (the tab bar's hidden state)
    /// has to go back. A completed return reports through `onSourceReturned`.
    public var onDismissalCancelled: (() -> Void)? {
        didSet {
            interaction.onCancelled = onDismissalCancelled
            extraInteractions.forEach { $0.onCancelled = onDismissalCancelled }
        }
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

    #if DEBUG
    deinit {
        ZoomDebugCensus.decrement(ZoomDebugCensus.Key.controller)
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] ZoomTransitionController deinit")
        }
    }
    #endif

    public init(source: any ZoomTransitionSource, destination: any ZoomTransitionDestination) {
        self.source = source
        self.destination = destination
        self.feedViewController = destination as? UIViewController
        super.init()
        #if DEBUG
        Self.debugMostRecent = self
        ZoomDebugCensus.increment(ZoomDebugCensus.Key.controller)
        #endif
        // Before the destination is pushed, and so before it lays out and
        // activates its first page — the only point early enough for it to
        // suppress its own playback for the duration of the flight.
        destination.zoomTransitionWillBegin()
    }

    /// Installs the grab-to-dismiss gesture on the pushed feed's view. Called
    /// by the presenter once it holds the feed VC. `axes` arms the grab's
    /// directions — both by default, the forward-only feed's contract: a
    /// rightward or a downward grab flies the card home identically.
    public func attachInteractiveDismissal(
        to view: UIView,
        axes: Set<ZoomDismissAxis> = [.horizontal, .vertical],
        onDismiss: @escaping () -> Void
    ) {
        guard let destination else { return }
        interaction.attach(
            to: view, source: source, destination: destination, axes: axes,
            onBeginDismiss: onDismiss
        )
    }

    /// A SECOND grab on the same view, flying `towards` a different source
    /// when it commits — the cluster-gallery split, where the vertical axis
    /// pops one level (to the gallery, registered via `setDismissSource`)
    /// and the horizontal axis escapes the whole stack. Keep the axis sets
    /// of the drivers disjoint: each pan self-gates on its own axes, so
    /// disjoint sets mean exactly one driver ever claims a drag.
    public func attachInteractiveDismissal(
        to view: UIView,
        axes: Set<ZoomDismissAxis>,
        towards flightSource: any ZoomTransitionSource,
        onDismiss: @escaping () -> Void
    ) {
        guard let destination else { return }
        let driver = ZoomDismissInteractionController()
        driver.setReturningChrome(returningSourceChrome)
        driver.onCancelled = onDismissalCancelled
        driver.attach(
            to: view, source: flightSource, destination: destination, axes: axes,
            onBeginDismiss: onDismiss
        )
        extraInteractions.append(driver)
    }

    #if DEBUG
    /// The controller most recently created, so a harness can grab the screen
    /// it just presented without every presenter having to publish its own.
    ///
    /// Weak and last-wins, which is exactly the harness's usage: it presents
    /// one screen and immediately dismisses that one. Nothing in shipping code
    /// reads this.
    public private(set) static weak var debugMostRecent: ZoomTransitionController?

    /// `-maps-demo-grab`: drives the interactive dismissal without touches
    /// (the sim can't inject pans) — one diagonal grab below the completion
    /// threshold (floats along the axis, then springs back to full screen
    /// from its 2D position), then one past it (completes the clip-morph
    /// home). Exercises the exact begin/update/release path a finger does.
    /// With `-zoom-demo-grab-vertical` alongside, the same script drives the
    /// VERTICAL grab (forward-only milestone) instead of the horizontal one.
    public func debugScriptedGrab() {
        let axis: ZoomDismissAxis = ProcessInfo.processInfo.arguments
            .contains("-zoom-demo-grab-vertical") ? .vertical : .horizontal
        Task { @MainActor [weak self] in
            await self?.interaction.debugPerformGrab(
                peakProgress: 0.22, verticalDrift: 180, axis: axis
            )
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await self?.interaction.debugPerformGrab(
                peakProgress: 0.55, verticalDrift: 70, axis: axis
            )
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
            animator.onPresentationReversed = { [weak self] in
                // The flight this interruptor served is over; didShow will not
                // fire to release it.
                self?.flightInterruptor = nil
                self?.onPresentationCancelled?()
            }
            return animator
        case .pop where fromVC === feed:
            return ZoomAnimator(
                // The flight flies to whichever screen this pop LANDS on —
                // the presenting screen normally, a registered intermediate
                // (the cluster gallery) when the stack carries one.
                isPresenting: false, source: dismissSource(for: toVC), destination: destination,
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
        if let live = ([interaction] + extraInteractions).first(where: { $0.isInteracting }) {
            (animationController as? ZoomAnimator)?.isSupersededByInteractiveDriver = true
            return live
        }
        // Otherwise the flight gets a dormant interruptor — either leg. It
        // starts the transition non-interactively, exactly as a tap always did,
        // and holds the right to catch the flight mid-air.
        guard let zoom = animationController as? ZoomAnimator else { return nil }
        let interruptor = ZoomFlightInterruptor(advancesOnDownwardDrag: zoom.isDismissing)
        // The free-position channel needs the flying card itself; the animator
        // stages it only once the transition starts, so the seam is a closure
        // resolved at grab time rather than a value captured now. Endpoints
        // ride the same seam: the caught fraction is recovered from the
        // card's presentation size against them.
        interruptor.flightCard = { [weak zoom] in zoom?.stagedFlightCard }
        interruptor.flightEndpoints = { [weak zoom] in zoom?.stagedFlightEndpoints }
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
        // Whatever showed, the flight that interruptor served is over. Left
        // set, it survived until the next flight replaced it — a small object,
        // but a retained one whose pan the container's teardown had already
        // orphaned.
        flightInterruptor = nil
        if viewController === feedViewController {
            onDestinationShown?()
            return
        }
        // A pop that landed on a REGISTERED intermediate (the cluster
        // gallery) is not the origin's return: the map is still buried and
        // its chrome must stay down. The owner hears about it through its
        // own hook and decides what the landing means.
        if dismissTargets.contains(where: { $0.target === viewController }) {
            onDismissedToIntermediate?(viewController)
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
