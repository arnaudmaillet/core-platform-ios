import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import Foundation
import MapsInterface
import PostGrid
import ShareSheet

@MainActor
public final class ProfileViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content(ProfileDisplayModel)
        case failed(message: String)
    }

    /// Whose profile this view model loads.
    public nonisolated enum Source: Equatable, Sendable {
        case currentUser
        case profile(ProfileID)
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

    /// The map-favorite star beside Message.
    ///
    /// Carries the RAILS the profile is on rather than a bare on/off, because
    /// a mutual can be on Friends, on Following, on both, or on neither, and
    /// the menu that edits that has to show which. `hidden` is a third state
    /// on purpose: "no button" and "an unfavorited button" are different
    /// products — the star is offered ONLY for a profile the viewer follows
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
        /// The star always opens the checklist now: with three rails, even
        /// someone merely followed has two of them (the dock and the Following
        /// row), and a single toggle could not say which.
        case shown(categories: Set<MapFavoriteCategory>, includesFriends: Bool)

        /// Whether the star reads as filled — on ANY rail counts.
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
    }

    /// Every page at once — the pager renders every page (neighbors are
    /// visible mid-swipe), so the view model always answers for all of them.
    /// The source filter is a global modifier: it is already applied to each
    /// page's content here.
    public nonisolated struct GallerySnapshot: Equatable, Sendable {
        /// Posts: every post, the list laid out like For You (#631).
        public var activity: GalleryPageState
        /// The media among them — the gallery Posts' "View all" pushes.
        public var media: GalleryPageState
        /// Whether no further page is coming, under the active source. What
        /// lets the Posts list settle its tail chunk (`MosaicChunkPlanner`).
        public var isComplete: Bool = true
        /// The viewer's saved pile. Absent on anyone else's profile — a saved
        /// list is private by construction. Own profile only.
        public var saved: GalleryPageState = .empty(message: "")
        /// ⚠️ Always the same answer, and honestly so. `engagement.v1` can
        /// record a reaction and count reactions on a post; nothing anywhere
        /// answers "which posts did this profile react to", and the client
        /// cannot even read back whether IT reacted to one. The tab exists so
        /// the shape is right when a seam arrives; what it shows until then is
        /// the truth about what can be known.
        public var reactions: GalleryPageState = .empty(message: "")
        /// The profile's reposts and the posts that tag it, each its own page
        /// (#696; your own profile too since #772).
        public var reposts: GalleryPageState = .empty(message: "")
        public var tagged: GalleryPageState = .empty(message: "")
        /// Whether no further page is coming for Reposts and for Tagged: each
        /// follows its own corpus, apart from `isComplete`.
        public var repostsComplete = true
        public var taggedComplete = true

        public func state(for tab: ProfileTab) -> GalleryPageState {
            switch tab {
            case .format(.activity): activity
            case .format(.media): media
            // No page since #631: its text posts are cards on Posts.
            case .format(.short): .empty(message: "")
            case .saved: saved
            case .reactions: reactions
            case .reposts: reposts
            case .tagged: tagged
            }
        }

        /// Whether `tab`'s list has every page it will get.
        public func isComplete(for tab: ProfileTab) -> Bool {
            switch tab {
            case .reposts: repostsComplete
            case .tagged: taggedComplete
            default: isComplete
            }
        }
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
        /// One of the viewer's posts went to Recently Deleted (#408).
        case postDeleted
        case reported
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onFollowButtonChange: ((FollowButton) -> Void)?
    /// Fires once the first relationship read has ANSWERED, whatever it
    /// answered — including a failure, which leaves the button `.hidden` and
    /// is still an answer: nothing more is coming for the screen to wait on.
    public var onRelationshipSettled: (() -> Void)?
    public var onMapPinButtonChange: ((MapPinButton) -> Void)?
    public var onGalleryChange: ((GallerySnapshot) -> Void)?
    /// Fired when a load finishes, however it finished — new data, identical
    /// data, or a failure. The view uses it to close out a switch, which it
    /// cannot infer from `onPhaseChange`: a revalidation that agrees with the
    /// cache publishes no phase at all.
    public var onLoadSettled: (() -> Void)?
    /// Fires when an overflow-menu command settles. Paired with
    /// `onDismissRequested` for block, which both reports and leaves.
    public var onActionResult: ((ActionResult) -> Void)?
    /// Fires after a successful block: the screen should leave (pop to the
    /// origin, or dismiss if it was presented). Never fires for the viewer's
    /// own profile, which cannot be blocked.
    public var onDismissRequested: (() -> Void)?

    private let repository: any ProfileProviding
    /// Curates the map's people rail. Nil in tests and in any app that did not
    /// wire Maps — the button is then simply not offered, which is the honest
    /// state rather than a button that cannot do anything.
    private let mapPinning: (any MapProfilePinning)?
    private let reporting: (any ContentReporting)?
    private let gallery: (any ProfileGalleryProviding)?
    /// The global gallery-filter preference. nil (tests, minimal setups)
    /// means "session-local": the filter starts at the default and isn't
    /// persisted.
    private let galleryPreferences: GalleryPreferences?
    /// The viewer's saved pile — client-owned, because nothing on the wire
    /// carries one. Absent on anyone else's profile, and absent in the many
    /// setups that never show a Saved tab at all.
    /// Read by the gallery's rows too, so a card's save control and the
    /// Saved tab share one pile.
    let bookmarks: PostBookmarkStore?
    /// The saved pile's tiles, once hydrated. Held because the pile can change
    /// while the screen is up (a post unsaved from the feed underneath) and the
    /// snapshot is rebuilt from parts.
    private var savedPage: GalleryPageState = .empty(message: "Nothing saved yet.")
    private let source: Source
    private let router: (any Router)?
    /// Last-known profiles, shared app-wide. Nil in compositions without one
    /// (tests), which simply never seed.
    private let cache: ProfileCache?
    private let shareLinks: (any ShareLinkManaging)?
    /// The own profile's share token (#412), once fetched. Until then, and
    /// on someone else's profile, the link is the `/@handle` one.
    private var shareToken: String?

    private var recovery: RecoveryObservation?
    /// The monitor whose recoveries reload this store — the shared one; a
    /// test hands its own (the shared one is process-wide).
    var connectivity: ConnectivityMonitor = .shared
    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var followButton: FollowButton = .hidden {
        didSet {
            // ⚠️ AN ANSWER THAT AGREES WITH THE SCREEN SAYS NOTHING. Every
            // refresh reads the relationship again, and each identical answer
            // used to re-pose the tray's capsule, cross-dissolve the whole
            // navigation bar and re-ask the map star — a landing turn's worth
            // of work, on a pull-to-refresh, to arrive where it already was.
            guard followButton != oldValue else { return }
            onFollowButtonChange?(followButton)
            // The pin is offered only while the viewer follows, so the two
            // move together — including the optimistic flip a follow tap makes
            // before the server has answered. A newly-followed profile has
            // never been asked about, so ask now.
            refreshMapPinButton()
            loadMapPinState()
        }
    }
    public private(set) var mapPinButton: MapPinButton = .hidden {
        didSet {
            guard mapPinButton != oldValue else { return }
            onMapPinButtonChange?(mapPinButton)
        }
    }
    /// Which rails the service last reported (or an optimistic tap set);
    /// `nil` until it has been asked.
    ///
    /// Optional so the button is not shown wearing a guess: resolving the
    /// never-curated fallbacks can take a round trip, and an outline star that
    /// silently fills in is a worse first impression than a button that
    /// arrives a frame late. Kept apart from `mapPinButton` so the answer
    /// survives the button being hidden and shown again — unfollowing does NOT
    /// unfavorite, by product decision, and re-following should not have to
    /// ask again.
    private var mapCategories: Set<MapFavoriteCategory>?
    /// Whether they follow back. Only a mutual may be kept on the Friends
    /// rail, so only a mutual is offered the choice.
    private var isMutual = false
    /// Supersedes an in-flight read when the subject changes, so a slow answer
    /// about the previous profile cannot land on this one.
    private var mapPinReadTask: Task<Void, Never>?

    /// The currently rendered profile — retained so a follow toggle can nudge
    /// its follower count without a full reload.
    /// The profile as last loaded (or seeded from the cache), for whoever
    /// opens a screen that needs it in hand — the editor, for one.
    public private(set) var profile: UserProfile? {
        didSet {
            // Only a change of SUBJECT matters here: an optimistic follower
            // nudge rebuilds this value for the same person, and re-asking
            // about their pin state on every count change would be noise.
            guard profile?.id != oldValue?.id else { return }
            mapCategories = nil
            refreshMapPinButton()
            loadMapPinState()
        }
    }
    private var isFollowing = false
    /// Internal for tests: a follow, request or withdrawal still on its way.
    private(set) var followInFlight = false
    /// The viewer's outbound block on this profile, from the relationship read
    /// and kept current by `setBlocked`. Drives which of Block / Unblock the
    /// overflow menu offers.
    public private(set) var isBlocked = false
    private var blockInFlight = false
    private var reportInFlight = false
    /// What of this profile the viewer has muted (#403), read beside the
    /// relationship; the nav bar's bell shows and edits it (#689).
    public private(set) var muteScopes: MuteScopes = .none {
        didSet {
            guard muteScopes != oldValue else { return }
            onMuteScopesChange?(muteScopes)
        }
    }
    /// Fires when `muteScopes` changes — a read landing, a toggle, or its
    /// rollback — so the bell's glyph follows without a re-push.
    public var onMuteScopesChange: ((MuteScopes) -> Void)?
    private(set) var muteInFlight = false
    /// Bumped by every mute toggle, so a read that started before one can't
    /// land after it and put the old scopes back.
    private var muteGeneration = 0
    /// Whether this composition can mute at all.
    public var canMute: Bool { repository is any ProfileMuting }
    /// Whether the viewer restricts this profile (#416), read beside the mute.
    public private(set) var isRestricted = false
    private var restrictInFlight = false
    /// Same guard as `muteGeneration`, for restrict.
    private var restrictGeneration = 0
    public var canRestrict: Bool { repository is any ProfileRestricting }

    private var load: Task<Void, Never>?
    private var relationshipLoad: Task<Void, Never>?
    /// Whether the follow state on screen is an answer rather than a wait:
    /// a relationship read has come back (or failed), or a cache seeded one.
    public private(set) var isRelationshipSettled = false {
        didSet {
            guard isRelationshipSettled, !oldValue else { return }
            onRelationshipSettled?()
        }
    }

    // MARK: Gallery state

    public private(set) var galleryFilter = GalleryFilter()
    /// The page on screen's source (`gallerySource`), on every profile (#772).
    private var pageSource: GalleryFilter.Source = .posts
    /// The authored fetch (Posts + Reposts split it) and the tagged fetch,
    /// cached so selector/kind changes recompute locally without round trips.
    /// nil = in flight (page shows loading); a failure records instead.
    private var authoredCache: [GalleryPost]?
    private var taggedCache: [GalleryPost]?
    private var authoredFailed = false
    private var taggedFailed = false
    private var galleryLoad: Task<Void, Never>?
    /// Where each corpus's next page starts; nil when it has no more, or
    /// before its first page answered (#634).
    private var authoredToken: String?
    private var taggedToken: String?
    /// Pages beyond the first are loaded: a revalidation merges its first
    /// page over them rather than cutting the corpus back to one page.
    private var authoredHasLaterPages = false
    private var taggedHasLaterPages = false
    /// The next page(s) on their way — one round at a time.
    private var galleryMoreLoad: Task<Void, Never>?
    /// Pages walked through in a row that add nothing to the tab on screen
    /// (Short over a run of photos) before waiting for the next approach.
    static let maxUnchangedGalleryPages = 5
    /// The last next-page round failed: the grid stops asking on its own
    /// (an empty tab would otherwise retry in a tight loop) until the viewer
    /// approaches the end again, or pulls to refresh.
    private var galleryMorePausedByFailure = false

    public init(
        repository: any ProfileProviding,
        mapPinning: (any MapProfilePinning)? = nil,
        reporting: (any ContentReporting)? = nil,
        gallery: (any ProfileGalleryProviding)? = nil,
        galleryPreferences: GalleryPreferences? = nil,
        bookmarks: PostBookmarkStore? = nil,
        source: Source = .currentUser,
        router: (any Router)? = nil,
        cache: ProfileCache? = nil,
        followEvents: FollowGraphEvents? = nil,
        shareLinks: (any ShareLinkManaging)? = nil
    ) {
        self.repository = repository
        self.shareLinks = shareLinks
        self.mapPinning = mapPinning
        self.reporting = reporting
        self.gallery = gallery
        self.galleryPreferences = galleryPreferences
        self.bookmarks = bookmarks
        self.source = source
        self.router = router
        self.cache = cache
        // The gallery opens on the user's last GLOBAL source, not a per-
        // profile default — the tray and its menu read this filter as their
        // initial truth.
        //
        // ⚠️ THE FORMAT IS NOT RESTORED (#631). It named one of three pages
        // (Activity / Gallery / Short) and there is one now, Posts — every
        // post. A stored Gallery or Short would narrow the list to media or
        // text with no page to say so.
        if let stored = galleryPreferences?.filter {
            galleryFilter = GalleryFilter(format: .activity, source: stored.source)
        }
        followSubscription = followEvents?.subscribeOnMain { [weak self] change in
            self?.followGraphDidChange(change)
        }
    }

    /// Keeps the Follow button agreeing with a follow accepted ANYWHERE —
    /// the "+" on this person's post in a feed pushed from here, an Unfollow
    /// in a card's menu, a followers list's row — for as long as this profile
    /// lives. See `FollowGraphEvents` for why this is heard, not re-read.
    private var followSubscription: FollowGraphSubscription?

    /// Takes a change about THIS profile the way its own toggle would —
    /// button, and the follower count nudged by one — unless the button says
    /// so already (which is how its own accepted toggle comes back), or its
    /// own toggle is still in flight and about to answer for itself.
    private func followGraphDidChange(_ change: FollowChange) {
        guard let profile, change.profileID == profile.id,
              followButton == .follow || followButton == .following,
              change.isFollowing != isFollowing, !followInFlight else { return }
        applyFollow(change.isFollowing, on: profile)
    }

    /// Whether the "Message" action applies (another user's profile).
    public var canMessage: Bool { followButton.isOtherProfile }

    /// Whether the moderation actions (Block / Report) apply. False for the
    /// viewer's own profile, and false until the relationship is known — a
    /// menu opened mid-load offers sharing only rather than guessing.
    public var canModerate: Bool { followButton.isOtherProfile }

    /// Everything the share sheet renders, resolved together so the QR code,
    /// the card, and the system share sheet's link preview cannot disagree
    /// about who is being shared.
    /// The share payload — the shared sheet's card (`ShareSheet.ShareCard`):
    /// display name, handle (with its leading `@`), avatar, link.
    public typealias ShareCard = ShareSheet.ShareCard

    /// The share payload, once the profile has loaded. `nil` before then —
    /// every share affordance is gated on it rather than rendering a card
    /// with a placeholder identity.
    public var shareCard: ShareCard? {
        profile.map {
            ShareCard(
                displayName: $0.displayName,
                handle: "@" + $0.handle,
                avatarURL: $0.avatarURL,
                url: shareURL(handle: $0.handle)
            )
        }
    }

    /// The profile's shareable link, once the handle is known.
    public var shareLink: URL? {
        profile.map { shareURL(handle: $0.handle) }
    }

    /// The own profile shares its token link (#412), which the owner can turn
    /// off or reset in Activity and Discovery; any other profile, or the own
    /// one before the token arrives, shares its `/@handle` link.
    private func shareURL(handle: String) -> URL {
        if isOwnProfile, let shareToken { return ProfileShareLink.url(shareToken: shareToken) }
        return ProfileShareLink.url(handle: handle)
    }

    /// Fetches the own profile's share token. Called each time the profile
    /// appears, so a reset in Settings is picked up on the way back. A
    /// failure keeps the last token (or the handle link).
    public func refreshShareToken() async {
        guard isOwnProfile, let shareLinks else { return }
        if let token = try? await shareLinks.shareToken() { shareToken = token }
    }

    /// The loaded profile's `@handle`, for naming it in confirmations.
    public var handle: String? { profile.map { "@" + $0.handle } }

    /// The loaded profile's name, for the navigation bar's title.
    ///
    /// ⚠️ THE NAME, NOT THE HANDLE. The bar carried the handle once and it said
    /// again what the identity block says in full a finger's width below it;
    /// the name is what a person is called, and the title is the only place it
    /// survives once the header has scrolled away.
    public var displayName: String? { profile?.displayName }

    /// Whether this screen shows a gallery at all — drives the filter tray's
    /// existence, not just its state.
    public var hasGallery: Bool { gallery != nil }

    /// Whether this screen is the viewer looking at themselves.
    ///
    /// Read from the SOURCE, so it is settled before the first byte arrives —
    /// the pager's page count depends on it and the pages are built once, in
    /// `init`, long before any relationship read resolves.
    ///
    /// ⚠️ Deliberately narrower than the `isSelf` the relationships screen is
    /// handed. That one also accepts a routed-to profile that turns out to be
    /// yours; this one does not, because a profile reached by tapping a handle
    /// is being read as somebody's page rather than as your own, and growing
    /// two extra tabs when the read lands would be a jump.
    public var isOwnProfile: Bool { source == .currentUser }

    /// Everything the followers / following screen needs to open, or `nil`
    /// until the profile has loaded (the counters read "—" until then, so
    /// there is nothing to tap).
    ///
    /// Handed over rather than re-fetched: this screen has already paid for the
    /// profile view *and* the relationship read, which between them carry both
    /// halves of the privacy decision. Making the destination ask again would
    /// put two round trips in front of a state it can otherwise render on the
    /// push's first frame.
    public var relationshipsSubject: ProfileRelationshipsViewModel.Subject? {
        guard let profile else { return nil }
        return ProfileRelationshipsViewModel.Subject(
            id: profile.id,
            handle: profile.handle,
            visibility: profile.visibility,
            viewerFollowsSubject: isFollowing,
            // `.currentUser` is self by construction, before any relationship
            // read has resolved; a routed-to profile becomes self only once
            // the read says so.
            isSelf: source == .currentUser || followButton == .edit,
            // The same counters the header is rendering — so the destination's
            // segmented control shows them without re-reading counter.v1, and
            // an optimistic follow nudge is already reflected in both places.
            followerCount: profile.followerCount,
            followingCount: profile.followingCount
        )
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        armRecovery()
        // ⚠️ A REVISIT RENDERS THE CACHED PROFILE AT FRAME 0 (charter P7). The
        // cache used to be read on an account switch alone; a second visit to
        // a profile opened on a skeleton and re-revealed a page the viewer had
        // seen seconds before. Seeded, the fetch REFRESHES: the phase moves
        // only if something changed, and the gallery revalidates in place
        // rather than resetting to its bones.
        if case .profile(let id) = source, let cached = cache?.profile(for: id) {
            profile = cached
            phase = .content(ProfileDisplayModel(profile: cached))
            loadGallery(for: cached, reset: true)
            galleryWasSeeded = true
        }
        // The relationship is seeded the same way, and for the same reason:
        // a revisit that knew "Following" a minute ago must not open on a
        // placeholder for it. The read in `reload` still runs and corrects.
        if case .profile(let id) = source, let relationship = cache?.relationship(for: id) {
            apply(relationship)
        }
        reload()
    }

    /// True between a cache seed and the fetch that confirms it, so that
    /// fetch revalidates the gallery instead of resetting it.
    private var galleryWasSeeded = false

    /// Reloads after an outage (#793): what failed while the network was gone
    /// comes back on its own when it returns — the viewer no longer has to
    /// find a way to retry, screen by screen.
    private func armRecovery() {
        guard recovery == nil else { return }
        recovery = connectivity.onRecovery { [weak self] in self?.recoverFromOutage() }
    }

    private func recoverFromOutage() {
        // Only a failed profile: every live one (the tab's, every pushed
        // one) revalidating at once on each recovery was a storm.
        guard case .failed = phase else { return }
        refresh()
    }

    /// Pull-to-refresh. Coalesced: a refresh while one is in flight is ignored.
    ///
    /// ⚠️ A REFRESH NEVER FALLS BACK TO BONES. The grid revalidates in place:
    /// what is on screen stays until the new pages land, and pages that came
    /// back identical publish nothing at all. It used to reset the corpora,
    /// so every pull blanked all three pages to their skeletons and rebuilt
    /// them under a cross-dissolve a moment later — the release's hitch.
    public func refresh() {
        guard load == nil else { return }
        reload(galleryRevalidates: true)
    }

    /// Revalidates after an account switch, rendering `id` from cache first
    /// if it is known — the stale half of stale-while-revalidate.
    ///
    /// Returns whether anything was seeded, so the view can choose its
    /// treatment: a hit cross-fades from a real profile to a real profile,
    /// while a miss has nothing truthful to show and wants the skeleton.
    ///
    /// The fetch is NOT coalesced away here. `refresh()` ignores a call while
    /// one is in flight, which is right for a pull-to-refresh but wrong for a
    /// switch: the load already running is for the profile just left, and its
    /// answer is about to be the wrong person.
    @discardableResult
    public func revalidate(after switchedTo: ProfileID?) -> Bool {
        var seeded = false
        if let switchedTo, let cached = cache?.profile(for: switchedTo) {
            profile = cached
            phase = .content(ProfileDisplayModel(profile: cached))
            // The grid is per-profile too, so it starts over for the new one —
            // its skeleton is the honest state until those pages land.
            loadGallery(for: cached, reset: true)
            seeded = true
        }
        reload()
        return seeded
    }

    // MARK: - Map pin

    /// Flips ONE rail, leaving the others exactly as they were — what each row
    /// of the checklist does.
    ///
    /// Optimistic, and deliberately without a rollback: the destination is a
    /// local list (`MapFavoritesStore`), so there is no server to disagree —
    /// the write cannot fail in a way the viewer could act on. What it CAN do
    /// is take a moment, because the very first write to a rail has to
    /// materialize its never-curated fallback, and the row must not sit inert
    /// for it.
    ///
    /// Independent toggles rather than presets: three rails have eight states,
    /// and a viewer reading three checkmarks can see all of them and reach any
    /// in one tap. An earlier menu carried a "Both" row for a state the other
    /// rows already spelled — a shortcut the checkmarks make redundant, and an
    /// item whose meaning (add both? clear both?) depended on state the row
    /// itself could not show.
    public func toggleMapCategory(_ category: MapFavoriteCategory) {
        guard case .shown(let categories, _) = mapPinButton else { return }
        setMapCategories(categories.symmetricDifference([category]))
    }

    /// Puts this profile on exactly these rails — what a checklist row
    /// commits, and what the plain toggle funnels through, so there is one
    /// write path and one optimistic update.
    public func setMapCategories(_ categories: Set<MapFavoriteCategory>) {
        guard mapPinButton != .hidden, let mapPinning, let profile else { return }
        // A non-mutual cannot be a friend, whatever a caller asks for; the
        // Friends row is the map's mutuals row. The dock and the Following row
        // are open to anyone the viewer follows.
        let allowed = isMutual ? categories : categories.subtracting([.friends])
        mapCategories = allowed
        refreshMapPinButton()
        Task { await mapPinning.setCategories(allowed, for: profile.id) }
    }

    /// Re-reads rail membership for the current subject. Called whenever the
    /// subject or the relationship changes — a profile the viewer does not
    /// follow is never asked about, so a stranger's profile costs nothing.
    private func loadMapPinState() {
        mapPinReadTask?.cancel()
        guard let mapPinning, let profile, followButton == .following else { return }
        let id = profile.id
        mapPinReadTask = Task { [weak self] in
            let categories = await mapPinning.categories(for: id)
            guard !Task.isCancelled, let self, self.profile?.id == id else { return }
            self.mapCategories = categories
            self.refreshMapPinButton()
        }
    }

    /// Whether the star's answer is in: not offered at all, or offered with
    /// its rails read. False only while a followed profile's rails are still
    /// being asked for — the star would otherwise land beside Message after
    /// the screen is up and squeeze the tray's capsules to make room.
    public var isMapPinSettled: Bool {
        !(mapPinning != nil && profile != nil && followButton == .following && mapCategories == nil)
    }

    /// The visibility rule, in one place: only a followed profile can be kept
    /// on a rail, and only when there is somewhere to keep them.
    private func refreshMapPinButton() {
        guard mapPinning != nil, profile != nil, followButton == .following,
              let mapCategories else {
            mapPinButton = .hidden
            return
        }
        // A mutual gets the Friends row too; everyone else gets the dock and
        // the Following row.
        mapPinButton = .shown(categories: mapCategories, includesFriends: isMutual)
    }

    /// Follow-button tapped. No-op for the viewer's own profile ("Edit"); an
    /// optimistic toggle otherwise — flip immediately, roll back if the server
    /// rejects. One mutation in flight at a time.
    ///
    /// A private profile is asked rather than followed (#396): Follow turns
    /// into Requested (no follower count moves), and Requested withdraws the
    /// request. The server has the last word: a profile that turned public
    /// meanwhile is followed, one that turned private is asked.
    public func toggleFollow() {
        guard let profile, !followInFlight else { return }
        guard followButton.isOtherProfile, followButton != .unavailable else { return }
        if let requests = repository as? any FollowRequestSending {
            switch followButton {
            case .requested: return withdrawRequest(on: profile, through: requests)
            case .follow: return follow(profile, through: requests)
            default: break
            }
        }

        let target = !isFollowing
        applyFollow(target, on: profile)
        followInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setFollowing(target, for: profile.id)
            } catch {
                // Roll back to the pre-tap state.
                if let current = self.profile {
                    self.applyFollow(!target, on: current)
                }
            }
            self.followInFlight = false
        }
    }

    private func follow(_ profile: UserProfile, through requests: any FollowRequestSending) {
        let asks = profile.visibility == .private
        if asks { showRequested(true) } else { applyFollow(true, on: profile) }
        followInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await requests.follow(profile.id)
                switch (outcome, asks) {
                case (.requested, false):
                    if let current = self.profile { self.applyFollow(false, on: current) }
                    self.showRequested(true)
                case (.following, true):
                    if let current = self.profile { self.applyFollow(true, on: current) }
                default:
                    break
                }
            } catch {
                if asks {
                    self.showRequested(false)
                } else if let current = self.profile {
                    self.applyFollow(false, on: current)
                }
            }
            self.followInFlight = false
        }
    }

    private func withdrawRequest(on profile: UserProfile, through requests: any FollowRequestSending) {
        showRequested(false)
        followInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await requests.cancelFollowRequest(to: profile.id)
            } catch {
                self.showRequested(true)
            }
            self.followInFlight = false
        }
    }

    /// Requested ⇄ Follow. Neither follows, so no count moves.
    private func showRequested(_ requested: Bool) {
        isFollowing = false
        followButton = requested ? .requested : .follow
        rememberRelationship()
    }

    /// "Message" tapped — open a DM with this profile via routing. Profile never
    /// imports Chat; it only emits a route.
    public func messageTapped() {
        guard canMessage, let profile else { return }
        router?.route(to: .messageUser(profile.id, stub: ProfileIdentityStub(
            handle: profile.handle, displayName: profile.displayName
        )))
    }

    /// Send this profile to someone as a DM, with the link pre-typed in their
    /// composer. Route-only, like `messageTapped` — Profile emits the intent
    /// and Chat owns the destination.
    public func sendProfile(_ card: ShareCard, to target: ProfileShareTarget) {
        router?.route(to: .sendLink(card.url.absoluteString, to: target.id, stub: ProfileIdentityStub(
            handle: target.handle, displayName: target.displayName
        )))
    }

    // MARK: - Overflow menu

    /// Block this profile, or the whole account behind it.
    ///
    /// Unlike follow, this is NOT optimistic: a block is a safety action whose
    /// UI consequence is leaving the screen, so it must not be shown as done
    /// and then silently rolled back. The state changes only once the server
    /// accepts. One mutation in flight at a time.
    public func block(_ scope: ProfileBlockScope) {
        guard let profile, canModerate, !blockInFlight, !isBlocked else { return }
        blockInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let count: Int
                switch scope {
                case .profile:
                    try await self.repository.setBlocked(true, for: profile.id)
                    count = 1
                case .account:
                    count = try await self.repository.blockAccount(behind: profile.id).count
                }
                self.isBlocked = true
                // Blocking severs the follow edge server-side; mirror that so
                // a re-entry before the next relationship read agrees.
                self.isFollowing = false
                self.followButton = .follow
                self.rememberRelationship()
                self.onActionResult?(.blocked(handle: "@" + profile.handle, profileCount: count))
                self.onDismissRequested?()
            } catch {
                self.onActionResult?(.failed(message: "Couldn't block this profile."))
            }
            self.blockInFlight = false
        }
    }

    /// Lift a block on this profile. Account-scoped blocks are NOT undone as a
    /// set: the viewer unblocks whichever profile they navigated to, because
    /// the client can't tell which of the account's profiles were blocked
    /// together versus individually — and silently unblocking aliases the user
    /// never asked about is the wrong way to be wrong about a safety action.
    public func unblock() {
        guard let profile, canModerate, !blockInFlight, isBlocked else { return }
        blockInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setBlocked(false, for: profile.id)
                self.isBlocked = false
                self.rememberRelationship()
                self.onActionResult?(.unblocked(handle: "@" + profile.handle))
            } catch {
                self.onActionResult?(.failed(message: "Couldn't unblock this profile."))
            }
            self.blockInFlight = false
        }
    }

    /// Switches one mute scope. Optimistic, unlike block: a mute is a quiet
    /// preference the target never sees, so a rollback costs nothing. The
    /// toast says what is muted now.
    public func toggleMute(_ scope: MuteScope) {
        guard let profile, canModerate, !muteInFlight, let muting = repository as? any ProfileMuting else { return }
        let before = muteScopes
        let after = before.toggling(scope)
        muteScopes = after
        muteInFlight = true
        muteGeneration += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                try await muting.setMuteScopes(after, for: profile.id)
                self.onActionResult?(.muteChanged(handle: "@" + profile.handle, scopes: after))
            } catch {
                self.muteScopes = before
                self.onActionResult?(.failed(message: "Couldn't change what you mute from this profile."))
            }
            self.muteInFlight = false
        }
    }

    /// Restrict or unrestrict. Optimistic, like mute: the target never sees it.
    public func toggleRestrict() {
        guard let profile, canModerate, !restrictInFlight, let restricting = repository as? any ProfileRestricting else { return }
        let target = !isRestricted
        isRestricted = target
        restrictInFlight = true
        restrictGeneration += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                try await restricting.setRestricted(target, for: profile.id)
                self.onActionResult?(.restrictChanged(handle: "@" + profile.handle, restricted: target))
            } catch {
                self.isRestricted = !target
                self.onActionResult?(.failed(message: target ? "Couldn't restrict this profile." : "Couldn't unrestrict this profile."))
            }
            self.restrictInFlight = false
        }
    }

    /// "Muted @ada's posts and messages", "Unmuted @ada".
    public nonisolated static func muteMessage(handle: String, scopes: MuteScopes) -> String {
        guard !scopes.isEmpty else { return "Unmuted \(handle)" }
        let names = MuteScope.allCases.filter(scopes.contains).map { $0.title.lowercased() }
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]
        return "Muted \(handle)'s \(list)"
    }

    /// File a moderation report against this profile. Reports are fire-and-
    /// confirm: the result is reported either way, because a report the user
    /// believes was filed but wasn't is the worst outcome here.
    public func report(_ reason: ReportReason) {
        guard let profile, canModerate, !reportInFlight else { return }
        guard let reporting else {
            onActionResult?(.failed(message: "Reporting isn't available right now."))
            return
        }
        reportInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                // The surface is a triage signal: the same profile reported
                // from its own screen and from a post card are different
                // reports.
                try await reporting.report(
                    .profile(profile.id), reason: reason, surface: "ios.profile"
                )
                self.onActionResult?(.reported)
            } catch {
                self.onActionResult?(.failed(message: "Couldn't send this report. Try again."))
            }
            self.reportInFlight = false
        }
    }

    // MARK: - Gallery

    /// A grid tile tapped — open the post. Route-only, like Message.
    /// Opens the unified feed on this post, carrying the gallery's order with
    /// it.
    ///
    /// Was `.post`, which is the single-post DETAIL screen — a dead end that
    /// cannot be swiped out of, and not the surface the rest of the app opens
    /// a tapped tile into. `stream` is the run of posts from the tapped one;
    /// empty only where a caller has no ordering to offer, and then this still
    /// opens the feed rather than falling back to the old screen.
    ///
    /// ⚠️ **The FALLBACK path, not the ordinary one.** A composition root that
    /// wired `feedHero` (which the app's does, always) opens every tapped post
    /// through the feed's own presentation seam instead — hero flight or plain
    /// push, decided there. This remains for the roots that wire nothing:
    /// previews, tests, and any future host that wants posts without the feed
    /// feature. It used to also serve text-only posts on the real app, which is
    /// how they ended up on a bare push with no dismissal gesture and the tab
    /// bar over them; see `ProfileViewController.onItemTapped`.
    public func galleryItemTapped(_ postID: PostID, stream: [PostID] = []) {
        router?.route(to: .postStream(stream.isEmpty ? [postID] : stream))
    }

    /// A gallery row's author was tapped.
    ///
    /// Routed like any other author tap — an ordinary push onto the current
    /// stack — EXCEPT when it names the profile already on screen, which is
    /// most of this gallery: pushing a copy of the screen the viewer is looking
    /// at is not navigation. The Tagged tab is the case this exists for, where
    /// the rows are other people's posts.
    public func galleryAuthorTapped(_ post: GalleryPost) {
        guard let authorID = post.authorID, authorID != profile?.id else { return }
        // The stub is what the row already drew — the destination titles itself
        // in the push's own frame rather than after its own round trip.
        router?.route(to: .profile(authorID, stub: post.authorIdentityStub))
    }

    /// Whether a gallery row may offer Report.
    ///
    /// No seam, no row — a screen that cannot file withholds the action rather
    /// than showing one that cannot act.
    ///
    /// And never for the viewer's OWN post. A report is a complaint about
    /// someone else's content; offered on your own it reads as a bug, and it is
    /// the only row this menu has, so the whole "..." disappears with it. The
    /// Tagged tab is why this is a per-POST question rather than a per-screen
    /// one: those rows are other people's posts on your own profile.
    /// Whether a gallery post is the VIEWER's own: on their own profile, a
    /// post whose author is the profile. Anyone else's post there (the Tagged
    /// tab) is not, and neither is anything on someone else's profile.
    public func isViewerPost(by authorID: ProfileID?) -> Bool {
        guard let authorID, let profile else { return false }
        return followButton == .edit && authorID == profile.id
    }

    /// Whether the viewer's own posts can be deleted here (#408).
    public var canDeletePosts: Bool { gallery is any PostTrashManaging }

    /// Deletes one of the viewer's own posts. Not optimistic: the tile leaves
    /// once the server has the tombstone, so a refused delete never shows a
    /// post gone and back. It can be restored for 30 days from Settings →
    /// Your Activity → Recently Deleted.
    public func deletePost(_ postID: PostID) {
        guard let profile, followButton == .edit, let trash = gallery as? any PostTrashManaging else { return }
        Task { [weak self] in
            do {
                try await trash.deletePost(postID, author: profile.id)
                guard let self else { return }
                self.authoredCache?.removeAll { $0.id == postID }
                self.renderGallery()
                self.onActionResult?(.postDeleted)
            } catch {
                self?.onActionResult?(.failed(message: "Couldn't delete this post. Try again."))
            }
        }
    }

    public func canReportPost(by authorID: ProfileID?) -> Bool {
        guard reporting != nil else { return false }
        // `canModerate` is false exactly on the viewer's own profile, and there
        // an author matching the profile IS the viewer.
        return canModerate || authorID != profile?.id
    }

    /// File a moderation report against one of the gallery's posts. Same
    /// fire-and-confirm contract as `report(_:)`, and the same reason: a report
    /// the user believes was filed but wasn't is the worst outcome here.
    public func reportPost(_ postID: PostID, reason: ReportReason) {
        guard let reporting else {
            onActionResult?(.failed(message: "Reporting isn't available right now."))
            return
        }
        Task { [weak self] in
            do {
                try await reporting.report(
                    .post(postID), reason: reason, surface: "ios.profile.gallery"
                )
                self?.onActionResult?(.reported)
            } catch {
                self?.onActionResult?(.failed(message: "Couldn't send this report. Try again."))
            }
        }
    }

    /// Where the user is — set by a tab tap or a settled swipe. Pure state
    /// (pages are always computed): the view pages to it, empty messages
    /// name it, and the choice persists globally for the next profile.
    public func setGalleryFormat(_ format: GalleryFilter.Format) {
        galleryFilter.format = format
        galleryPreferences?.filter = galleryFilter
        // A tab the loaded pages leave empty fills itself as it arrives.
        fillEmptyGalleryTab()
    }

    /// The page on screen. Format pages set the format (above); the page
    /// also picks the corpus the paging, "View all" and a feed's continuation
    /// read (#696) — on your own profile too since #772. Saved and Liked read
    /// no corpus of the profile's and leave it on Posts.
    public func setActiveTab(_ tab: ProfileTab) {
        if let format = tab.format { setGalleryFormat(format) }
        let source: GalleryFilter.Source = switch tab {
        case .reposts: .reposts
        case .tagged: .tagged
        default: .posts
        }
        guard source != pageSource else { return }
        pageSource = source
        // The media "View all" shows, and an empty page fills itself.
        renderGallery()
    }

    /// The source the page on screen reads.
    ///
    /// ⚠️ EVERY PROFILE'S PAGES ARE ITS SOURCES (#696, and your own since
    /// #772): Posts (its own posts, reposts excluded), Reposts, Tagged. So it
    /// always opens on Posts. The stored filter's source — the top menu your
    /// own profile had — is read by nothing any more.
    var gallerySource: GalleryFilter.Source { pageSource }

    /// Fetches both corpora concurrently once the profile is known (the pager
    /// shows neighbors mid-swipe, so tagged can't be lazy). Called from the
    /// profile load path; `reset` makes pull-to-refresh refresh the grid too.
    private func loadGallery(for profile: UserProfile, reset: Bool) {
        guard let gallery else { return }
        if reset {
            // A reset lands on Posts — the only page shown while the sources
            // reload (#742) — so the source goes back with it (#772).
            pageSource = .posts
            galleryLoad?.cancel()
            galleryLoad = nil
            galleryMoreLoad?.cancel()
            galleryMoreLoad = nil
            authoredCache = nil
            taggedCache = nil
            authoredFailed = false
            taggedFailed = false
            authoredToken = nil
            taggedToken = nil
            authoredHasLaterPages = false
            taggedHasLaterPages = false
        }
        guard galleryLoad == nil else { return }
        galleryMorePausedByFailure = false
        renderGallery() // all pages report loading — or, revalidating, what they hold
        galleryLoad = Task { [weak self] in
            async let authoredFetch = gallery.authoredPage(for: profile.id, after: nil)
            async let taggedFetch = gallery.taggedPage(for: profile.id, handle: profile.handle, after: nil)

            // The two fetches fail independently: one page family degrading
            // must not blank the other.
            let authored = try? await authoredFetch
            let tagged = try? await taggedFetch
            guard let self, !Task.isCancelled else { return }

            // A revalidation over pages beyond the first merges into them —
            // and, failing, leaves them as they are rather than blanking them.
            if self.authoredHasLaterPages, let shown = self.authoredCache {
                if let authored { self.authoredCache = Self.mergingGallery(firstPage: authored.posts, over: shown) }
            } else {
                self.authoredCache = authored?.posts
                self.authoredFailed = authored == nil
                self.authoredToken = authored?.nextPageToken
            }
            if self.taggedHasLaterPages, let shown = self.taggedCache {
                if let tagged { self.taggedCache = Self.mergingGallery(firstPage: tagged.posts, over: shown) }
            } else {
                self.taggedCache = tagged?.posts
                self.taggedFailed = tagged == nil
                self.taggedToken = tagged?.nextPageToken
            }
            self.galleryLoad = nil
            self.renderGallery()
        }
    }

    /// The viewer neared the end of the grid on screen: the next page of
    /// every corpus its source reads, if any has one and none is on its way
    /// (#634). Appended below what is shown; a failure is retried on the next
    /// approach.
    /// The posts after `id` on the tab the viewer is on, for a full-screen
    /// feed opened from the grid (#638): what the grid holds past it, then
    /// its next pages, under the same source — the same order the grid
    /// shows, so a post the feed reaches is a tile the grid also has.
    ///
    /// `nil`: nothing follows and the corpora have no more. EMPTY: none yet
    /// (a page failed, or the first load is still out); the feed asks again
    /// on its next approach.
    ///
    /// `format` is the list the feed was opened from: Posts, or the media
    /// gallery its "View all" pushes (#631).
    public func galleryPostIDs(
        after id: PostID, in format: GalleryFilter.Format = .activity
    ) async -> [PostID]? {
        for _ in 0..<Self.maxUnchangedGalleryPages {
            let tiles = galleryTiles(format)
            guard let index = tiles.firstIndex(where: { $0.id == id }) else { return nil }
            let following = tiles[(index + 1)...]
            if !following.isEmpty { return following.prefix(Self.continuationWindow).map(\.id) }
            guard galleryTokensToFollow() != (nil, nil) else { return nil }
            if galleryMoreLoad == nil { loadMoreGallery() }
            // Not started: the first load is still out.
            guard let round = galleryMoreLoad else { return [] }
            await round.value
            if galleryMorePausedByFailure { return [] }
        }
        return []
    }

    /// How many posts a feed opened from the grid is handed per step.
    static let continuationWindow = 12

    public func loadMoreGallery() {
        galleryMorePausedByFailure = false
        startGalleryPages()
    }

    /// A tab on screen that the loaded pages leave empty has no tile to come
    /// on screen and ask for more: it asks here — unless the last round
    /// failed, which waits for the viewer.
    private func fillEmptyGalleryTab() {
        guard !galleryMorePausedByFailure, galleryTiles(galleryFilter.format).isEmpty else { return }
        startGalleryPages()
    }

    private func startGalleryPages() {
        guard let gallery, let profile, galleryLoad == nil, galleryMoreLoad == nil,
              galleryTokensToFollow() != (nil, nil)
        else { return }
        galleryMoreLoad = Task { [weak self] in
            await self?.appendGalleryPages(from: gallery, for: profile)
        }
    }

    /// The tokens the active source reads through: authored for Posts and
    /// Reposts, tagged for Tagged, both for All.
    private func galleryTokensToFollow(
        _ source: GalleryFilter.Source? = nil
    ) -> (authored: String?, tagged: String?) {
        let source = source ?? gallerySource
        return (
            source == .tagged ? nil : authoredToken,
            source == .all || source == .tagged ? taggedToken : nil
        )
    }

    private func appendGalleryPages(from gallery: any ProfileGalleryProviding, for profile: UserProfile) async {
        for _ in 0..<Self.maxUnchangedGalleryPages {
            let tokens = galleryTokensToFollow()
            guard tokens != (nil, nil) else { break }
            let before = galleryTiles(galleryFilter.format).count
            async let authoredFetch = Self.page(of: tokens.authored) { token in
                try await gallery.authoredPage(for: profile.id, after: token)
            }
            async let taggedFetch = Self.page(of: tokens.tagged) { token in
                try await gallery.taggedPage(for: profile.id, handle: profile.handle, after: token)
            }
            let (authored, tagged) = await (authoredFetch, taggedFetch)
            // A reset since — another profile, a pull that started over —
            // owns the grid now, and the slot with it.
            guard !Task.isCancelled, self.profile?.id == profile.id else { return }
            var failed = false
            if let token = tokens.authored {
                if let page = authored {
                    if authoredToken == token {
                        authoredToken = page.nextPageToken
                        if let grown = Self.appending(page.posts, to: authoredCache) {
                            authoredCache = grown
                            authoredHasLaterPages = true
                        }
                    }
                } else { failed = true }
            }
            if let token = tokens.tagged {
                if let page = tagged {
                    if taggedToken == token {
                        taggedToken = page.nextPageToken
                        if let grown = Self.appending(page.posts, to: taggedCache) {
                            taggedCache = grown
                            taggedHasLaterPages = true
                        }
                    }
                } else { failed = true }
            }
            // The tab on screen gained tiles: they come on screen and ask
            // again. It gained none (Short over a run of photos): no tile will
            // ask, so the next page is asked now — within a bound.
            if failed { galleryMorePausedByFailure = true }
            if failed || galleryTiles(galleryFilter.format).count > before { break }
        }
        // ⚠️ THE SLOT FREES BEFORE THE TILES RENDER: a page that lands wholly
        // on screen asks for the next one while it renders (#596).
        galleryMoreLoad = nil
        renderGallery()
    }

    private static func page(
        of token: String?, _ fetch: @Sendable (String) async throws -> GalleryPage
    ) async -> GalleryPage? {
        guard let token else { return nil }
        return try? await fetch(token)
    }

    /// `shown` with the page's new posts below it, or nil when it brings
    /// none — a post can sit on both sides of a page boundary.
    private static func appending(_ page: [GalleryPost], to shown: [GalleryPost]?) -> [GalleryPost]? {
        let known = Set((shown ?? []).map(\.id))
        let fresh = page.filter { !known.contains($0.id) }
        return fresh.isEmpty ? nil : (shown ?? []) + fresh
    }

    /// A revalidated first page over a corpus that runs past it: the page
    /// replaces every post at least as recent as its oldest, and every older
    /// post stays. Both corpora page newest first, so a post missing from the
    /// fresh page either slid down (older: kept) or went away (newer:
    /// dropped). Pure, for tests.
    static func mergingGallery(firstPage: [GalleryPost], over shown: [GalleryPost]) -> [GalleryPost] {
        guard let oldest = firstPage.map(\.publishedAtMS).min() else { return shown }
        let fresh = Set(firstPage.map(\.id))
        return firstPage + shown.filter { !fresh.contains($0.id) && $0.publishedAtMS < oldest }
    }

    /// The tiles a tab shows under the active source.
    ///
    /// ⚠️ ALL STOPS AT THE FRONTIER. It merges two corpora that page on their
    /// own; a post older than what one of them has reached may still be
    /// followed by newer ones from it, and showing it now would have the next
    /// page land ABOVE tiles already on screen. So All shows only down to the
    /// later of the unfinished corpora's oldest posts — where both are known
    /// — and every page from then on only adds below.
    private func galleryTiles(
        _ format: GalleryFilter.Format, source: GalleryFilter.Source? = nil
    ) -> [GalleryPost] {
        let source = source ?? gallerySource
        let filter = GalleryFilter(format: format, source: source)
        let tiles = filter.tiles(authored: authoredCache ?? [], tagged: taggedCache ?? [])
        guard source == .all, let frontier = allFrontier else { return tiles }
        return tiles.filter { $0.publishedAtMS >= frontier }
    }

    /// The later of the unfinished corpora's oldest loaded posts; nil when
    /// neither has more to load.
    private var allFrontier: Int64? {
        [(authoredToken, authoredCache), (taggedToken, taggedCache)]
            .compactMap { token, cache in token == nil ? nil : cache?.map(\.publishedAtMS).min() }
            .max()
    }

    /// Recomputes the snapshot — Posts, Reposts, Tagged, the media of the page
    /// on screen, Saved — from the caches. Every data landing and page change
    /// funnels here.
    private func renderGallery() {
        guard gallery != nil else { return }

        // Which fetches a source depends on: All needs both, Tagged its own,
        // Posts/Reposts the authored one. A page is loading/failed only when
        // a fetch it actually reads is.
        func page(
            _ format: GalleryFilter.Format, _ source: GalleryFilter.Source, emptyMessage: String? = nil
        ) -> GalleryPageState {
            let readsAuthored = source != .tagged
            let readsTagged = source == .all || source == .tagged
            if (readsAuthored && authoredFailed) || (readsTagged && taggedFailed) {
                return .failed(message: "Couldn't load. Pull to retry.")
            }
            if (readsAuthored && authoredCache == nil) || (readsTagged && taggedCache == nil) {
                return .loading
            }
            let filter = GalleryFilter(format: format, source: source)
            let tiles = galleryTiles(format, source: source)
            guard tiles.isEmpty else { return .content(tiles) }
            // Nothing YET is not nothing: with pages still to load, a tab
            // that none of the loaded posts fill is still loading — or, its
            // last page having failed, says so.
            if galleryTokensToFollow(source) == (nil, nil) {
                return .empty(message: emptyMessage ?? Self.emptyMessage(for: filter))
            }
            return galleryMorePausedByFailure ? .failed(message: "Couldn't load. Pull to retry.") : .loading
        }

        // Three pages, three sources (#696), on every profile since #772; the
        // media "View all" pushes is the page on screen's. The empty pages let
        // their tab speak (`ProfileTab.emptyState`), Posts saying what it
        // holds here. Saved is your own profile's alone.
        let snapshot = GallerySnapshot(
            activity: page(.activity, .posts, emptyMessage: "Posts will appear here."),
            media: page(.media, pageSource),
            isComplete: galleryTokensToFollow(.posts) == (nil, nil),
            saved: isOwnProfile ? savedPage : .empty(message: ""),
            reposts: page(.activity, .reposts, emptyMessage: ""),
            tagged: page(.activity, .tagged, emptyMessage: ""),
            repostsComplete: galleryTokensToFollow(.reposts) == (nil, nil),
            taggedComplete: galleryTokensToFollow(.tagged) == (nil, nil)
        )
        fillEmptyGalleryTab()
        // The same pages again is no news: a revalidation that agrees with
        // the screen must cost the screen nothing.
        guard snapshot != publishedGallery else { return }
        publishedGallery = snapshot
        onGalleryChange?(snapshot)
    }

    /// The pages last handed to the view — what `renderGallery` compares a
    /// new answer against.
    /// The pages last published — what a screen bound after the gallery
    /// landed renders first (#742: its tabs follow what the sources hold).
    public private(set) var publishedGallery: GallerySnapshot?

    /// Rebuilds the Saved page from the pile the viewer has curated.
    ///
    /// ⚠️ Reads the ids EVERY time rather than caching them. The pile is
    /// mutable from outside this screen — the feed's bookmark button writes to
    /// the same store — so the ids are the store's answer at the moment of
    /// asking, not a copy taken when the profile opened.
    ///
    /// A post that no longer resolves simply drops out, the same way a tile
    /// that fails to hydrate does everywhere else. That is the honest behaviour
    /// for a client-owned list pointing at server-owned posts: the pile can
    /// outlive what it points at.
    func loadSavedPosts() {
        guard let bookmarks, let gallery else { return }
        let ids = bookmarks.savedPostIDs
        guard !ids.isEmpty else {
            savedPage = .empty(message: "")
            renderGallery()
            return
        }
        // ⚠️ SKELETONS ONLY FOR A PAGE WITH NOTHING TO SHOW. This runs on
        // every appearance, including the one a closing post delivers, and a
        // `.loading` over shown tiles reloaded the grid as bones mid-dismissal:
        // the card had no tile to land on and collapsed to the fallback rect.
        // A page already showing its tiles keeps them while the refresh runs.
        if case .content = savedPage {} else {
            savedPage = .loading
            renderGallery()
        }
        Task { [weak self] in
            let tiles = (try? await gallery.posts(ids: ids)) ?? []
            guard let self else { return }
            savedPage = tiles.isEmpty
                ? .empty(message: "Nothing saved yet.")
                : .content(tiles)
            renderGallery()
        }
    }

    /// Names the empty combination so the blank page reads as an answer.
    ///
    /// ⚠️ Empty means "nothing to add", not "nothing to say". Unfiltered, this
    /// page is empty because the profile has nothing of that kind — which the
    /// TAB already says better than a generated sentence can, with a glyph and
    /// a headline. It is the FILTER that this knows and the tab cannot: "no
    /// media in reposts" explains why the page is narrower than the profile,
    /// and that is worth overriding the tab's own line for.
    nonisolated static func emptyMessage(for filter: GalleryFilter) -> String {
        guard filter.source != .all else { return "" }
        // Posts (#631) is every kind, so the source alone names what is
        // missing: "No reposts yet", not "No activity in reposts yet".
        if filter.format == .activity {
            return switch filter.source {
            case .all, .posts: "No posts yet."
            case .reposts: "No reposts yet."
            case .tagged: "No tagged posts yet."
            }
        }
        let format = switch filter.format {
        case .activity: "posts"
        case .media: "media"
        case .short: "short posts"
        }
        let source = switch filter.source {
        case .all: ""
        case .posts: " in posts"
        case .reposts: " in reposts"
        case .tagged: " in tagged posts"
        }
        return "No \(format)\(source) yet."
    }

    // MARK: - Loading

    private func reload(galleryRevalidates: Bool = false) {
        load?.cancel()
        relationshipLoad?.cancel()
        // Deliberately NOT resetting `followButton` here: the controller may
        // have pre-seeded a provisional state from the route's identity stub,
        // and a refresh keeps showing the last known state. The relationship
        // read overwrites with the authoritative answer when it lands.
        // ⚠️ THE RELATIONSHIP IS READ ALONGSIDE THE PROFILE, NOT AFTER IT.
        // It needs only the id, which a routed profile has from the start;
        // chained behind the profile fetch it was a second round trip in
        // series, and the button it decides is the one thing on the header a
        // push would otherwise have to show as a placeholder. Only the
        // viewer's own profile, whose id the fetch resolves, still chains.
        let readsRelationshipUpFront: Bool
        if case .profile(let id) = source {
            loadRelationship(for: id)
            readsRelationshipUpFront = true
        } else {
            readsRelationshipUpFront = false
        }
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await self.fetch()
                self.cache?.store(profile)
                // Revalidation that agrees with what is already on screen
                // publishes NOTHING. Re-emitting an identical model would run
                // the header's switch transition a second time over unchanged
                // text — a visible flicker whose only cause is that the
                // network confirmed the cache.
                let unchanged = self.profile == profile
                self.profile = profile
                if !unchanged {
                    self.phase = .content(ProfileDisplayModel(profile: profile))
                }
                if !readsRelationshipUpFront {
                    self.loadRelationship(for: profile.id)
                }
                // Every (re)load refreshes the grid too: the caches reset so
                // pull-to-refresh picks up new posts alongside the header —
                // except right after a cache seed, whose grid is loading or
                // loaded already and only needs confirming.
                self.loadGallery(for: profile, reset: !self.galleryWasSeeded && !galleryRevalidates)
                self.galleryWasSeeded = false
            } catch is CancellationError {
                // Superseded by a newer load; leave the phase alone.
            } catch {
                // Only surface a hard failure when there is nothing on screen;
                // a failed refresh keeps the last good content.
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load this profile. Pull to retry.")
                }
            }
            self.load = nil
            self.onLoadSettled?()
        }
    }

    private func fetch() async throws -> UserProfile {
        switch source {
        case .currentUser: try await repository.currentUserProfile()
        case .profile(let id): try await repository.profile(id: id)
        }
    }

    /// The relationship is best-effort: if it can't be read, the button simply
    /// stays hidden rather than failing the whole screen.
    private func loadRelationship(for id: ProfileID) {
        relationshipLoad = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            // Dev convenience: `-profile-relationship-delay` holds the
            // relationship answer for a few seconds, making the nav-bar
            // skeleton capsule and its cross-fade to Follow/Following
            // observable (the mock otherwise answers before the push starts).
            if ProcessInfo.processInfo.arguments.contains("-profile-relationship-delay") {
                try? await Task.sleep(for: .seconds(3))
            }
            #endif
            let relationship: ProfileRelationship
            do {
                relationship = try await self.repository.relationship(for: id)
            } catch {
                // Superseded by a newer read: that one answers. Otherwise a
                // failure is still an answer — the button stays as it is.
                guard !Task.isCancelled else { return }
                self.isRelationshipSettled = true
                self.relationshipLoad = nil
                return
            }
            guard !Task.isCancelled else { return }
            self.apply(relationship)
            self.cache?.store(relationship, for: id)
            self.relationshipLoad = nil
            // The mute rides beside the relationship; only someone else's
            // profile can be muted.
            // A toggle made while a read was out wins: the read is from before.
            let muteAsked = self.muteGeneration
            if relationship != .me, let muting = self.repository as? any ProfileMuting,
               let scopes = try? await muting.muteScopes(for: id),
               !self.muteInFlight, self.muteGeneration == muteAsked {
                self.muteScopes = scopes
            }
            let restrictAsked = self.restrictGeneration
            if relationship != .me, let restricting = self.repository as? any ProfileRestricting,
               let restricted = try? await restricting.isRestricted(id),
               !self.restrictInFlight, self.restrictGeneration == restrictAsked {
                self.isRestricted = restricted
            }
        }
    }

    /// Puts a relationship on screen — the read's answer or the cache's.
    private func apply(_ relationship: ProfileRelationship) {
        switch relationship {
        case .me:
            isFollowing = false
            isBlocked = false
            followButton = .edit
        case .other(let following, let mutual, let blocked):
            isFollowing = following
            isMutual = mutual
            isBlocked = blocked
            followButton = following ? .following : .follow
        case .requested:
            isFollowing = false
            isMutual = false
            isBlocked = false
            followButton = .requested
        case .cannotFollow:
            isFollowing = false
            isMutual = false
            isBlocked = false
            followButton = .unavailable
        }
        isRelationshipSettled = true
    }

    /// The relationship as this screen now holds it, for the cache — so the
    /// next visit opens on what the viewer last saw here, including a follow
    /// they just made.
    private func rememberRelationship() {
        guard let id = profile?.id, followButton.isOtherProfile else { return }
        let relationship: ProfileRelationship = switch followButton {
        case .requested: .requested
        case .unavailable: .cannotFollow
        default: .other(isFollowing: isFollowing, isMutual: isMutual, isBlocked: isBlocked)
        }
        cache?.store(relationship, for: id)
    }

    /// Applies a follow state everywhere it shows: the button and the
    /// optimistic follower count on the rendered profile.
    private func applyFollow(_ following: Bool, on profile: UserProfile) {
        isFollowing = following
        followButton = following ? .following : .follow
        defer { rememberRelationship() }

        let updated = UserProfile(
            id: profile.id,
            handle: profile.handle,
            displayName: profile.displayName,
            bio: profile.bio,
            avatarURL: profile.avatarURL,
            websiteURL: profile.websiteURL,
            // Carried through explicitly: the initializer defaults links and
            // visibility, so omitting them here would drop the profile's custom
            // links — and silently re-open a private profile — on every
            // optimistic follow toggle.
            customLinks: profile.customLinks,
            isVerified: profile.isVerified,
            visibility: profile.visibility,
            followerCount: profile.followerCount.adjusted(by: following ? 1 : -1),
            followingCount: profile.followingCount,
            reactionCount: profile.reactionCount,
            accountType: profile.accountType,
            businessCategory: profile.businessCategory
        )
        self.profile = updated
        phase = .content(ProfileDisplayModel(profile: updated))
    }
}
