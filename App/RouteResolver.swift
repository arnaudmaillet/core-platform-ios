import ChatInterface
import CoreModels
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
            // Your own profile is a different screen, not a differently
            // labelled one: it carries Edit Profile, the settings gear and the
            // profile switcher. Deciding here — synchronously, from what the
            // origin already knew — is what makes the push land on the finished
            // personal profile instead of a stranger profile that discovers it
            // is you a round trip later and relabels itself.
            //
            // `makeCurrentUserProfileViewController` resolves the viewer from
            // the auth session, so `profileID` is not needed on this branch.
            //
            // `onLogout: nil` is the point, not an omission: a routed arrival
            // gets the personal profile *without* the settings gear and the
            // account switcher. Logging out or switching identity from inside a
            // deep stack would strand every screen beneath it on an identity
            // that no longer applies — those actions belong at the canonical
            // entry point only.
            let profile: UIViewController = if stub?.isSelf == true {
                profileFeature().makeCurrentUserProfileViewController(
                    onLogout: nil, identityStub: stub
                )
            } else {
                profileFeature().makeProfileViewController(for: profileID, identityStub: stub)
            }
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

        case .sendLink(let text, let profileID, let stub):
            // Same destination as `.messageUser`, with the composer seeded.
            let thread = chatFeature().makeDraftConversationViewController(
                with: profileID,
                displayName: stub?.displayName ?? "",
                prefill: text
            )
            navigator.activeNavigationController?.pushViewController(thread, animated: true)

        case .messageUser(let profileID, let stub):
            // Pushed immediately, with whatever identity the origin knew. The
            // thread finds-or-creates its conversation once it is on screen —
            // previously this awaited that call before pushing anything, which
            // is exactly as slow as it sounds from a tap.
            let thread = chatFeature().makeDraftConversationViewController(
                with: profileID,
                displayName: stub?.displayName ?? ""
            )
            navigator.activeNavigationController?.pushViewController(thread, animated: true)

        case .newMessage:
            let picker = chatFeature().makeNewMessageViewController()
            navigator.activeNavigationController?.pushViewController(picker, animated: true)
        }
    }
}
