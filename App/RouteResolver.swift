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

    /// Pushes a destination, dropping any picker it is arriving *from*.
    ///
    /// Behaves as a plain push whenever no picker is on the stack, which is
    /// every route except the ones the compose flow emits.
    ///
    /// Every push goes through here rather than calling `pushViewController`
    /// directly, so the rule is a property of "the resolver pushed something"
    /// instead of a thing each new route has to remember. A screen that
    /// conforms to `TransientDestinationPicking` exists only to choose a
    /// destination; once one is on screen it would otherwise sit wedged
    /// underneath, and backing out of a thread you just opened would return you
    /// to a contact list rather than to Messages.
    ///
    /// When there IS one, it is replaced in a single `setViewControllers`
    /// rather than pushed-then-pruned: UIKit animates a stack whose last element
    /// is new exactly like a push, so this is the same transition with the
    /// picker simply absent from the result. Pruning afterwards would either
    /// fight the in-flight animation or have to be deferred into its completion,
    /// where an interactive pop can interleave.
    private func push(_ destination: UIViewController, using navigator: AppNavigating) {
        guard let navigation = navigator.activeNavigationController else { return }
        // The overwhelmingly common case takes the plain path, untouched. This
        // app drives pushes through custom navigation delegates — zoom
        // transitions, the pop-gesture enabler — and `setViewControllers` is a
        // different enough entry point that routing every ordinary push through
        // it would be a wide change to buy a narrow fix.
        guard navigation.viewControllers.contains(where: { $0 is TransientDestinationPicking }) else {
            navigation.pushViewController(destination, animated: true)
            return
        }
        var stack = navigation.viewControllers
        // Filtered across the WHOLE stack, not just the top: a picker is only
        // ever reached from a destination already on it, so one cannot
        // legitimately be buried deeper. Sweeping is what keeps repeated
        // compose → thread → compose round trips from stacking pickers the
        // viewer can never see but must swipe back through.
        stack.removeAll { $0 is TransientDestinationPicking }
        stack.append(destination)
        navigation.setViewControllers(stack, animated: true)
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
            push(profile, using: navigator)

        case .upload:
            let compose = uploadFeature.makeComposeViewController()
            navigator.activeNavigationController?.present(compose, animated: true)

        case .post(let postID):
            let detail = feedFeature().makePostDetailViewController(for: postID, mode: .full)
            push(detail, using: navigator)

        case .postStream(let postIDs):
            // The unified feed, not the single-post detail screen. Same
            // destination a Maps pin expands into — one repository and one post
            // cache behind it, so a tile the origin was showing is already warm.
            guard !postIDs.isEmpty else { return }
            // ⚠️ `ownsInteractiveDismissal: false` is load-bearing, not tidying.
            //
            // The snap feed defaults to claiming its own dismissal, because
            // every other way it is reached attaches a flight's grab or a slide
            // of its own. THIS push attaches neither — a route has no origin to
            // fly from and no screen-specific object to hang a gesture on — so
            // inheriting the claim meant `NativePopPolicy` refused the native
            // edge pop on behalf of a gesture that did not exist. The screen
            // rendered perfectly and answered no horizontal drag anywhere.
            //
            // Disclaiming hands the dismissal back to the platform, which is
            // exactly what a plain push should have. `hidesBottomBarWhenPushed`
            // is then the right way to manage the dock too: the objection to
            // that flag everywhere else in this app is that its choreography
            // does not scrub with a CUSTOM interactive pop, and there is no
            // custom pop here — this is UIKit's own, which the flag was written
            // for. `MainTabCoordinator.syncTabBarVisibility` already honours it.
            let feed = feedFeature().makeSnapFeedViewController(
                postIDs: postIDs, ownsInteractiveDismissal: false
            )
            feed.hidesBottomBarWhenPushed = true
            push(feed, using: navigator)

        case .comments(let postID):
            let comments = feedFeature().makePostDetailViewController(for: postID, mode: .commentsOnly)
            push(comments, using: navigator)

        case .conversation(let conversationID):
            let thread = chatFeature().makeConversationViewController(for: conversationID)
            push(thread, using: navigator)

        case .sendLink(let text, let profileID, let stub):
            // Same destination as `.messageUser`, with the composer seeded.
            let thread = chatFeature().makeDraftConversationViewController(
                with: profileID,
                displayName: stub?.displayName ?? "",
                prefill: text
            )
            push(thread, using: navigator)

        case .messageUser(let profileID, let stub):
            // Pushed immediately, with whatever identity the origin knew. The
            // thread finds-or-creates its conversation once it is on screen —
            // previously this awaited that call before pushing anything, which
            // is exactly as slow as it sounds from a tap.
            let thread = chatFeature().makeDraftConversationViewController(
                with: profileID,
                displayName: stub?.displayName ?? ""
            )
            push(thread, using: navigator)

        }
    }
}
