import CoreNavigation
import OSLog

/// Maps `AppRoute`s onto feature coordinators. In-app taps, universal links,
/// and push notification payloads all end up here — one navigation code path.
final class RouteResolver: Router {

    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "navigation")

    func route(to route: AppRoute) {
        // Dispatch to feature coordinators as they land.
        logger.debug("Unhandled route: \(String(describing: route))")
    }
}
