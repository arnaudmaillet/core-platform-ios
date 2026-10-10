import Foundation

/// Holds block-based notification tokens for a screen's lifetime and
/// unregisters them together on its own deallocation, which happens when the
/// owning view controller is released. `@unchecked Sendable` so its `deinit`
/// may run off the main actor; `removeObserver` is itself thread-safe, and the
/// tokens are only mutated on the main actor.
///
/// ⚠️ It exists because a `deinit` cannot do this itself under Swift 6: a
/// main-actor screen's `deinit` is nonisolated, so it may not even READ a
/// stored `[any NSObjectProtocol]` to unregister it. A `@unchecked Sendable`
/// box whose own deinit does the work is the way out — and shared across this
/// package, because the second screen that wanted the wallet's change post
/// hit the same wall on the same day.
final class NotificationObserverBag: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    func add(_ token: any NSObjectProtocol) { tokens.append(token) }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
