import UIKit

/// Whether a screen transition's flight is in the air in a WINDOW — a hero
/// zoom, its landing cover and hold, a grab dismissal, a text reveal — for
/// content that must not play through one.
///
/// ⚠️ ANIMATED EMOTES SIT OUT A FLIGHT (the owner, 2026-10-15): a flight lays
/// out its cards inside its own animation, and an emote placed then flew in
/// from the label's corner; copies of the caption on both ends drew it
/// twice. While any flight is up in its window an `EmoteLabel` draws plain
/// glyphs and the post page's shortcut wheel hides, and both come back when
/// the last one lands.
///
/// Per window, not process-wide: a flight only stills what it flies over,
/// and a test host's transition — often abandoned, or staged with no window
/// at all — never stills another suite's labels (#713/#716's trap). A flight
/// with no window stills nothing.
///
/// Counted, not a flag: a landing hold can overlap the next flight's staging.
/// The flights themselves begin and end it (CoreNavigation's
/// `FlightOrientationLock` and reveal transition); this package only carries
/// the state, which both sides can see.
@MainActor
public enum FlightActivity {
    /// Posted when a window's activity starts or ends; the object is the
    /// window.
    public static let didChangeNotification = Notification.Name("FlightActivity.didChange")

    /// The windows with a flight in the air, and how many. Held weakly: a
    /// window freed mid-flight drops out, and a new window at the same
    /// address is never mistaken for it.
    private final class Entry {
        weak var window: UIWindow?
        var count = 0
        init(window: UIWindow) { self.window = window }
    }

    private static var entries: [Entry] = []

    /// Whether a flight is in the air in `view`'s window. Off a window, no.
    public static func isActive(for view: UIView) -> Bool {
        guard let window = view.window else { return false }
        return entries.contains { $0.window === window && $0.count > 0 }
    }

    /// One flight's hold: released when it lands, idempotently, and by
    /// itself after `maximumHold` — a transition UIKit abandons never reaches
    /// its completion, and a hold nothing released would still every emote
    /// for the rest of the session.
    @MainActor
    public final class Lease {
        private var isHeld = true
        private weak var window: UIWindow?
        fileprivate init(window: UIWindow?) { self.window = window }

        public func release() {
            guard isHeld else { return }
            isHeld = false
            if let window { FlightActivity.ended(in: window) }
        }
    }

    /// The longest a flight may hold: every one lands long before this.
    public static let maximumHold: TimeInterval = 10

    /// A flight took off in `window`; release the lease when it lands. No
    /// window: a lease that stills nothing.
    public static func begin(in window: UIWindow?) -> Lease {
        let lease = Lease(window: window)
        guard let window else { return lease }
        entries.removeAll { $0.window == nil }
        let entry = entries.first { $0.window === window } ?? {
            let entry = Entry(window: window)
            entries.append(entry)
            return entry
        }()
        entry.count += 1
        if entry.count == 1 { NotificationCenter.default.post(name: didChangeNotification, object: window) }
        // STRONG, as `FlightOrientationLock`'s: the timeout must still count
        // down a lease whose owner was freed without releasing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumHold) { lease.release() }
        return lease
    }

    private static func ended(in window: UIWindow) {
        guard let entry = entries.first(where: { $0.window === window }), entry.count > 0 else { return }
        entry.count -= 1
        if entry.count == 0 {
            entries.removeAll { $0 === entry || $0.window == nil }
            NotificationCenter.default.post(name: didChangeNotification, object: window)
        }
    }
}
