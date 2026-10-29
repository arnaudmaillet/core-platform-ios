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
    /// The profile a handle (`GetProfileByHandle`) or a share token
    /// (`ResolveShareToken`) names — handed to the profile pushed for
    /// `.profileHandle` / `.profileShareToken`, which asks it once on screen.
    private let lookupProfile: ProfileLookingUp
    /// A place's page from a link (#985) — built by Maps, which owns the
    /// atlas and the flags; nil for a place it cannot name.
    private let makePlacePage: (PlaceLink) -> UIViewController?
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "navigation")
    /// The profile the router pushed last — what turns a second tap on the
    /// same author into nothing while that profile is the top screen, or
    /// while its push waits for a running transition (#778). Keyed by the
    /// handle or token for a profile still resolving one (#800).
    private var repeatProfiles = RepeatPushFilter<ProfileRouteKey>()

    init(
        searchFeature: @escaping () -> any SearchFeatureBuilding,
        profileFeature: @escaping () -> any ProfileFeatureBuilding,
        feedFeature: @escaping () -> any FeedFeatureBuilding,
        chatFeature: @escaping () -> any ChatFeatureBuilding,
        attachBalance: @escaping (UIViewController) -> Void,
        lookupProfile: @escaping ProfileLookingUp = { _ in .unavailable },
        makePlacePage: @escaping (PlaceLink) -> UIViewController? = { _ in nil }
    ) {
        self.lookupProfile = lookupProfile
        self.makePlacePage = makePlacePage
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
        // A route at cold launch arrives before the window's first layout.
        navigation.layOutWindowIfUnsized()
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

    /// A second tap on the author whose profile is the top screen, or whose
    /// push is waiting (#778, #800).
    private func isRepeatProfile(_ route: AppRoute, using navigator: AppNavigating) -> Bool {
        guard let key = route.profileRouteKey else { return false }
        return repeatProfiles.isRepeat(
            key, topScreen: navigator.activeNavigationController?.topViewController,
            screenKeys: { ($0 as? ProfileRouteAnswering)?.profileRouteKeys ?? [] }
        )
    }

    /// A profile opened as a window out of `source` (#1874, `ProfileWindow`).
    /// The rules of `route(to:)` that a profile meets apply — the repeat
    /// filter, the overlays closing, the transient pickers — and anything this
    /// path cannot open as a window takes the plain push.
    func route(to route: AppRoute, throughWindowOf source: any ProfileWindowSource) {
        open(route, throughWindowOf: source, launch: nil)
    }

    private func open(_ route: AppRoute, throughWindowOf source: any ProfileWindowSource, launch: RevealLaunch?) {
        guard case .profile(let profileID, let stub) = route, let navigator else { return self.route(to: route) }
        if isRepeatProfile(route, using: navigator) {
            navigator.closeOverlays()
            return
        }
        navigator.closeOverlays()
        let profile = makeProfile(profileID, stub: stub)
        // ⚠️ THE STACK'S OWN TRANSITION, not any coordinator: the card's sheet
        // has just left (unanimated) in this same turn, and a coordinator for
        // that dismissal is not a push running (`isTransitioningItsStack`).
        guard let nav = navigator.activeNavigationController, !nav.isTransitioningItsStack,
              !nav.viewControllers.contains(where: { $0 is TransientDestinationPicking }),
              let opening = source.profileWindowGeometry(for: profileID, launch: launch)
        else { return pushProfile(profile, for: route, using: navigator) }
        if let key = route.profileRouteKey {
            repeatProfiles.willPush(key, screen: profile, isTransitioning: false)
        }
        repeatProfiles.stoppedWaiting(profile)
        nav.layOutWindowIfUnsized()
        let slide = ProfileWindow.attach(
            to: profile, opening: opening,
            closing: { [weak source] in source?.profileWindowGeometry(for: profileID, launch: nil) },
            releaseSource: { [weak source] in source?.releaseProfileWindowSource() }
        )
        // BEFORE the push, so the push asks this driver for its animator.
        slide.install(on: nav)
        nav.pushViewController(profile, animated: true)
    }

    func route(to route: AppRoute) {
        guard let navigator else {
            logger.debug("No navigator; dropping route: \(String(describing: route))")
            return
        }
        // A second tap on the author whose profile was just pushed is the same
        // request, not a second push: during the slide the new profile is
        // already the top screen. A second tap on the same `@handle` too,
        // while the profile it pushed is still resolving it.
        // Either way round: the top profile answers to the id a handle
        // resolved to, and to the handle a profile opened by id loaded.
        if isRepeatProfile(route, using: navigator) {
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
            let profile = makeProfile(profileID, stub: stub)
            // ⚠️ AT ONCE, ON ITS LOADING STATE (#778, the owner's rule
            // 2026-10-10: a push never waits on data). The header redacts in
            // place and the gallery shows its bones; the data cross-fades in
            // over the very frames it will occupy. It used to be held up to
            // 250 ms for its data (`PresentationHold`, charter P12a).
            pushProfile(profile, for: route, using: navigator)

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

        case .profileCard:
            // ⚠️ THE VIEWER'S OWN PILL PUSHES THEIR PROFILE (#1524): a card
            // of oneself has nothing to act on.
            switch route.profileCardResolution {
            case .presentCard(let profileID, let stub):
                presentProfileCard(profileID, stub: stub, using: navigator)
            case .pushProfile(let profile):
                self.route(to: profile)
            case nil:
                break
            }

        case .profileHandle(let handle):
            // A tapped `@handle` or a `core-platform.click/@handle` link (#524). ⚠️ PUSHED
            // AT ONCE (#800): the profile resolves the handle behind its
            // skeleton, then loads like an author's. The lookup used to run
            // here first, with nothing on screen for the whole round trip. A
            // handle that names no one (renamed, deleted) says so inside the
            // pushed screen, and one that could not be asked offers Try Again.
            //
            // Your own handle lands on a routed profile, as it did when this
            // looked the id up and routed `.profile(id, stub: nil)`.
            routeToReference(.handle(handle), for: route, using: navigator)

        case .profileShareToken(let token):
            // A scanned QR code or a `core-platform.click/s/<token>` link (#412): pushed at
            // once and resolved by the screen, like a handle. A token the owner
            // reset, or links they switched off, read as no one.
            routeToReference(.shareToken(token), for: route, using: navigator)

        case .place(let link):
            // A shared place (#985): the page alone, a plain push like a
            // hashtag's.
            guard let page = makePlacePage(link) else {
                logger.info("route .place: no page for \(String(describing: link), privacy: .public)")
                return
            }
            push(page, using: navigator)

        case .hashtag(let tag):
            // A tapped `#tag`, a hashtag completion, a searched `#tag` (#524):
            // a plain push, like a post's detail.
            push(searchFeature().makeHashtagViewController(tag: tag), using: navigator)

        case .post(let postID):
            // ONE POST SCREEN (#1577): the vertical feed on that post — a tapped
            // push notification, `-open-post`. A plain push the platform's own
            // edge pop dismisses, as `.postStream` explains.
            let feed = feedFeature().makePostFeedViewController(for: postID, opensComments: false)
            feed.hidesBottomBarWhenPushed = true
            push(feed, using: navigator)

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
            // The same screen, its comments up (#1577).
            let feed = feedFeature().makePostFeedViewController(for: postID, opensComments: true)
            feed.hidesBottomBarWhenPushed = true
            push(feed, using: navigator)

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

        case .supervisionInvite(let code):
            // A family invite link or QR code (#417): the accept screen, the
            // code filled in. A guest signs up first (`gatedAction`).
            guard let accept = profileFeature().makeSupervisionAcceptViewController(code: code) else {
                logger.debug("No supervision on this account; dropping the invite link")
                return
            }
            push(accept, using: navigator)

        case .supervision(let otherAccountID):
            // A supervision notification (#1106): Family and Teens, then
            // that link's page if it still exists.
            guard let page = profileFeature().makeFamilyAndTeensViewController(openingSupervisionWith: otherAccountID) else {
                logger.debug("No account; dropping the supervision route")
                return
            }
            push(page, using: navigator)

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
    /// The profile a handle or a token names, pushed before anyone knows whose
    /// it is (#800).
    private func routeToReference(
        _ reference: ProfileReference, for route: AppRoute, using navigator: AppNavigating
    ) {
        let profile = profileFeature().makeProfileViewController(resolving: reference, lookup: lookupProfile)
        // The balance rides the push, as on an author's profile.
        attachBalance(profile)
        pushProfile(profile, for: route, using: navigator)
    }

    /// The profile a `.profile` route pushes — the viewer's own when the
    /// stub says so — with the balance on its bar, attached BEFORE any push so
    /// the item rides it instead of popping in after.
    private func makeProfile(_ profileID: ProfileID, stub: ProfileIdentityStub?) -> UIViewController {
        let profile: UIViewController = if stub?.isSelf == true {
            profileFeature().makeCurrentUserProfileViewController(onLogout: nil, identityStub: stub)
        } else {
            profileFeature().makeProfileViewController(for: profileID, identityStub: stub)
        }
        attachBalance(profile)
        return profile
    }

    /// The profile card (#1524), over whatever the active stack shows on
    /// top — a full-screen post included. Its "open the profile" pushes the
    /// profile through `.profile` once the card has closed, and its lists
    /// push on the same stack.
    private func presentProfileCard(_ profileID: ProfileID, stub: ProfileIdentityStub?, using navigator: AppNavigating) {
        guard let navigation = navigator.activeNavigationController else { return }
        var presenter: UIViewController = navigation
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        let card = profileFeature().makeProfileCardViewController(
            for: profileID, identityStub: stub,
            openProfile: { [weak self] in self?.route(to: .profile(profileID, stub: stub)) },
            push: { [weak self, weak navigator] screen in
                guard let self, let navigator else { return }
                push(screen, using: navigator)
            }
        )
        // `-profile-window` (#1874): the profile opens as a window out of the
        // sheet, onto the post screen's pill, when the screen under the card
        // is one a window can close onto.
        if let source = navigation.topViewController as? any ProfileWindowSource,
           source.opensProfileWindows,
           let launching = Self.windowLaunching(in: card) {
            launching.opensProfileThroughWindow = { [weak self, weak source] launch in
                guard let self, let source else { return }
                open(.profile(profileID, stub: stub), throughWindowOf: source, launch: launch)
            }
        }
        presenter.present(card, animated: true)
    }

    /// The card inside its sheet's wrapper, when it can open a window.
    private static func windowLaunching(in card: UIViewController) -> (any ProfileWindowLaunching)? {
        (card as? any ProfileWindowLaunching)
            ?? ((card as? UINavigationController)?.viewControllers.first as? any ProfileWindowLaunching)
    }

    /// The screen a route would push, for a caller that pushes it itself —
    /// a swipe's interactive push (#1525). A profile only, for now: what a
    /// leftward swipe hangs on the feed and the conversation. Profile routes
    /// are not gated, so a guest gets one too.
    func destination(for route: AppRoute) -> UIViewController? {
        switch route {
        case .profile(let profileID, let stub):
            return makeProfile(profileID, stub: stub)
        default:
            return nil
        }
    }

    /// Records a profile push for the repeat filter, under the route's own
    /// key (its id, or the handle / token it still resolves), then pushes it.
    private func pushProfile(_ profile: UIViewController, for route: AppRoute, using navigator: AppNavigating) {
        if let key = route.profileRouteKey {
            repeatProfiles.willPush(
                key, screen: profile,
                isTransitioning: navigator.activeNavigationController?.transitionCoordinator != nil
            )
        }
        push(profile, using: navigator)
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
        // Linking a family account needs one.
        case .supervisionInvite, .supervision:
            .supervision
        default:
            nil
        }
    }
}
