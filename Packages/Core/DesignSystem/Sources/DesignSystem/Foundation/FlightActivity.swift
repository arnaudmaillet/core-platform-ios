import Foundation

/// Whether a screen transition's flight is in the air — a hero zoom, its
/// landing cover and hold, a grab dismissal, a text reveal — for content
/// that must not play through one.
///
/// ⚠️ ANIMATED EMOTES SIT OUT A FLIGHT (the owner, 2026-10-15): a flight lays
/// out its cards inside its own animation, and an emote placed then flew in
/// from the label's corner; copies of the caption on both ends drew it
/// twice. While any flight is up an `EmoteLabel` draws plain glyphs, and its
/// emotes come back when the last one lands.
///
/// Counted, not a flag: a landing hold can overlap the next flight's staging.
/// The flights themselves begin and end it (CoreNavigation's
/// `FlightOrientationLock` and reveal transition); this package only carries
/// the state, which both sides can see.
@MainActor
public enum FlightActivity {
    /// Posted when `isActive` changes.
    public static let didChangeNotification = Notification.Name("FlightActivity.didChange")

    private static var count = 0

    public static var isActive: Bool { count > 0 }

    /// One flight's hold: released when it lands, idempotently, and by
    /// itself after `maximumHold` — a transition UIKit abandons never reaches
    /// its completion, and a hold nothing released would still every emote
    /// for the rest of the session.
    @MainActor
    public final class Lease {
        private var isHeld = true
        fileprivate init() {}

        public func release() {
            guard isHeld else { return }
            isHeld = false
            FlightActivity.ended()
        }
    }

    /// The longest a flight may hold: every one lands long before this.
    public static let maximumHold: TimeInterval = 10

    /// A flight took off; release the lease when it lands.
    public static func begin() -> Lease {
        count += 1
        if count == 1 { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
        let lease = Lease()
        // STRONG, as `FlightOrientationLock`'s: the timeout must still count
        // down a lease whose owner was freed without releasing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumHold) { lease.release() }
        return lease
    }

    #if DEBUG
    /// Tests: lands every flight a test host left in the air. A transition
    /// a test drives without a window never reaches its completion, and its
    /// lease would still the emotes of every suite after it until the
    /// timeout.
    public static func debugLandAll() {
        guard count > 0 else { return }
        count = 0
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
    #endif

    private static func ended() {
        guard count > 0 else { return }
        count -= 1
        if count == 0 { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }
}
