import UIKit

/// Holds the interface orientation still while a hero flight is in the air.
///
/// Every pose a flight animates is a rect measured once, at staging, in the
/// container's coordinates: the source's tile, the destination's page, the
/// landing rect a release freezes. A rotation mid-flight re-lays the screens
/// out under those rects, and nothing re-measures them, so the card would fly
/// to where the tile WAS. Product decision (2026-10-03): rotation waits for
/// the flight, rather than every leg learning to re-measure.
///
/// Leases, not a flag: a dismissal's landing hold can overlap the next flight's
/// staging, and either ending must not release the other's hold.
/// `SideDrawerContainerViewController` (the app's root) answers the current
/// orientation alone while any lease is live, and is asked again when the last
/// one ends, so a rotation the device made meanwhile is applied then.
@MainActor
public enum FlightOrientationLock {
    @MainActor
    public final class Lease {
        private(set) var isHeld = true
        fileprivate init() {}

        /// Idempotent: every terminal branch of a flight may call it.
        public func release() {
            guard isHeld else { return }
            isHeld = false
            FlightOrientationLock.leaseEnded()
        }
    }

    private static var liveLeases = 0

    public static var isHeld: Bool { liveLeases > 0 }

    /// Live leases — for tests, which run beside other suites' flights.
    static var liveLeaseCount: Int { liveLeases }

    /// The longest any lease may hold. Every flight ends long before this
    /// (spring 0.42s, cover ≤3s, hold ≤0.75s), but a transition UIKit abandons
    /// never reaches its terminal branch, and a lock nothing releases would
    /// pin the app's orientation for the rest of the session.
    static let maximumHold: TimeInterval = 10

    public static func acquire() -> Lease {
        liveLeases += 1
        let lease = Lease()
        // STRONG: a lease whose owner was freed without releasing it must
        // still be counted down, and this is the only reference left then.
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumHold) {
            lease.release()
        }
        return lease
    }

    private static func leaseEnded() {
        liveLeases = max(0, liveLeases - 1)
        guard liveLeases == 0 else { return }
        // The device may have turned while the flight was up; let UIKit
        // re-ask now that the answer is no longer pinned.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }

    /// The mask holding `orientation` alone.
    static func mask(holding orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }
}
