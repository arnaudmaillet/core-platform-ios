import CoreModels
import CoreNavigation
import Foundation

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

        public func state(for format: GalleryFilter.Format) -> GalleryPageState {
            switch format {
            case .activity: activity
            case .media: media
            case .short: short
            }
        }
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onFollowButtonChange: ((FollowButton) -> Void)?
    public var onGalleryChange: ((GallerySnapshot) -> Void)?

    private let repository: any ProfileProviding
    private let gallery: (any ProfileGalleryProviding)?
    /// The global gallery-filter preference. nil (tests, minimal setups)
    /// means "session-local": the filter starts at the default and isn't
    /// persisted.
    private let galleryPreferences: GalleryPreferences?
    private let source: Source
    private let router: (any Router)?

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
        gallery: (any ProfileGalleryProviding)? = nil,
        galleryPreferences: GalleryPreferences? = nil,
        source: Source = .currentUser,
        router: (any Router)? = nil
    ) {
        self.repository = repository
        self.gallery = gallery
        self.galleryPreferences = galleryPreferences
        self.source = source
        self.router = router
        // The gallery opens on the user's last GLOBAL choice, not a per-
        // profile default — the tray, pager, and menu all read this filter
        // as their initial truth.
        if let stored = galleryPreferences?.filter {
            galleryFilter = stored
        }
    }

    /// Whether the "Message" action applies (another user's profile).
    public var canMessage: Bool { followButton == .follow || followButton == .following }

    /// Whether this screen shows a gallery at all — drives the filter tray's
    /// existence, not just its state.
    public var hasGallery: Bool { gallery != nil }

    // MARK: - Inputs

    public func viewDidLoad() {
        reload()
    }

    /// Pull-to-refresh. Coalesced: a refresh while one is in flight is ignored.
    public func refresh() {
        guard load == nil else { return }
        reload()
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
            short: page(.short)
        ))
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
                self.profile = profile
                self.phase = .content(ProfileDisplayModel(profile: profile))
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
                self.followButton = .edit
            case .other(let following):
                self.isFollowing = following
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
            isVerified: profile.isVerified,
            followerCount: profile.followerCount.adjusted(by: following ? 1 : -1),
            followingCount: profile.followingCount,
            reactionCount: profile.reactionCount,
            viewCount: profile.viewCount
        )
        self.profile = updated
        phase = .content(ProfileDisplayModel(profile: updated))
    }
}
