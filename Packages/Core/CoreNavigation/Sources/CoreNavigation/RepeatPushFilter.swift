import Foundation

/// Whether a route repeats the push the router made last — a second tap on
/// the same author, not a second profile (#778).
///
/// Lives here rather than in the app's `RouteResolver` because it is POLICY,
/// and the app target has no tests: the rule is pure, so it can be.
///
/// Profiles are pushed at once, on their loading state, so during the slide
/// the new profile is already the top screen: that is what a repeat is
/// measured against. Except mid-transition, where the push waits for rest
/// (UIKit would drop it) and the screen is on no stack yet: a repeat then is
/// any route to the same id until that push runs.
///
/// Only the LAST push is remembered. A route to another id supersedes it, as
/// a newer tap supersedes an older one.
///
/// A screen can answer to more than the key it was pushed under (#800): a
/// profile pushed for `@ada` learns Ada's id once it resolves, and one pushed
/// by id learns her handle once it loads. `screenKeys` asks the screen, so a
/// notification for Ada over her `@ada` profile — or an `@ada` link over her
/// profile opened by id — is a repeat too.
public struct RepeatPushFilter<ID: Hashable> {
    private var last: (id: ID, screen: WeakScreen)?
    /// `last` waits for a running transition to end: not on the stack yet.
    private var isAwaitingRest = false

    public init() {}

    /// Whether a route to `id` is the last push again: its screen is still
    /// `topScreen`, or its push still waits for rest. `screenKeys` names the
    /// other keys the last pushed screen answers to by now.
    public func isRepeat(
        _ id: ID, topScreen: AnyObject?, screenKeys: (AnyObject) -> Set<ID> = { _ in [] }
    ) -> Bool {
        guard let last else { return false }
        let screen = last.screen.value
        guard last.id == id || screen.map({ screenKeys($0).contains(id) }) == true else { return false }
        if isAwaitingRest { return true }
        guard let screen, let topScreen else { return false }
        return screen === topScreen
    }

    /// When the router's push of `screen` happens.
    public enum Timing: Equatable, Sendable {
        case now
        /// A transition runs: the push waits for rest.
        case atRest
    }

    /// Records the push of `screen` for `id`, and when it happens.
    @discardableResult
    public mutating func willPush(_ id: ID, screen: AnyObject, isTransitioning: Bool) -> Timing {
        last = (id, WeakScreen(screen))
        isAwaitingRest = isTransitioning
        return isTransitioning ? .atRest : .now
    }

    /// The push of `screen` stopped waiting: it goes onto the stack now, or
    /// was dropped. If it is the one that waited for rest, the stack answers
    /// from here: popping it (or never landing it) ends the repeat.
    public mutating func stoppedWaiting(_ screen: AnyObject) {
        guard let pending = last?.screen.value, pending === screen else { return }
        isAwaitingRest = false
    }
}

/// A screen held weakly: a popped profile must be free to go.
private struct WeakScreen {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
