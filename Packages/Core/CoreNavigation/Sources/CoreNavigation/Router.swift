import UIKit

/// Cross-feature navigation contract. Features hold a `Router` and ask for
/// destinations by route; only the app layer knows which coordinator answers.
@MainActor
public protocol Router: AnyObject {
    func route(to route: AppRoute)
    /// The screen `route` would push, made but NOT pushed — for a caller that
    /// pushes it itself, following a finger (`SwipeStageArbiter`'s `.push`,
    /// #1525). Nil: the route has no such screen (it presents, switches tabs,
    /// or is gated).
    func destination(for route: AppRoute) -> UIViewController?
    /// `route` with its push opened as a window out of `source` (#1874,
    /// `ProfileWindow`): a profile only, every push rule of `route(to:)`
    /// applying; any other route, or no window to measure, is `route(to:)`.
    func route(to route: AppRoute, throughWindowOf source: any ProfileWindowSource)
}

public extension Router {
    func destination(for route: AppRoute) -> UIViewController? { nil }
    func route(to route: AppRoute, throughWindowOf source: any ProfileWindowSource) {
        self.route(to: route)
    }
}
