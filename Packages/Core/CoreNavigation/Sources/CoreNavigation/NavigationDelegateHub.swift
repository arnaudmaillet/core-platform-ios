import ObjectiveC
import UIKit

/// The ONE delegate of a navigation controller, holding the stack's custom
/// transitions as leases (`dev/HERO_PUSH_AUDIT_PLAN.md`, 3.2).
///
/// ⚠️ WHY. `UINavigationController.delegate` is a single weak slot, and the
/// hero system had four writers taking turns in it:
/// - every flight (`HeroPushSession`);
/// - every card-shaped close (`InteractiveSlideDismissal`);
/// - the place page's map-return;
/// - a grab re-taking it for its flight.
///
/// Each one captured "who was there before" in its own way and gave it back in
/// its own way. A slot holds ONE object, so whoever was displaced stopped
/// hearing `didShow`, and `didShow` is news, not a choice. Three shipped
/// defects were exactly that:
/// - a flight never learned it had landed;
/// - a controller leaked per opened post;
/// - a delegate was restored to a flight that was already over.
///
/// The hub sits in the slot for the life of the stack, and the writers LEASE
/// it:
/// - **Routing.** UIKit's questions (which animator, which interaction
///   controller) go to the TOP lease alone, exactly as they went to the slot's
///   single occupant. A lease may still forward to the one it covers, as the
///   card close forwards a `.hero` pop to its flight.
/// - **Broadcast.** `didShow` goes to EVERY live lease, bottom first (the order
///   the forwarding chains already used), once each. A displaced flight hears
///   that it landed whether or not anyone remembered to tell it.
/// - **Release.** Releasing a lease uncovers whatever lies below it; there is
///   no "previous delegate" to capture, so none can be stale.
///
/// A delegate written to the slot directly (code or tests that predate the hub)
/// is adopted the next time the hub is reached — at the bottom if it was there
/// first, on top if it was written after — so nothing is silently dropped.
@MainActor
public final class NavigationDelegateHub: NSObject, UINavigationControllerDelegate {
    private struct Lease {
        weak var delegate: (any UINavigationControllerDelegate)?
    }

    private weak var navigationController: UINavigationController?
    private var leases: [Lease] = []
    /// The delegates already told about the `didShow` being dispatched, so a
    /// lease that also forwards it (`deliverDidShow`) cannot deliver it twice.
    private var delivered: Set<ObjectIdentifier>?

    private init(navigationController: UINavigationController) {
        self.navigationController = navigationController
        super.init()
    }

    /// The hub of `nav`, installed in its delegate slot (adopting whatever was
    /// written there directly) if it is not already.
    public static func of(_ nav: UINavigationController) -> NavigationDelegateHub {
        let hub: NavigationDelegateHub
        if let existing = objc_getAssociatedObject(nav, &hubKey) as? NavigationDelegateHub {
            hub = existing
        } else {
            hub = NavigationDelegateHub(navigationController: nav)
            objc_setAssociatedObject(nav, &hubKey, hub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        hub.reclaimSlot()
        return hub
    }

    /// The hub of `nav` if one was ever installed — without installing one.
    public static func existing(on nav: UINavigationController) -> NavigationDelegateHub? {
        objc_getAssociatedObject(nav, &hubKey) as? NavigationDelegateHub
    }

    /// Puts the hub back in the slot, adopting a delegate written there
    /// directly: at the BOTTOM if it was there before the hub (it owned the
    /// stack first), on TOP if it was written after (it took the slot, so it
    /// is the current owner).
    private func reclaimSlot() {
        guard let nav = navigationController, nav.delegate !== self else { return }
        if let direct = nav.delegate, !contains(direct) {
            if hasInstalled {
                leases.append(Lease(delegate: direct))
            } else {
                leases.insert(Lease(delegate: direct), at: 0)
            }
        }
        hasInstalled = true
        nav.delegate = self
    }

    private var hasInstalled = false

    // MARK: - Leases

    /// Puts `delegate` on top (moving it there if it is already leased).
    public func lease(_ delegate: any UINavigationControllerDelegate) {
        reclaimSlot()
        prune()
        leases.removeAll { $0.delegate === delegate }
        leases.append(Lease(delegate: delegate))
    }

    /// Takes `delegate` out, uncovering whatever is below it. Idempotent.
    public func release(_ delegate: any UINavigationControllerDelegate) {
        leases.removeAll { $0.delegate === delegate || $0.delegate == nil }
    }

    /// The lease UIKit's questions go to.
    public var top: (any UINavigationControllerDelegate)? {
        prune()
        return leases.last?.delegate
    }

    public func contains(_ delegate: any UINavigationControllerDelegate) -> Bool {
        leases.contains { $0.delegate === delegate }
    }

    /// Live leases, bottom first.
    var liveLeases: [any UINavigationControllerDelegate] {
        prune()
        return leases.compactMap(\.delegate)
    }

    private func prune() {
        leases.removeAll { $0.delegate == nil }
    }

    // MARK: - Forwarding without double delivery

    /// Tells `delegate` that `viewController` showed, once per dispatch.
    ///
    /// The forwarding a lease does on its own (a card close passing `didShow`
    /// to the flight it covers) goes through here: inside the hub's broadcast
    /// it is a no-op for a delegate already told, and outside one (a caller
    /// driving a lease directly) it delivers as it always did.
    public static func deliverDidShow(
        to delegate: (any UINavigationControllerDelegate)?,
        in nav: UINavigationController,
        viewController: UIViewController,
        animated: Bool
    ) {
        guard let delegate, delegate !== existing(on: nav) else { return }
        if let hub = existing(on: nav), hub.delivered != nil {
            let id = ObjectIdentifier(delegate)
            guard hub.delivered?.contains(id) == false else { return }
            hub.delivered?.insert(id)
        }
        delegate.navigationController?(nav, didShow: viewController, animated: animated)
    }

    // MARK: - UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        top?.navigationController?(
            navigationController, animationControllerFor: operation, from: fromVC, to: toVC
        )
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        top?.navigationController?(
            navigationController, interactionControllerFor: animationController
        )
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        top?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // A nested dispatch (a lease pushing from inside its own `didShow`)
        // gets a fresh ledger and restores the outer one after.
        let outer = delivered
        delivered = []
        defer { delivered = outer }
        // Snapshot: a lease may release itself (or another) while told.
        for lease in liveLeases {
            Self.deliverDidShow(
                to: lease, in: navigationController,
                viewController: viewController, animated: animated
            )
        }
    }
}

nonisolated(unsafe) private var hubKey: UInt8 = 0

public extension UINavigationController {
    /// The delegate this stack's custom transitions are answered by: the hub's
    /// top lease, or the raw delegate on a stack that has no hub.
    var leasedDelegate: (any UINavigationControllerDelegate)? {
        if let hub = NavigationDelegateHub.existing(on: self), delegate === hub { return hub.top }
        return delegate
    }
}
