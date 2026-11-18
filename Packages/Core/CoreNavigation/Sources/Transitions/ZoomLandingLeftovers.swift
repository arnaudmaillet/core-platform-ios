import UIKit

/// What a landed flight legitimately leaves on screen after
/// `completeTransition`, and the one place that can take it away again.
///
/// Two things outlive a hero by design:
/// - the present's landing COVER: the card parked above the page until the
///   page has a picture (`ZoomPresentSettlement`), up to 3s;
/// - the dismissal's landing HOLD: the card kept over the tile until the tile
///   is drawing (`ZoomAnimator.holdCard`), up to 0.75s.
///
/// ⚠️ NEITHER COULD BE CANCELLED, and both outlive the locks that keep a
/// second flight from starting. On a REUSED destination (For You keeps one
/// feed) that meant:
/// - a cold open closed and re-opened inside 3s kept the first post's cover
///   over the second post's page;
/// - when the first cover's gate finally fired, it adopted the first post's
///   surface into the second post's cell;
/// - a tile tapped during a hold flew over its own twin.
///
/// So each one is a lease here, and the next thing that needs the screen ends
/// it: a new present, a dismissal starting, the destination re-pointed, the
/// viewer dragging the page. Ending a lease removes the card at once, and a
/// gate that fires later finds it dead and does nothing (no adoption).
@MainActor
public enum ZoomLandingLeftovers {
    @MainActor
    final class Lease {
        private(set) weak var card: UIView?
        /// The view the leftover sits over: the destination's own view for a
        /// cover, the transition container for a hold.
        private(set) weak var host: UIView?
        private(set) var isLive = true

        init(card: UIView, host: UIView) {
            self.card = card
            self.host = host
        }

        /// Ends the lease. With `removingCard`, the card goes now; without, the
        /// owner is about to remove it itself (the natural ending).
        func end(removingCard: Bool) {
            guard isLive else { return }
            isLive = false
            if removingCard { card?.removeFromSuperview() }
            ZoomLandingLeftovers.forget(self)
        }
    }

    private static var leases: [Lease] = []

    /// Registers `card`, already parented in or over `host`, as a leftover.
    static func lease(_ card: UIView, over host: UIView) -> Lease {
        leases.removeAll { !$0.isLive || $0.card == nil }
        let lease = Lease(card: card, host: host)
        leases.append(lease)
        return lease
    }

    private static func forget(_ lease: Lease) {
        leases.removeAll { $0 === lease || $0.card == nil }
    }

    /// Ends every leftover over `host`, or inside it: the screen is needed for
    /// something else now.
    public static func clear(over host: UIView) {
        for lease in leases where lease.isLive {
            guard let leftover = lease.host,
                  leftover === host || leftover.isDescendant(of: host) || host.isDescendant(of: leftover)
            else { continue }
            lease.end(removingCard: true)
        }
    }

    #if DEBUG
    /// Live leftovers, for tests and the arrival audit.
    static var liveCount: Int { leases.filter { $0.isLive && $0.card != nil }.count }
    #endif
}
