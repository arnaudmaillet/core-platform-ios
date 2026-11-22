import CoreModels
import MapsInterface
import PostGrid
import ProfileData
import ProfileInterface

// The view model's value types (#2522): what it publishes and what its
// commands answer. Read by both screens and the tests as `ProfileViewModel.X`.
extension ProfileViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        /// Not loaded yet, but the person is known from where they were
        /// opened (#1859): their identity is drawn, their counters wait.
        case seeded(ProfileSeedModel)
        case content(ProfileDisplayModel)
        case failed(message: String)
        /// The handle or link named no one (#800). An answer, not a failure:
        /// there is nothing to try again.
        case notFound(message: String, detail: String?)
    }

    /// Whose profile this view model loads.
    public nonisolated enum Source: Equatable, Sendable {
        case currentUser
        case profile(ProfileID)
        /// A handle or a share token, resolved once the screen is up (#800):
        /// it becomes `.profile` with the id the lookup answers.
        case lookup(ProfileReference)
    }

    /// The header's action button. `hidden` until the relationship is known, so
    /// the button never flickers a wrong state on first paint.
    public nonisolated enum FollowButton: Equatable, Sendable {
        case hidden
        case edit
        case follow
        case following
        /// A private profile the viewer asked to follow (#396); tapping it
        /// withdraws the request.
        case requested
        /// Someone else's profile the viewer cannot follow (#726): no Follow,
        /// Message and the menu stay.
        case unavailable

        /// Someone else's profile, whatever the follow state.
        var isOtherProfile: Bool {
            self == .follow || self == .following || self == .requested || self == .unavailable
        }
    }

    /// The map-favorite pin (the "Map" submenu).
    ///
    /// Carries the RAILS the profile is on rather than a bare on/off, because
    /// a mutual can be on Friends, on Following, on both, or on neither, and
    /// the menu that edits that has to show which. `hidden` is a third state
    /// on purpose: "no button" and "an unfavorited button" are different
    /// products — the pin is offered ONLY for a profile the viewer follows
    /// (the map's people rails are a shortcut through the people you already
    /// keep up with), and only when the app was wired with somewhere to keep
    /// them.
    public nonisolated enum MapPinButton: Equatable, Sendable {
        /// Not offered: own profile, a stranger, an unresolved relationship,
        /// or no pinning service.
        case hidden
        /// Offered. `categories` is what the map currently shows (empty = on
        /// no rail); `includesFriends` is true for a MUTUAL, the only viewer
        /// for whom the Friends row exists at all.
        ///
        /// The pin always opens the checklist now: with three rails, even
        /// someone merely followed has two of them (the dock and the Following
        /// row), and a single toggle could not say which.
        case shown(categories: Set<MapFavoriteCategory>, includesFriends: Bool)

        /// Whether the pin reads as filled — on ANY rail counts.
        public var isFavorited: Bool {
            if case .shown(let categories, _) = self { return !categories.isEmpty }
            return false
        }

        public var categories: Set<MapFavoriteCategory> {
            if case .shown(let categories, _) = self { return categories }
            return []
        }

        /// Whether the Friends row belongs in this profile's checklist.
        public var includesFriends: Bool {
            if case .shown(_, let includesFriends) = self { return includesFriends }
            return false
        }
    }

    /// One horizontal page of the gallery pager.
    public nonisolated enum GalleryPageState: Equatable, Sendable {
        case loading
        case content([GalleryPost])
        /// The page's combination has nothing to show; `message` names it so
        /// the blank grid reads intentional, not broken.
        case empty(message: String)
        case failed(message: String)
        /// A private profile the viewer doesn't follow (guests included): its
        /// posts are its followers' (#447, backend #691), so the server sends
        /// none — which is not "nothing here".
        case restricted(title: String, message: String)
    }

    /// The outcome of an overflow-menu command, for the view to surface. The
    /// view model never presents anything itself — it names what happened and
    /// the controller chooses the alert/toast.
    public nonisolated enum ActionResult: Equatable, Sendable {
        /// `profileCount` is how many profiles the block actually covered — 1
        /// for a profile-scoped block, and for an account-scoped one however
        /// many aliases were reachable (which can also be 1; see
        /// `ProfileBlockScope`). Reported rather than assumed, so the
        /// confirmation can't overstate what happened.
        case blocked(handle: String, profileCount: Int)
        case unblocked(handle: String)
        /// The mute now in force; none means unmuted.
        case muteChanged(handle: String, scopes: MuteScopes)
        /// Restricted (#416) or no longer.
        case restrictChanged(handle: String, restricted: Bool)
        case reported
        case failed(message: String)
        /// A follow change the server refused, already rolled back on the
        /// button (#802). Not `failed`, which is an alert: the button shows
        /// the truth again, so there is nothing to dismiss — a failure toast
        /// says why it flipped back, where a silent rollback read as a glitch.
        case followFailed(message: String)
        /// An action shown with Undo (#957) the server refused when its
        /// countdown ran out: already put back on screen, said in a failure
        /// toast.
        case commitFailed(message: String)
    }

    /// Which follow change failed, for its message.
    public nonisolated enum FollowAttempt: Sendable {
        case follow, unfollow, request, withdraw
    }

    /// The words of a refused follow change (#802) — short, no period, the
    /// toast's rule.
    public nonisolated static func followFailureMessage(handle: String?, change: FollowAttempt) -> String {
        let who = handle ?? "this profile"
        switch change {
        case .follow: return "Couldn't follow \(who)"
        case .unfollow: return "Couldn't unfollow \(who)"
        case .request: return "Couldn't ask to follow \(who)"
        case .withdraw: return "Couldn't withdraw your request"
        }
    }
}
