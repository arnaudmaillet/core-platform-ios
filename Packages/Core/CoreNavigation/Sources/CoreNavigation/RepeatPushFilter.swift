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
public struct RepeatPushFilter<ID: Hashable> {
    private var last: (id: ID, screen: WeakScreen)?
    /// `last` waits for a running transition to end: not on the stack yet.
    private var isAwaitingRest = false

    public init() {}

    /// Whether a route to `id` is the last push again: its screen is still
    /// `topScreen`, or its push still waits for rest.
    public func isRepeat(_ id: ID, topScreen: AnyObject?) -> Bool {
        guard let last, last.id == id else { return false }
        if isAwaitingRest { return true }
        guard let screen = last.screen.value, let topScreen else { return false }
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
