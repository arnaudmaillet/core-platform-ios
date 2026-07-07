import ChatInterface
import CoreNavigation
import FeedInterface
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
    /// Resolved lazily: the feed feature depends on this resolver (as its
    /// router), so injecting it directly would be a construction cycle. The
    /// closure is only called when a `.post` route actually fires.
    private let feedFeature: () -> any FeedFeatureBuilding
    /// Also resolved lazily — chat depends on this resolver as its router.
    private let chatFeature: () -> any ChatFeatureBuilding
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "navigation")

    init(
        profileFeature: any ProfileFeatureBuilding,
        uploadFeature: any UploadFeatureBuilding,
        feedFeature: @escaping () -> any FeedFeatureBuilding,
        chatFeature: @escaping () -> any ChatFeatureBuilding
    ) {
        self.profileFeature = profileFeature
        self.uploadFeature = uploadFeature
        self.feedFeature = feedFeature
        self.chatFeature = chatFeature
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

        case .post(let postID):
            let detail = feedFeature().makePostDetailViewController(for: postID)
            navigator.activeNavigationController?.pushViewController(detail, animated: true)

        case .conversation(let conversationID):
            let thread = chatFeature().makeConversationViewController(for: conversationID)
            navigator.activeNavigationController?.pushViewController(thread, animated: true)
        }
    }
}
