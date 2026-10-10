import ChatInterface
import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import OSLog
import ProfileInterface
import UIKit
import SearchInterface

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
    /// ⚠️ A CLOSURE, like every other feature here, and NOT the value.
    ///
    /// `searchFeature` reaches the router, and the router IS this resolver, so
    /// handing the value in makes `routeResolver → searchFeature →
    /// routeResolver` a lazy cycle that recurses until the stack ends
    /// (`EXC_BAD_ACCESS` in `swift_beginAccess`, with the two getters
    /// alternating all the way down). The upload builder it replaced could be
    /// passed by value precisely because it needed no router.
    private let searchFeature: () -> any SearchFeatureBuilding
    /// Feature builders are resolved lazily: each one depends on this resolver
    /// (as its router), so injecting them directly would be a construction
    /// cycle. The closures are only called when a route actually fires.
    private let profileFeature: () -> any ProfileFeatureBuilding
    private let feedFeature: () -> any FeedFeatureBuilding
    private let chatFeature: () -> any ChatFeatureBuilding
    /// Puts the viewer's balance in a pushed screen's header — today, every
    /// routed profile. A closure for the same reason the features are: the
    /// wallet and its sheet belong to the container, which builds this
    /// resolver before it has built either.
    private let attachBalance: (UIViewController) -> Void
    /// The profile a handle names (`GetProfileByHandle`), for `.profileHandle`.
    private let lookupHandle: (String) async -> AppContainer.HandleLookup
    /// The profile a share token opens (`ResolveShareToken`), for
    /// `.profileShareToken`.
    private let lookupShareToken: (String) async -> AppContainer.HandleLookup
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "navigation")
    /// The profile the router pushed last — what turns a second tap on the
    /// same author into nothing while that profile is the top screen, or
    /// while its push waits for a running transition (#778).
    private var repeatProfiles = RepeatPushFilter<ProfileID>()

    init(
        searchFeature: @escaping () -> any SearchFeatureBuilding,
        profileFeature: @escaping () -> any ProfileFeatureBuilding,
        feedFeature: @escaping () -> any FeedFeatureBuilding,
        chatFeature: @escaping () -> any ChatFeatureBuilding,
        attachBalance: @escaping (UIViewController) -> Void,
        lookupHandle: @escaping (String) async -> AppContainer.HandleLookup = { _ in .unavailable },
        lookupShareToken: @escaping (String) async -> AppContainer.HandleLookup = { _ in .unavailable }
    ) {
        self.lookupHandle = lookupHandle
        self.lookupShareToken = lookupShareToken
        self.searchFeature = searchFeature
        self.profileFeature = profileFeature
        self.feedFeature = feedFeature
        self.chatFeature = chatFeature
        self.attachBalance = attachBalance
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
    /// - `animated`: `false` skips the slide entirely. Only the search screen
    ///   asks for it, and for one reason: it opens the keyboard as soon as it
    ///   is on screen, and a push animation is time the keyboard spends
    ///   waiting. UIKit hands out no transition coordinator for an unanimated
    ///   push, so the destination's `viewDidAppear` claim runs immediately
    ///   instead of after a transition that no longer exists.
    private func push(
        _ destination: UIViewController,
        using navigator: AppNavigating,
        animated: Bool = true
    ) {
        guard let navigation = navigator.activeNavigationController else {
            repeatProfiles.stoppedWaiting(destination)
            return
        }
        // A route arriving while a transition runs (a deep link during a hero
        // flight) waits for it: UIKit would drop the push silently.
        guard navigation.transitionCoordinator == nil else {
            navigation.whenAtRest { [weak self] in
                self?.push(destination, using: navigator, animated: animated)
            }
            return
        }
        repeatProfiles.stoppedWaiting(destination)
        // The overwhelmingly common case takes the plain path, untouched. This
        // app drives pushes through custom navigation delegates — zoom
        // transitions, the pop-gesture enabler — and `setViewControllers` is a
        // different enough entry point that routing every ordinary push through
        // it would be a wide change to buy a narrow fix.
        guard navigation.viewControllers.contains(where: { $0 is TransientDestinationPicking }) else {
            navigation.pushViewController(destination, animated: animated)
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
        navigation.setViewControllers(stack, animated: animated)
    }

    func route(to route: AppRoute) {
        guard let navigator else {
            logger.debug("No navigator; dropping route: \(String(describing: route))")
            return
        }
        // A second tap on the author whose profile was just pushed is the same
        // request, not a second push: during the slide the new profile is
        // already the top screen.
        if case .profile(let id, _) = route,
           repeatProfiles.isRepeat(id, topScreen: navigator.activeNavigationController?.topViewController) {
            // Still the viewer's tap: a drawer it came from slides shut.
            navigator.closeOverlays()
            return
        }
        // A route that writes (opening a thread to message someone) needs an
        // account: a guest signs up first, and the route then runs as asked.
        // Checked here so every origin — a profile's button, a share sheet, a
        // deep link — is covered by one rule.
        if let action = route.gatedAction,
           let source = navigator.activeNavigationController,
           let gate = MemberGates.gate(from: source), !gate.isMember {
            Task { [weak self] in
                guard await gate.requireMember(for: action) else { return }
                self?.route(to: route)
            }
            return
        }
        // The notifications drawer slides shut as the destination arrives —
        // a tap on a notification is a route, and it lands underneath.
        navigator.closeOverlays()

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
            // The header reads `[back][filter] … [coins]`: the balance is the
            // viewer's, on anyone's profile. Attached BEFORE the push so the
            // item rides the push instead of popping in after it.
            attachBalance(profile)
            // ⚠️ AT ONCE, ON ITS LOADING STATE (#778, the owner's rule
            // 2026-10-10: a push never waits on data). The header redacts in
            // place and the gallery shows its bones; the data cross-fades in
            // over the very frames it will occupy. It used to be held up to
            // 250 ms for its data (`PresentationHold`, charter P12a).
            repeatProfiles.willPush(
                profileID, screen: profile,
                isTransitioning: navigator.activeNavigationController?.transitionCoordinator != nil
            )
            push(profile, using: navigator)

        case .search:
            // ⚠️ NOT ANIMATED, and that is the whole point of this route being
            // different. The screen's job is a keyboard: it claims the field
            // the moment it appears, and with a push animation that claim waits
            // for the slide to finish before the keyboard even starts rising.
            // Skipping the slide takes the transition out of the sum — the
            // screen and its keyboard arrive together.
            //
            // ⚠️ AND IT IS A CROSS-DISSOLVE, NOT A CUT. A cut was tried
            // (`performWithoutAnimation` around the unanimated push, because
            // on iOS 26 `animated: false` alone still animated the wrapper's
            // frame — filmed as the list growing out of the top-left corner)
            // and read as brutal: the bar's items simply swapped. The dissolve
            // is the one native alternative to the slide that needs no
            // navigation delegate — see `crossDissolve`. The keyboard still
            // rises at once: the push inside is unanimated, so the screen's
            // `viewDidAppear` claims the field synchronously.
            let destination = searchFeature().makeSearchViewController()
            if let navigation = navigator.activeNavigationController {
                navigation.crossDissolve { [self] in
                    push(destination, using: navigator, animated: false)
                }
            } else {
                push(destination, using: navigator, animated: false)
            }

        case .profileHandle(let handle):
            // A tapped `@handle` or a `wynn.cn/@handle` link (#524): looked up,
            // then the profile is routed like an author's. A handle that names
            // no one (renamed, deleted) says so on the screen the viewer is on
            // rather than pushing a dead page.
            Task { [weak self, weak navigator] in
                guard let self else { return }
                switch await lookupHandle(handle) {
                case .found(let id):
                    // `self.`: inside `route(to:)` the bare name is the route.
                    self.route(to: .profile(id, stub: nil))
                case .missing:
                    Self.toast("This account doesn\u{2019}t exist", symbol: "person.crop.circle.badge.questionmark", on: navigator)
                case .unavailable:
                    Self.toast("Couldn\u{2019}t open @\(handle)", symbol: "wifi.exclamationmark", on: navigator)
                }
            }

        case .profileShareToken(let token):
            // A scanned QR code or a `wynn.cn/s/<token>` link (#412): resolved
            // by the server, then routed like an author's profile. A token the
            // owner reset, or links they switched off, read as no one.
            Task { [weak self, weak navigator] in
                guard let self else { return }
                switch await lookupShareToken(token) {
                case .found(let id):
                    self.route(to: .profile(id, stub: nil))
                case .missing:
                    Self.toast("This link no longer works", symbol: "link", on: navigator)
                case .unavailable:
                    Self.toast("Couldn\u{2019}t open this link", symbol: "wifi.exclamationmark", on: navigator)
                }
            }

        case .hashtag(let tag):
            // A tapped `#tag`, a hashtag completion, a searched `#tag` (#524):
            // a plain push, like a post's detail.
            push(searchFeature().makeHashtagViewController(tag: tag), using: navigator)

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

extension RouteResolver {
    /// A failure toast over the screen the viewer is on — or over the sheet
    /// covering it, which `Feedback` finds (#804): a link opened from a sheet
    /// used to say so behind it.
    static func toast(_ message: String, symbol: String, on navigator: (any AppNavigating)?) {
        guard let screen = navigator?.activeNavigationController?.topViewController else { return }
        Feedback.failure(message, symbol: symbol, from: screen)
    }
}

private extension AppRoute {
    /// The account a route needs before it runs, or nil for one anybody may
    /// follow (reading a post, a profile, a place).
    var gatedAction: GatedAction? {
        switch self {
        case .messageUser(_, let stub), .sendLink(_, _, let stub):
            .message(handle: stub?.handle)
        // The inbox is a member's: its tab is greyed out for a guest, so a
        // route there (a deep link, a notification) asks them to sign up and
        // lands once they have.
        case .messages, .conversation:
            .inbox
        default:
            nil
        }
    }
}
