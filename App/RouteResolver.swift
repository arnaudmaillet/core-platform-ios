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

    private let uploadFeature: any UploadFeatureBuilding
    /// Feature builders are resolved lazily: each one depends on this resolver
    /// (as its router), so injecting them directly would be a construction
    /// cycle. The closures are only called when a route actually fires.
    private let profileFeature: () -> any ProfileFeatureBuilding
    private let feedFeature: () -> any FeedFeatureBuilding
    private let chatFeature: () -> any ChatFeatureBuilding
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "navigation")

    init(
        uploadFeature: any UploadFeatureBuilding,
        profileFeature: @escaping () -> any ProfileFeatureBuilding,
        feedFeature: @escaping () -> any FeedFeatureBuilding,
        chatFeature: @escaping () -> any ChatFeatureBuilding
    ) {
        self.uploadFeature = uploadFeature
        self.profileFeature = profileFeature
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
            // Not a tab switch: the feed is pushed onto the current tab's
            // stack (or popped back to, if already there) — openFeed owns
            // the dismiss-then-push choreography.
            navigator.openFeed()

        case .messages(let category):
            navigator.selectTab(.messages)
            navigator.activeNavigationController?.popToRootViewController(animated: true)
            // The inbox is the tab's root and already built: page it rather
            // than rebuild it, so an arriving route never resets the stack's
            // root under the user.
            (navigator.activeNavigationController?.viewControllers.first as? MessagesInboxCategorySelecting)?
                .setCategory(category, animated: false)

        case .profile(let profileID, let stub):
            let profile = profileFeature().makeProfileViewController(for: profileID, identityStub: stub)
            navigator.activeNavigationController?.pushViewController(profile, animated: true)

        case .upload:
            let compose = uploadFeature.makeComposeViewController()
            navigator.activeNavigationController?.present(compose, animated: true)

        case .post(let postID):
            let detail = feedFeature().makePostDetailViewController(for: postID, mode: .full)
            navigator.activeNavigationController?.pushViewController(detail, animated: true)

        case .comments(let postID):
            let comments = feedFeature().makePostDetailViewController(for: postID, mode: .commentsOnly)
            navigator.activeNavigationController?.pushViewController(comments, animated: true)

        case .conversation(let conversationID):
            let thread = chatFeature().makeConversationViewController(for: conversationID)
            navigator.activeNavigationController?.pushViewController(thread, animated: true)

        case .messageUser(let profileID):
            // Creating/finding the DM is async; capture the destination stack now.
            let chatFeature = chatFeature
            let nav = navigator.activeNavigationController
            Task {
                if let thread = await chatFeature().makeDirectMessageViewController(with: profileID) {
                    nav?.pushViewController(thread, animated: true)
                }
            }

        case .newMessage:
            // Interim: the contact-selection flow doesn't exist yet. This is
            // its one landing site — swap the alert for the picker (which
            // then emits `.messageUser`) without touching any emitter.
            let alert = UIAlertController(
                title: "New Message",
                message: "Contact selection is on its way. Until then, open someone's profile and tap Message.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            navigator.activeNavigationController?.present(alert, animated: true)
        }
    }
}
