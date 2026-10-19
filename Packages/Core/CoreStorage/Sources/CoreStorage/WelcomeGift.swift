import Foundation

/// The likes a guest's sign-up brings (guest mode decision 11,
/// `dev/GUEST_MODE_REPORT.md` §3.2; the owner, 2026-10-14, #1146).
///
/// A flat `Policy.firstLaunch` likes, once per device: the first time the app
/// opens without an account the gift opens, and the member who arrives on
/// this device takes it (`settle(into:)`). A guest is never told about it —
/// no badge, no wallet sheet, no "your N likes" on a prompt: the server
/// credits it at sign-up, silently (core-platform-backend#827, #943).
///
/// The gift's three states, in order:
/// - unopened — no guest has opened the app on this device yet;
/// - open — a guest has;
/// - settled — a member arrived and took it (`settle(into:)`), or a member
///   was here first and the device never had a guest to welcome. Final.
public final class WelcomeGift: @unchecked Sendable {
    public enum Policy {
        /// What a sign-up after a guest's visit brings, once per device.
        public static let firstLaunch = 50
    }

    /// Fired after the gift opens or settles, with `object:` the gift.
    public static let didChangeNotification = Notification.Name("welcomeGift.didChange")

    private enum Key {
        static let openedAt = "welcomeGift.openedAt"
        static let settled = "welcomeGift.settled"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        #if DEBUG
        // `-welcome-gift-reset`: a fresh device, as far as the gift goes.
        if ProcessInfo.processInfo.arguments.contains("-welcome-gift-reset") {
            defaults.removeObject(forKey: Key.openedAt)
            defaults.removeObject(forKey: Key.settled)
        }
        #endif
    }

    // MARK: - Reads

    /// Whether a guest has opened the gift and no member has taken it yet.
    public var isOpen: Bool {
        lock.withLock { !defaults.bool(forKey: Key.settled) && openedAtLocked() != nil }
    }

    // MARK: - Writes

    /// A guest is here: opens the gift if this device never had one. A no-op
    /// on an open or settled gift.
    public func open() {
        let opened: Bool = lock.withLock {
            guard !defaults.bool(forKey: Key.settled), openedAtLocked() == nil else { return false }
            defaults.set(now().timeIntervalSince1970, forKey: Key.openedAt)
            return true
        }
        if opened { postDidChange() }
    }

    /// A member is here: credits an open gift to `wallet` and settles it, for
    /// good. Returns the amount credited — `Policy.firstLaunch` for an open
    /// gift, 0 otherwise, which settles an unopened gift too: an install whose
    /// first viewer was already a member has no guest to welcome, and must
    /// not start one on a later sign-out.
    @discardableResult
    public func settle(into wallet: WalletStore) -> Int {
        let outcome: (credited: Int, changed: Bool) = lock.withLock {
            guard !defaults.bool(forKey: Key.settled) else { return (0, false) }
            let amount = openedAtLocked() == nil ? 0 : Policy.firstLaunch
            defaults.set(true, forKey: Key.settled)
            return (amount, true)
        }
        // Credit after the gift settles, so a re-entrant settle can't pay twice.
        // ⚠️ NOT WHEN THE WALLET IS THE SERVER'S (#1008): the server credits
        // the gift itself when the guest's session ends into a member's, and
        // a local credit would be a second one the next read takes back.
        if wallet.server == nil { wallet.credit(outcome.credited) }
        if outcome.changed { postDidChange() }
        return outcome.credited
    }

    // MARK: - Private

    private func openedAtLocked() -> Date? {
        defaults.object(forKey: Key.openedAt) == nil
            ? nil
            : Date(timeIntervalSince1970: defaults.double(forKey: Key.openedAt))
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
