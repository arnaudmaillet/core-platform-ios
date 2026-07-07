import CoreNavigation
import OSLog
import ProfileInterface
import UIKit
import UploadInterface

/// Maps `AppRoute`s onto the app shell. In-app taps, universal links, and push
/// notification payloads all end up here — one navigation code path.
///
/// Destinations are pushed onto the *currently selected* tab's stack (so back
/// returns to the origin); tab-owning routes select their tab first. The
/// navigator is held weakly and set by the shell when it starts, so routes
/// fired before login — or after logout — are logged and dropped, never crash.
@MainActor
final class RouteResolver: Router {
    weak var navigator: AppNavigating?

    private let profileFeature: any ProfileFeatureBuilding
    private let uploadFeature: any UploadFeatureBuilding
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "navigation")

    init(profileFeature: any ProfileFeatureBuilding, uploadFeature: any UploadFeatureBuilding) {
        self.profileFeature = profileFeature
        self.uploadFeature = uploadFeature
    }

    func route(to route: AppRoute) {
        guard let navigator else {
            logger.debug("No navigator; dropping route: \(String(describing: route))")
            return
        }

        switch route {
        case .feed:
            navigator.selectTab(.feed)
            navigator.activeNavigationController?.popToRootViewController(animated: true)

        case .profile(let profileID):
            let profile = profileFeature.makeProfileViewController(for: profileID)
            navigator.activeNavigationController?.pushViewController(profile, animated: true)

        case .upload:
            let compose = uploadFeature.makeComposeViewController()
            navigator.activeNavigationController?.present(compose, animated: true)

        case .post, .conversation:
            // No feature backs these yet; keep the single code path and light
            // up here once post detail / chat land.
            logger.debug("Route not yet backed by a feature: \(String(describing: route))")
        }
    }
}
