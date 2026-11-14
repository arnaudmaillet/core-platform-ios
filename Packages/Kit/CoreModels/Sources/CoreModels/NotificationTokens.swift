import Foundation

/// Block-based `NotificationCenter` tokens, unregistered together when this
/// goes: with the screen, view model or store that holds it (#2390).
///
/// ⚠️ IT EXISTS BECAUSE A `@MainActor` OWNER'S `deinit` IS NONISOLATED under
/// Swift 6, so it may not even read its own stored tokens to unregister them.
/// This box does it in its own `deinit`, which may run on any thread:
/// `removeObserver` is thread-safe, and the tokens are only written on the
/// main actor. Eight packages and the app each carried a copy of these five
/// lines; one of them removed from `.default` whatever center the token came
/// from, and the ones written by assignment dropped the previous tokens
/// without unregistering them.
public final class NotificationTokens: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    /// `center` is the one the kept tokens were registered on.
    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// Whether nothing is observed.
    public var isEmpty: Bool { tokens.isEmpty }

    /// Keeps `token`, which came from this box's center.
    public func add(_ token: any NSObjectProtocol) {
        tokens.append(token)
    }

    /// Unregisters what was kept, then keeps `tokens` in its place: a second
    /// setup replaces the first instead of observing twice.
    public func replace(with tokens: [any NSObjectProtocol]) {
        removeAll()
        self.tokens = tokens
    }

    /// Unregisters everything kept.
    public func removeAll() {
        tokens.forEach(center.removeObserver)
        tokens = []
    }

    /// Observes `name` on the main queue; `handler` runs on the main actor.
    public func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        add(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        })
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}
