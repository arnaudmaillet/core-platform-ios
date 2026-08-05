import CoreModels
import CoreNavigation
import CoreStorage
import Foundation
import PostGrid

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

    /// All three format pages at once — the pager renders every page
    /// (neighbors are visible mid-swipe), so the view model always answers
    /// for all of them. The source filter is a global modifier: it is
    /// already applied to each page's content here.
    public nonisolated struct GallerySnapshot: Equatable, Sendable {
        public var activity: GalleryPageState
        public var media: GalleryPageState
        public var short: GalleryPageState
        /// The viewer's saved pile. Absent on anyone else's profile — a saved
        /// list is private by construction.
        public var saved: GalleryPageState = .empty(message: "Nothing saved yet.")
        /// ⚠️ Always the same answer, and honestly so. `engagement.v1` can
        /// record a reaction and count reactions on a post; nothing anywhere
        /// answers "which posts did this profile react to", and the client
        /// cannot even read back whether IT reacted to one. The tab exists so
        /// the shape is right when a seam arrives; what it shows until then is
        /// the truth about what can be known.
        public var reactions: GalleryPageState = .empty(
            message: "Your reactions will appear here once we can list them."
        )

        public func state(for tab: ProfileTab) -> GalleryPageState {
            switch tab {
            case .format(.activity): activity
            case .format(.media): media
            case .format(.short): short
            case .saved: saved
            case .reactions: reactions
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
        case reported
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onFollowButtonChange: ((FollowButton) -> Void)?
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
    private let reporting: (any ProfileReporting)?
    private let gallery: (any ProfileGalleryProviding)?
    /// The global gallery-filter preference. nil (tests, minimal setups)
    /// means "session-local": the filter starts at the default and isn't
    /// persisted.
    private let galleryPreferences: GalleryPreferences?
    /// The viewer's saved pile — client-owned, because nothing on the wire
    /// carries one. Absent on anyone else's profile, and absent in the many
    /// setups that never show a Saved tab at all.
    private let bookmarks: PostBookmarkStore?
    /// The saved pile's tiles, once hydrated. Held because the pile can change
    /// while the screen is up (a post unsaved from the feed underneath) and the
    /// snapshot is rebuilt from parts.
    private var savedPage: GalleryPageState = .empty(message: "Nothing saved yet.")
    private let source: Source
    private let router: (any Router)?
    /// Last-known profiles, shared app-wide. Nil in compositions without one
    /// (tests), which simply never seed.
    private let cache: ProfileCache?

    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var followButton: FollowButton = .hidden {
        didSet { onFollowButtonChange?(followButton) }
    }

    /// The currently rendered profile — retained so a follow toggle can nudge
    /// its follower count without a full reload.
    private var profile: UserProfile?
    private var isFollowing = false
    private var followInFlight = false
    /// The viewer's outbound block on this profile, from the relationship read
    /// and kept current by `setBlocked`. Drives which of Block / Unblock the
    /// overflow menu offers.
    public private(set) var isBlocked = false
    private var blockInFlight = false
    private var reportInFlight = false

    private var load: Task<Void, Never>?
    private var relationshipLoad: Task<Void, Never>?

    // MARK: Gallery state

    public private(set) var galleryFilter = GalleryFilter()
    /// The authored fetch (Posts + Reposts split it) and the tagged fetch,
    /// cached so selector/kind changes recompute locally without round trips.
    /// nil = in flight (page shows loading); a failure records instead.
    private var authoredCache: [GalleryPost]?
    private var taggedCache: [GalleryPost]?
    private var authoredFailed = false
    private var taggedFailed = false
    private var galleryLoad: Task<Void, Never>?

    public init(
        repository: any ProfileProviding,
        reporting: (any ProfileReporting)? = nil,
        gallery: (any ProfileGalleryProviding)? = nil,
        galleryPreferences: GalleryPreferences? = nil,
        bookmarks: PostBookmarkStore? = nil,
        source: Source = .currentUser,
        router: (any Router)? = nil,
        cache: ProfileCache? = nil
    ) {
        self.repository = repository
        self.reporting = reporting
        self.gallery = gallery
        self.galleryPreferences = galleryPreferences
        self.bookmarks = bookmarks
        self.source = source
        self.router = router
        self.cache = cache
        // The gallery opens on the user's last GLOBAL choice, not a per-
        // profile default — the tray, pager, and menu all read this filter
        // as their initial truth.
        if let stored = galleryPreferences?.filter {
            galleryFilter = stored
        }
    }

    /// Whether the "Message" action applies (another user's profile).
    public var canMessage: Bool { followButton == .follow || followButton == .following }

    /// Whether the moderation actions (Block / Report) apply. False for the
    /// viewer's own profile, and false until the relationship is known — a
    /// menu opened mid-load offers sharing only rather than guessing.
    public var canModerate: Bool { followButton == .follow || followButton == .following }

    /// Everything the share sheet renders, resolved together so the QR code,
    /// the card, and the system share sheet's link preview cannot disagree
    /// about who is being shared.
    public nonisolated struct ShareCard: Equatable, Sendable {
        public let displayName: String
        /// Includes the leading `@`.
        public let handle: String
        public let avatarURL: URL?
        public let url: URL
    }

    /// The share payload, once the profile has loaded. `nil` before then —
    /// every share affordance is gated on it rather than rendering a card
    /// with a placeholder identity.
    public var shareCard: ShareCard? {
        profile.map {
            ShareCard(
                displayName: $0.displayName,
                handle: "@" + $0.handle,
                avatarURL: $0.avatarURL,
                url: ProfileShareLink.url(handle: $0.handle)
            )
        }
    }

    /// The profile's shareable link, once the handle is known.
    public var shareLink: URL? {
        profile.map { ProfileShareLink.url(handle: $0.handle) }
    }

    /// The loaded profile's `@handle`, for naming it in confirmations.
    public var handle: String? { profile.map { "@" + $0.handle } }

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
        reload()
    }

    /// Pull-to-refresh. Coalesced: a refresh while one is in flight is ignored.
    public func refresh() {
        guard load == nil else { return }
        reload()
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

    /// Follow-button tapped. No-op for the viewer's own profile ("Edit"); an
    /// optimistic toggle otherwise — flip immediately, roll back if the server
    /// rejects. One mutation in flight at a time.
    public func toggleFollow() {
        guard let profile, !followInFlight else { return }
        guard followButton == .follow || followButton == .following else { return }

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
                self.onActionResult?(.unblocked(handle: "@" + profile.handle))
            } catch {
                self.onActionResult?(.failed(message: "Couldn't unblock this profile."))
            }
            self.blockInFlight = false
        }
    }

    /// File a moderation report against this profile. Reports are fire-and-
    /// confirm: the result is reported either way, because a report the user
    /// believes was filed but wasn't is the worst outcome here.
    public func report(_ reason: ProfileReportReason) {
        guard let profile, canModerate, !reportInFlight else { return }
        guard let reporting else {
            onActionResult?(.failed(message: "Reporting isn't available right now."))
            return
        }
        reportInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await reporting.reportProfile(profile.id, reason: reason)
                self.onActionResult?(.reported)
            } catch {
                self.onActionResult?(.failed(message: "Couldn't send this report. Try again."))
            }
            self.reportInFlight = false
        }
    }

    // MARK: - Gallery

    /// A grid tile tapped — open the post. Route-only, like Message.
    public func galleryItemTapped(_ postID: PostID) {
        router?.route(to: .post(postID))
    }

    /// Where the user is — set by a tab tap or a settled swipe. Pure state
    /// (pages are always computed): the view pages to it, empty messages
    /// name it, and the choice persists globally for the next profile.
    public func setGalleryFormat(_ format: GalleryFilter.Format) {
        galleryFilter.format = format
        galleryPreferences?.filter = galleryFilter
    }

    /// The global source modifier: recomputes every page locally, without
    /// touching the active format tab; persists globally like the format.
    public func setGallerySource(_ source: GalleryFilter.Source) {
        guard galleryFilter.source != source else { return }
        galleryFilter.source = source
        galleryPreferences?.filter = galleryFilter
        renderGallery()
    }

    /// Fetches both corpora concurrently once the profile is known (the pager
    /// shows neighbors mid-swipe, so tagged can't be lazy). Called from the
    /// profile load path; `reset` makes pull-to-refresh refresh the grid too.
    private func loadGallery(for profile: UserProfile, reset: Bool) {
        guard let gallery else { return }
        if reset {
            galleryLoad?.cancel()
            galleryLoad = nil
            authoredCache = nil
            taggedCache = nil
            authoredFailed = false
            taggedFailed = false
        }
        guard galleryLoad == nil else { return }
        renderGallery() // all pages report loading
        galleryLoad = Task { [weak self] in
            async let authoredFetch = gallery.authoredPosts(for: profile.id)
            async let taggedFetch = gallery.taggedPosts(for: profile.id, handle: profile.handle)

            // The two fetches fail independently: one page family degrading
            // must not blank the other.
            let authored = try? await authoredFetch
            let tagged = try? await taggedFetch
            guard let self, !Task.isCancelled else { return }

            self.authoredCache = authored
            self.authoredFailed = authored == nil
            self.taggedCache = tagged
            self.taggedFailed = tagged == nil
            self.renderGallery()
            self.galleryLoad = nil
        }
    }

    /// Recomputes the full three-page snapshot from the caches and the global
    /// source modifier. Every data landing and source change funnels here.
    private func renderGallery() {
        guard gallery != nil else { return }

        let source = galleryFilter.source
        // Which fetches the active source depends on: All needs both, Tagged
        // its own, Posts/Reposts the authored one. A page is loading/failed
        // only when a fetch it actually reads is.
        let readsAuthored = source != .tagged
        let readsTagged = source == .all || source == .tagged
        func page(_ format: GalleryFilter.Format) -> GalleryPageState {
            if (readsAuthored && authoredFailed) || (readsTagged && taggedFailed) {
                return .failed(message: "Couldn't load. Pull to retry.")
            }
            if (readsAuthored && authoredCache == nil) || (readsTagged && taggedCache == nil) {
                return .loading
            }
            let filter = GalleryFilter(format: format, source: source)
            let tiles = filter.tiles(authored: authoredCache ?? [], tagged: taggedCache ?? [])
            return tiles.isEmpty
                ? .empty(message: Self.emptyMessage(for: filter))
                : .content(tiles)
        }

        onGalleryChange?(GallerySnapshot(
            activity: page(.activity),
            media: page(.media),
            short: page(.short),
            saved: savedPage
        ))
    }

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
            savedPage = .empty(message: "Nothing saved yet.")
            renderGallery()
            return
        }
        savedPage = .loading
        renderGallery()
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
    nonisolated static func emptyMessage(for filter: GalleryFilter) -> String {
        let format = switch filter.format {
        case .activity: "activity"
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

    private func reload() {
        load?.cancel()
        relationshipLoad?.cancel()
        // Deliberately NOT resetting `followButton` here: the controller may
        // have pre-seeded a provisional state from the route's identity stub,
        // and a refresh keeps showing the last known state. The relationship
        // read overwrites with the authoritative answer when it lands.
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
                self.loadRelationship(for: profile.id)
                // Every (re)load refreshes the grid too: the caches reset so
                // pull-to-refresh picks up new posts alongside the header.
                self.loadGallery(for: profile, reset: true)
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
            guard let relationship = try? await self.repository.relationship(for: id) else { return }
            switch relationship {
            case .me:
                self.isFollowing = false
                self.isBlocked = false
                self.followButton = .edit
            case .other(let following, let blocked):
                self.isFollowing = following
                self.isBlocked = blocked
                self.followButton = following ? .following : .follow
            }
            self.relationshipLoad = nil
        }
    }

    /// Applies a follow state everywhere it shows: the button and the
    /// optimistic follower count on the rendered profile.
    private func applyFollow(_ following: Bool, on profile: UserProfile) {
        isFollowing = following
        followButton = following ? .following : .follow

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
            viewCount: profile.viewCount
        )
        self.profile = updated
        phase = .content(ProfileDisplayModel(profile: updated))
    }
}
