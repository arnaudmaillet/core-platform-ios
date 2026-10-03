import UIKit

/// One hero push, from the tap to the last thing it leaves behind — the
/// orchestration every presenter used to write for itself.
///
/// ⚠️ WHY THIS EXISTS. "Present a post by hero" was written three times (For
/// You, the map, `FeedFeatureBuilder`) plus close-only variants, and the
/// copies drifted. The audit (`dev/HERO_PUSH_AUDIT_PLAN.md`, 3.1) found:
/// - a reversed push closed out by two copies and leaked by the third;
/// - the navigation delegate restored four different ways, including an
///   unconditional `= nil` that clobbered whoever held the slot;
/// - a retainer cycle broken on one ending only.
///
/// Every one of those is a rule about the SESSION, not about the screen,
/// so it lives here once:
/// - the controller is built here and kept alive until the session closes;
/// - the stack's delegate slot is LEASED (`NavigationDelegateHub`): the
///   controller, and every driver registered as forwarding to it, give
///   their leases back on close, uncovering whatever lies below;
/// - every ending — returned, reversed, abandoned — runs ONE idempotent
///   close-out, then the presenter's hook with the reason;
/// - objects are released a turn after the close-out, because it runs inside
///   their own delegate callbacks.
///
/// What remains the presenter's is what is genuinely its own: playback scopes,
/// concealment, its dock policy, its gates. All of it goes in `onClose`.
@MainActor
public final class HeroPushSession {
    public enum Ending: Sendable, Equatable {
        /// The destination left the stack and the presenter is back (`didShow`).
        case returned
        /// The push was caught and reversed: the destination never showed.
        case reversed
        /// The presenter found the flight over by other means (a sweep on
        /// appearance, a pop-to-root, a card close that finished the pop) and
        /// closed it itself.
        case abandoned
        /// A dismissal landed on a registered intermediate
        /// (`ZoomTransitionController.setDismissSource`) — the cluster
        /// gallery: the flight is over, the presenter is still buried.
        case toIntermediate
    }

    /// The transition this session runs. Exposed for wiring that is genuinely
    /// per-screen (dismissal targets, intermediates, debug scripts).
    public let controller: ZoomTransitionController
    private weak var navigationController: UINavigationController?
    /// Drivers that hold the delegate slot on this session's behalf (a card
    /// close forwarding `.hero` pops to the controller). Weak: each is owned by
    /// whoever armed it.
    private var forwarders: [WeakDelegate] = []
    private var strongSelf: HeroPushSession?
    public private(set) var isClosed = false

    /// The presenter's own close-out, run once, after the session's.
    public var onClose: ((Ending) -> Void)?

    /// - Parameters:
    ///   - presents: `false` for a session that only ever flies a dismissal
    ///     (see `ZoomTransitionController.init(source:destination:presents:)`).
    ///   - retainsItself: `true` for a presenter that cannot hold the session
    ///     (a struct builder): the session then keeps itself alive until it
    ///     closes. Otherwise the presenter holds it.
    public init(
        source: any ZoomTransitionSource,
        destination: any ZoomTransitionDestination,
        on navigationController: UINavigationController,
        presents: Bool = true,
        retainsItself: Bool = false
    ) {
        controller = ZoomTransitionController(
            source: source, destination: destination, presents: presents
        )
        self.navigationController = navigationController
        if retainsItself { strongSelf = self }
        controller.onSourceReturned = { [weak self] in self?.close(.returned) }
        controller.onPresentationCancelled = { [weak self] in self?.close(.reversed) }
        controller.onDismissedToIntermediate = { [weak self] _ in self?.close(.toIntermediate) }
    }

    /// Leases the stack's delegate slot to the controller
    /// (`NavigationDelegateHub`). Called once, right before the push (or, for a
    /// close-only session, right after the screen it closes is up).
    public func takeDelegateSlot() {
        guard let nav = navigationController else { return }
        NavigationDelegateHub.of(nav).lease(controller)
    }

    /// Registers `driver` as holding the delegate slot for this session (it
    /// forwards to the controller), so a close may take the slot back from it.
    public func registerForwarder(_ driver: any UINavigationControllerDelegate) {
        forwarders.append(WeakDelegate(value: driver))
    }

    /// Whether the slot's top lease is this session's controller or one of its
    /// forwarders.
    public var holdsDelegateSlot: Bool {
        guard let nav = navigationController,
              let top = NavigationDelegateHub.existing(on: nav)?.top else { return false }
        return top === controller || isForwarder(top)
    }

    /// Ends the session. Idempotent: every ending may call it, and the first
    /// one wins.
    public func close(_ ending: Ending) {
        guard !isClosed else { return }
        isClosed = true
        // The flight's leases end with it: whatever lies below is uncovered,
        // with nothing captured that could be stale.
        if let nav = navigationController, let hub = NavigationDelegateHub.existing(on: nav) {
            hub.release(controller)
            for forwarder in forwarders.compactMap(\.value) { hub.release(forwarder) }
        }
        onClose?(ending)
        // Released a turn later: the close-out runs inside a delegate callback
        // of these very objects (the controller's `didShow`, which a card close
        // forwards from its own and then keeps executing).
        let released = (strongSelf, onClose)
        strongSelf = nil
        onClose = nil
        DispatchQueue.main.async { withExtendedLifetime(released) {} }
    }

    private func isForwarder(_ delegate: (any UINavigationControllerDelegate)?) -> Bool {
        guard let delegate else { return false }
        return forwarders.contains { $0.value === delegate }
    }

    private struct WeakDelegate {
        weak var value: (any UINavigationControllerDelegate)?
    }
}
