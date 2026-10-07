import Connect
import CoreContracts
import Foundation

/// Fakes of timeline.v1 / post.v1 / profile.v1 over one shared dataset,
/// honoring the contracts' semantics: the timeline returns bare
/// (post_id, author_id, published_at_ms) tuples with cursor pagination and
/// the cold-path flag; hydration happens through post/profile lookups exactly
/// as against the real services.
public final class MockSocialServices: @unchecked Sendable {
    private let dataset: MockSocialDataset
    private let postStore: MockPostStore?
    private let pageSizeCap: Int32
    /// Ranks the discovery pool by likes. Nil ranks it by publication.
    private let counters: MockCounterStore?

    private let lock = NSLock()
    private var servedWarmRequest = false

    /// The viewer's editable profile, mutated by the `UpdateProfile` /
    /// `ChangeHandle` mocks so edits persist for the session (the seed is a
    /// static struct; these overlay it). Guarded by `lock`. Seeded with a
    /// starter custom link so the Links editor has something to show.
    private var viewerHandle = MockPostStore.viewer.handle
    /// `SetVisibility` writes, by profile. Only the viewer's account's
    /// profiles can be changed; others keep their seeded flag.
    private var visibilityOverrides: [String: Profile_V1_ProfileVisibility] = [:]
    /// `SetAccountType` writes, by profile (backend #734): the kind, and a
    /// business's public contact card. prof-6 is seeded a creator so the
    /// header's type can be seen without setup.
    private var accountTypes: [String: (kind: Profile_V1_ProfileKind, business: Profile_V1_BusinessInfo?)] = [
        "prof-6": (.professional, nil)
    ]
    /// `SetLocationSettings` writes, by profile (backend #717); absent is
    /// not ghosted, precise. Stored only: the viewer is always the reader
    /// here, and the author's own reads are never filtered.
    private var locationSettings: [String: Profile_V1_LocationSettings] = [:]
    /// `SetDiscoverySettings` writes, by profile (backend #726); absent is
    /// everything on.
    private var discoverySettings: [String: Profile_V1_DiscoverySettings] = [:]
    /// Each profile's QR / share-link token (backend #661), issued on first
    /// ask. prof-1 holds `seededShareToken`, so a link that opens someone
    /// else's profile can be tried without setup.
    private var shareTokens: [String: String] = ["prof-1": MockSocialServices.seededShareToken]
    /// prof-1's share token: `wynn.cn/s/<this>` opens its profile.
    public static let seededShareToken = "mockShareToken-prof1_A"
    /// `SetInteractionSettings` writes, by profile (backend #714). prof-13 —
    /// public, and not followed by the viewer — takes comments from its
    /// followers only, so a refused comment can be seen without setup, and
    /// hides its like counts (#809), so a post without a count can be too.
    private var interactionSettings: [String: Profile_V1_InteractionSettings] = [
        "prof-13": {
            var settings = MockSocialServices.defaultInteractionSettings
            settings.comments = .followers
            settings.showLikeCounts = false
            return settings
        }()
    ]
    /// Posts deleted this session, with when (backend #663: a tombstone,
    /// restorable for 30 days). Guarded by `lock`.
    private var deletedPosts: [String: Date] = [:]
    /// How long a deleted post can be restored.
    public static let restoreWindow: TimeInterval = 30 * 86_400
    /// `SetFeedSettings` writes, by profile (backend #731); absent is Less.
    private var feedSettings: [String: Profile_V1_FeedSettings] = [:]
    /// Interest tags by profile (timeline #662), heaviest first. The viewer
    /// starts with a few that match mock captions, so removing one visibly
    /// changes For You. Nothing is learnt here: a removed or reset tag stays
    /// gone.
    private var interests: [String: [Timeline_V1_Interest]] = [
        MockSocialDataset.viewerProfileID: MockSocialServices.seededInterests,
    ]
    /// The viewer's starting interest tags.
    public static let seededInterests: [Timeline_V1_Interest] = [
        ("travel", 0.92), ("foodie", 0.71), ("goldenhour", 0.44), ("sailing", 0.31), ("ramen", 0.18),
    ].map { tag, weight in
        var interest = Timeline_V1_Interest()
        interest.tag = tag
        interest.weight = weight
        return interest
    }
    /// `SetTabSettings` writes, by profile (backend #729): the post window
    /// visitors see, and the tab flags. Absent is the defaults.
    private var tabSettings: [String: Profile_V1_TabSettings] = [:]
    /// `SetCommentFilters` writes, by profile (backend #728); absent means
    /// no hidden words and the offensive filter on.
    private var commentFilters: [String: Profile_V1_CommentFilters] = [:]
    private var viewerDisplayName = MockPostStore.viewer.displayName
    private var viewerBio = MockPostStore.viewer.bio
    private var viewerWebsite = MockPostStore.viewer.websiteURL
    private var viewerLinks: [(label: String, url: String)] = [
        (label: "Portfolio", url: "https://www.example.com/demo/portfolio")
    ]

    /// Verification requests, by profile (backend #668): the latest one.
    /// Nobody decides them here — a seed stands for a staff decision.
    private var verificationRequests: [String: Profile_V1_VerificationRequestView] = [:]

    /// `verificationSeed` gives the viewer a request in that state
    /// (`pending`, `rejected` or `approved`); anything else, none.
    public init(
        dataset: MockSocialDataset = MockSocialDataset(),
        postStore: MockPostStore? = nil,
        pageSizeCap: Int32 = 50,
        verificationSeed: String? = nil,
        counters: MockCounterStore? = nil
    ) {
        self.dataset = dataset
        self.postStore = postStore
        self.pageSizeCap = pageSizeCap
        self.counters = counters
        if let seeded = Self.verificationRequest(seed: verificationSeed) {
            verificationRequests[MockPostStore.viewer.profileID] = seeded
        }
        // Takes no mentions and no messages (#397): a post mentioning it is
        // refused, and so is a message to it. No seeded conversation has it.
        var noContact = Self.defaultInteractionSettings
        noContact.mentions = .noOne
        noContact.messages = .noOne
        interactionSettings[Self.noContactProfileID] = noContact
    }

    /// The profile that takes no mentions and no messages.
    public static let noContactProfileID = "prof-30"

    private static func verificationRequest(seed: String?) -> Profile_V1_VerificationRequestView? {
        let status: Profile_V1_VerificationRequestStatus
        switch seed {
        case "pending": status = .pending
        case "rejected": status = .rejected
        case "approved": status = .approved
        default: return nil
        }
        let nowMS = Int64(Date().timeIntervalSince1970 * 1_000)
        var view = Profile_V1_VerificationRequestView()
        view.profileID = MockPostStore.viewer.profileID
        view.category = .notable
        view.documents = ["https://example.com/press/interview"]
        view.status = status
        view.submittedAtMs = nowMS - 9 * 86_400_000
        if status != .pending { view.decidedAtMs = nowMS - 2 * 86_400_000 }
        if status == .rejected { view.reason = "The links don't show enough independent coverage of you." }
        return view
    }

    /// Timeline = client-authored published posts (newest first) followed by
    /// the seeded dataset. Computed per request so a fresh post shows up on
    /// refresh.
    private var timelineFeed: [(postID: String, authorID: String, publishedAtMS: Int64)] {
        let authored = (postStore?.publishedRecords ?? []).map {
            (postID: $0.postID, authorID: $0.profileID, publishedAtMS: $0.createdAtMS)
        }
        let seeded = dataset.posts.map {
            (postID: $0.postID, authorID: $0.authorProfileID, publishedAtMS: $0.publishedAtMS)
        }
        return authored + seeded
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/timeline.v1.TimelineService/GetFollowingFeed") { [self] (request: Timeline_V1_GetFollowingFeedRequest) in
            getFollowingFeed(request)
        }
        bff.register(path: "/timeline.v1.TimelineService/GetDiscoveryFeed") { [self] (request: Timeline_V1_GetDiscoveryFeedRequest) in
            getDiscoveryFeed(request)
        }
        bff.register(path: "/timeline.v1.TimelineService/ListInterests") { [self] (request: Timeline_V1_ListInterestsRequest) -> Result<Timeline_V1_InterestsResponse, ConnectError> in
            var response = Timeline_V1_InterestsResponse()
            response.interests = lock.withLock { interests[request.profileID] ?? [] }
            return .success(response)
        }
        bff.register(path: "/timeline.v1.TimelineService/RemoveInterest") { [self] (request: Timeline_V1_RemoveInterestRequest) -> Result<Timeline_V1_InterestsResponse, ConnectError> in
            let tag = request.tag.hasPrefix("#") ? String(request.tag.dropFirst()).lowercased() : request.tag.lowercased()
            var response = Timeline_V1_InterestsResponse()
            response.interests = lock.withLock {
                let remaining = (interests[request.profileID] ?? []).filter { $0.tag != tag }
                interests[request.profileID] = remaining
                return remaining
            }
            return .success(response)
        }
        bff.register(path: "/timeline.v1.TimelineService/ResetInterests") { [self] (request: Timeline_V1_ResetInterestsRequest) -> Result<Timeline_V1_InterestsResponse, ConnectError> in
            lock.withLock { interests[request.profileID] = [] }
            return .success(Timeline_V1_InterestsResponse())
        }
        bff.register(path: "/post.v1.PostService/GetPost") { [self] (request: Post_V1_GetPostRequest) in
            getPost(request)
        }
        bff.register(path: "/post.v1.PostService/ListPostsByProfile") { [self] (request: Post_V1_ListPostsByProfileRequest) in
            listPostsByProfile(request)
        }
        bff.register(path: "/post.v1.PostService/DeletePost") { [self] (request: Post_V1_DeletePostRequest) -> Result<Post_V1_CommandResponse, ConnectError> in
            guard let author = author(ofPost: request.postID) else {
                return .failure(ConnectError(code: .notFound, message: "post \(request.postID) not found"))
            }
            guard author == request.profileID else {
                return .failure(ConnectError(code: .permissionDenied, message: "PST-1005: not the author"))
            }
            lock.withLock { if deletedPosts[request.postID] == nil { deletedPosts[request.postID] = Date() } }
            var response = Post_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/post.v1.PostService/ListRecentlyDeleted") { [self] (request: Post_V1_ListRecentlyDeletedRequest) in
            listRecentlyDeleted(request)
        }
        bff.register(path: "/post.v1.PostService/RestorePost") { [self] (request: Post_V1_RestorePostRequest) -> Result<Post_V1_CommandResponse, ConnectError> in
            guard author(ofPost: request.postID) == request.profileID else {
                return .failure(ConnectError(code: .permissionDenied, message: "PST-1005: not the author"))
            }
            guard let deletedAt = lock.withLock({ deletedPosts[request.postID] }) else {
                return .failure(ConnectError(code: .failedPrecondition, message: "PST-1006: post is not deleted"))
            }
            guard Date().timeIntervalSince(deletedAt) <= Self.restoreWindow else {
                return .failure(ConnectError(code: .failedPrecondition, message: "PST-1007: restore window has passed"))
            }
            lock.withLock { deletedPosts[request.postID] = nil }
            var response = Post_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/GetProfileById") { [self] (request: Profile_V1_GetProfileByIdRequest) in
            getProfileByID(request)
        }
        bff.register(path: "/profile.v1.ProfileService/GetProfileByHandle") { [self] (request: Profile_V1_GetProfileByHandleRequest) in
            getProfileByHandle(request)
        }
        bff.register(path: "/profile.v1.ProfileService/ListProfilesByAccount") { [self] (request: Profile_V1_ListProfilesByAccountRequest) in
            listProfilesByAccount(request)
        }
        bff.register(path: "/profile.v1.ProfileService/UpdateProfile") { [self] (request: Profile_V1_UpdateProfileRequest) in
            updateProfile(request)
        }
        bff.register(path: "/profile.v1.ProfileService/SetFeedSettings") { [self] (request: Profile_V1_SetFeedSettingsRequest) in
            lock.withLock {
                feedSettings[request.profileID] = request.settings
                // Non-personalised erases what was learnt (timeline #662).
                if request.settings.nonPersonalized { interests[request.profileID] = [] }
            }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetTabSettings") { [self] (request: Profile_V1_SetTabSettingsRequest) in
            // Partial: an unspecified window or an unset flag keeps its value.
            lock.withLock {
                var settings = tabSettings[request.profileID] ?? Self.defaultTabSettings
                if request.postWindow != .unspecified { settings.postWindow = request.postWindow }
                if request.hasShowLikes { settings.showLikes = request.showLikes }
                if request.hasShowSaved { settings.showSaved = request.showSaved }
                if request.hasShowReposts { settings.showReposts = request.showReposts }
                if request.hasShowPlaces { settings.showPlaces = request.showPlaces }
                tabSettings[request.profileID] = settings
            }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetCommentFilters") { [self] (request: Profile_V1_SetCommentFiltersRequest) -> Result<Profile_V1_CommandResponse, ConnectError> in
            // Trimmed, lowercased, de-duplicated and sorted; at most 200
            // words of at most 64 characters, as on the fleet.
            let words = Array(Set(request.filters.hiddenWords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })).sorted()
            guard words.count <= 200, words.allSatisfy({ $0.count <= 64 }) else {
                return .failure(ConnectError(code: .invalidArgument, message: "PRF-9001: too many hidden words, or one too long"))
            }
            var filters = request.filters
            filters.hiddenWords = words
            lock.withLock { commentFilters[request.profileID] = filters }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetInteractionSettings") { [self] (request: Profile_V1_SetInteractionSettingsRequest) -> Result<Profile_V1_CommandResponse, ConnectError> in
            let settings = request.settings
            // The whole set at once; an unspecified audience is refused.
            guard settings.comments != .unspecified, settings.mentions != .unspecified, settings.messages != .unspecified else {
                return .failure(ConnectError(code: .invalidArgument, message: "PRF-9001: every audience must be set"))
            }
            lock.withLock {
                let stored = interactionSettings[request.profileID] ?? Self.defaultInteractionSettings
                var next = settings
                // Remix and sound reuse: absent keeps the stored value; the
                // limit is set only through its own RPCs.
                if !settings.hasAllowRemix { next.allowRemix = stored.allowRemix }
                if !settings.hasAllowSoundReuse { next.allowSoundReuse = stored.allowSoundReuse }
                if stored.hasLimit { next.limit = stored.limit } else { next.clearLimit() }
                interactionSettings[request.profileID] = next
            }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetDiscoverySettings") { [self] (request: Profile_V1_SetDiscoverySettingsRequest) in
            // Partial: an unset flag keeps its value.
            lock.withLock {
                var settings = discoverySettings[request.profileID] ?? Self.defaultDiscoverySettings
                if request.hasActivityStatus { settings.activityStatus = request.activityStatus }
                if request.hasReadReceipts { settings.readReceipts = request.readReceipts }
                if request.hasByPhone { settings.byPhone = request.byPhone }
                if request.hasByEmail { settings.byEmail = request.byEmail }
                if request.hasByHandleSearch { settings.byHandleSearch = request.byHandleSearch }
                if request.hasByQr { settings.byQr = request.byQr }
                if request.hasInSuggestions { settings.inSuggestions = request.inSuggestions }
                discoverySettings[request.profileID] = settings
            }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/GetShareToken") { [self] (request: Profile_V1_GetShareTokenRequest) -> Result<Profile_V1_ShareTokenResponse, ConnectError> in
            var response = Profile_V1_ShareTokenResponse()
            response.token = lock.withLock {
                if let token = shareTokens[request.profileID] { return token }
                let token = Self.newShareToken()
                shareTokens[request.profileID] = token
                return token
            }
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/RotateShareToken") { [self] (request: Profile_V1_RotateShareTokenRequest) -> Result<Profile_V1_ShareTokenResponse, ConnectError> in
            // The old token stops resolving at once.
            var response = Profile_V1_ShareTokenResponse()
            response.token = Self.newShareToken()
            lock.withLock { shareTokens[request.profileID] = response.token }
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/ResolveShareToken") { [self] (request: Profile_V1_ResolveShareTokenRequest) -> Result<Profile_V1_ProfileView, ConnectError> in
            // NOT_FOUND alike for a token no one holds (reset or junk) and an
            // owner who switched QR codes and links off.
            let owner: String? = lock.withLock {
                guard let holder = shareTokens.first(where: { $0.value == request.token })?.key,
                      (discoverySettings[holder] ?? Self.defaultDiscoverySettings).byQr else { return nil }
                return holder
            }
            guard let owner else { return .failure(ConnectError(code: .notFound, message: "share token not found")) }
            var byID = Profile_V1_GetProfileByIdRequest()
            byID.profileID = owner
            return getProfileByID(byID)
        }
        bff.register(path: "/profile.v1.ProfileService/SetLocationSettings") { [self] (request: Profile_V1_SetLocationSettingsRequest) in
            lock.withLock { locationSettings[request.profileID] = request.settings }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetAccountType") { [self] (request: Profile_V1_SetAccountTypeRequest) -> Result<Profile_V1_CommandResponse, ConnectError> in
            guard request.kind != .bot, request.kind != .unspecified else {
                return .failure(ConnectError(code: .invalidArgument, message: "PRF-9001: choose personal, professional or brand"))
            }
            if request.kind == .brand {
                let category = request.business.category.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !category.isEmpty, category.count <= 64 else {
                    return .failure(ConnectError(code: .invalidArgument, message: "PRF-9001: a brand needs a category of 1 to 64 characters"))
                }
            }
            // The card exists only for a brand; switching away drops it.
            lock.withLock { accountTypes[request.profileID] = (request.kind, request.kind == .brand ? request.business : nil) }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        // Ask for a badge with 1–5 supporting documents (backend #668):
        // refused when already verified (PRF-5001) or while a request is
        // pending (PRF-5002).
        bff.register(path: "/profile.v1.ProfileService/RequestVerification") { [self] (request: Profile_V1_RequestVerificationRequest) -> Result<Profile_V1_CommandResponse, ConnectError> in
            let documents = request.documents
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard request.category != .unspecified, (1...5).contains(documents.count), documents.allSatisfy({ $0.count <= 512 }) else {
                return .failure(ConnectError(code: .invalidArgument, message: "PRF-9001: 1–5 supporting documents"))
            }
            return lock.withLock { () -> Result<Profile_V1_CommandResponse, ConnectError> in
                switch verificationRequests[request.profileID]?.status {
                case .approved:
                    return .failure(ConnectError(code: .alreadyExists, message: "PRF-5001: the profile is already verified"))
                case .pending:
                    return .failure(ConnectError(code: .alreadyExists, message: "PRF-5002: a verification request is pending"))
                default:
                    var view = Profile_V1_VerificationRequestView()
                    view.profileID = request.profileID
                    view.category = request.category
                    view.documents = documents
                    view.status = .pending
                    view.submittedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
                    verificationRequests[request.profileID] = view
                    var response = Profile_V1_CommandResponse()
                    response.success = true
                    return .success(response)
                }
            }
        }
        // `request` unset: the profile never asked.
        bff.register(path: "/profile.v1.ProfileService/GetVerificationRequest") { [self] (request: Profile_V1_GetVerificationRequestRequest) in
            var response = Profile_V1_GetVerificationRequestResponse()
            if let stored = lock.withLock({ verificationRequests[request.profileID] }) { response.request = stored }
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetInteractionLimit") { [self] (request: Profile_V1_SetInteractionLimitRequest) -> Result<Profile_V1_CommandResponse, ConnectError> in
            let nowMS = Int64(Date().timeIntervalSince1970 * 1_000)
            // In the future, and at most four weeks ahead.
            guard request.audience != .unspecified, request.untilMs > nowMS,
                  request.untilMs <= nowMS + 28 * 86_400_000 + 60_000 else {
                return .failure(ConnectError(code: .invalidArgument, message: "PRF-9001: a limit ends within four weeks"))
            }
            lock.withLock {
                var settings = interactionSettings[request.profileID] ?? Self.defaultInteractionSettings
                settings.limit.audience = request.audience
                settings.limit.untilMs = request.untilMs
                interactionSettings[request.profileID] = settings
            }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/ClearInteractionLimit") { [self] (request: Profile_V1_ClearInteractionLimitRequest) in
            lock.withLock {
                var settings = interactionSettings[request.profileID] ?? Self.defaultInteractionSettings
                settings.clearLimit()
                interactionSettings[request.profileID] = settings
            }
            var response = Profile_V1_CommandResponse()
            response.success = true
            return .success(response)
        }
        bff.register(path: "/profile.v1.ProfileService/SetVisibility") { [self] (request: Profile_V1_SetVisibilityRequest) in
            setVisibility(request)
        }
        bff.register(path: "/profile.v1.ProfileService/ChangeHandle") { [self] (request: Profile_V1_ChangeHandleRequest) in
            changeHandle(request)
        }
        bff.register(path: "/profile.v1.ProfileService/CheckHandleAvailability") { [self] (request: Profile_V1_CheckHandleAvailabilityRequest) in
            .success(handleAvailability(request.handle))
        }
        bff.register(path: "/profile.v1.ProfileService/CreateProfile") { [self] (request: Profile_V1_CreateProfileRequest) in
            createProfile(request)
        }
    }

    // MARK: - Sign-up (B4)

    /// `^[a-z0-9._]{3,30}$`, case-insensitive, and not anyone else's.
    func handleAvailability(_ raw: String) -> Profile_V1_CheckHandleAvailabilityResponse {
        var response = Profile_V1_CheckHandleAvailabilityResponse()
        let handle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._")
        guard (3...30).contains(handle.count), handle.allSatisfy(allowed.contains) else {
            response.availability = .invalid
            response.invalidReason = "3–30 letters, numbers, dots or underscores."
            return response
        }
        response.handle = handle
        let taken = dataset.authors.contains { $0.handle.lowercased() == handle }
        response.availability = taken ? .taken : .available
        return response
    }

    /// The mock is one world with one viewer: a new account's profile is the
    /// demo viewer's, named with what the sign-up chose.
    private func createProfile(_ request: Profile_V1_CreateProfileRequest) -> Result<Profile_V1_CommandResponse, ConnectError> {
        let check = handleAvailability(request.handle)
        guard check.availability == .available else {
            return .failure(ConnectError(code: .alreadyExists, message: "PRF-1001: handle unavailable"))
        }
        lock.withLock {
            viewerHandle = check.handle
            if !request.displayName.isEmpty { viewerDisplayName = request.displayName }
        }
        return .success(Self.accepted(profileID: MockPostStore.viewer.profileID))
    }

    // MARK: - timeline.v1

    /// The discovery pool (backend B3): every post, everyone's, viewer-free.
    /// RECENT is newest first; FOR_YOU, TRENDING and NEARBY rank by likes,
    /// then recency. The mock has no age-gated posts, so `content_level` is
    /// echoed and filters nothing (a guest always gets RESTRICTED).
    private func getDiscoveryFeed(
        _ request: Timeline_V1_GetDiscoveryFeedRequest
    ) -> Result<Timeline_V1_GetDiscoveryFeedResponse, ConnectError> {
        var pool = timelineFeed
        if request.ranking != .recent, let counters {
            let likes = Dictionary(pool.map { ($0.postID, counters.likeCount(for: $0.postID)) },
                                   uniquingKeysWith: { first, _ in first })
            pool.sort { (likes[$0.postID] ?? 0, $0.publishedAtMS) > (likes[$1.postID] ?? 0, $1.publishedAtMS) }
        }
        // FOR_YOU for a profile that keeps personalisation on: posts tagged
        // with one of its interests come first (timeline #662).
        let tags = personalizingTags(for: request)
        if !tags.isEmpty {
            let captions = Dictionary(dataset.posts.map { ($0.postID, $0.caption.lowercased()) }, uniquingKeysWith: { first, _ in first })
            func matches(_ postID: String) -> Bool {
                guard let caption = captions[postID] else { return false }
                return tags.contains { caption.contains("#" + $0) }
            }
            pool = pool.filter { matches($0.postID) } + pool.filter { !matches($0.postID) }
        }
        let start = Int(request.pageToken) ?? 0
        let limit = Int(request.limit <= 0 ? 20 : min(request.limit, pageSizeCap))
        let end = min(start + limit, pool.count)
        guard start <= end else {
            return .failure(ConnectError(code: .invalidArgument, message: "bad page token"))
        }
        var response = Timeline_V1_GetDiscoveryFeedResponse()
        response.items = pool[start..<end].map { record in
            var item = Timeline_V1_FeedItem()
            item.postID = record.postID
            item.authorID = record.authorID
            item.publishedAtMs = record.publishedAtMS
            return item
        }
        response.nextPageToken = end < pool.count ? String(end) : ""
        response.contentLevelApplied = request.contentLevel == .standard ? .standard : .restricted
        response.personalized = !tags.isEmpty
        return .success(response)
    }

    /// The interest tags that rank this FOR_YOU read: none for a guest (no
    /// profile), a read that asks not to be personalised, or a profile whose
    /// Feed Settings turned personalisation off.
    private func personalizingTags(for request: Timeline_V1_GetDiscoveryFeedRequest) -> [String] {
        guard request.ranking == .forYou, !request.profileID.isEmpty, !request.nonPersonalized else { return [] }
        return lock.withLock {
            guard feedSettings[request.profileID]?.nonPersonalized != true else { return [] }
            return (interests[request.profileID] ?? []).map(\.tag)
        }
    }

    /// The interest tags a profile holds now, heaviest first.
    public func interestTags(of profileID: String) -> [String] {
        lock.withLock { (interests[profileID] ?? []).map(\.tag) }
    }

    private func getFollowingFeed(_ request: Timeline_V1_GetFollowingFeedRequest) -> Result<Timeline_V1_GetFollowingFeedResponse, ConnectError> {
        guard request.profileID == MockSocialDataset.viewerProfileID else {
            return .failure(ConnectError(code: .permissionDenied, message: "feed belongs to another profile"))
        }

        let feed = timelineFeed
        let start = Int(request.pageToken) ?? 0
        let limit = Int(min(max(request.limit, 1), pageSizeCap))
        let end = min(start + limit, feed.count)
        guard start <= end else {
            return .failure(ConnectError(code: .invalidArgument, message: "bad page token"))
        }

        // First request hits the cold path (per contract: Redis not warm yet);
        // everything after is warm.
        let isCold = lock.withLock {
            let cold = !servedWarmRequest
            servedWarmRequest = true
            return cold
        }

        var response = Timeline_V1_GetFollowingFeedResponse()
        response.items = feed[start..<end].map { record in
            var item = Timeline_V1_FeedItem()
            item.postID = record.postID
            item.authorID = record.authorID
            item.publishedAtMs = record.publishedAtMS
            return item
        }
        response.nextPageToken = end < feed.count ? String(end) : ""
        response.isCold = isCold
        return .success(response)
    }

    // MARK: - post.v1

    private func storedCommentFilters(for profileID: String) -> Profile_V1_CommentFilters {
        lock.withLock { commentFilters[profileID] } ?? {
            var filters = Profile_V1_CommentFilters()
            filters.filterOffensive = true
            return filters
        }()
    }

    /// The words a post owner hides from their comments. The comment mock
    /// reads it to drop matching comments, as comment.v1 does (backend #728).
    /// The offensive filter has no term list here, as on the fleet until
    /// trust & safety supplies one.
    public func hiddenWords(of profileID: String) -> [String] {
        storedCommentFilters(for: profileID).hiddenWords
    }

    /// Who wrote a post, client-authored or seeded; nil if unknown.
    private func author(ofPost postID: String) -> String? {
        postStore?.record(for: postID)?.profileID ?? dataset.post(for: postID)?.authorProfileID
    }

    /// Test seam: back-dates a deletion, to reach the end of the window.
    public func backdateDeletion(of postID: String, by interval: TimeInterval) {
        lock.withLock { deletedPosts[postID] = deletedPosts[postID]?.addingTimeInterval(-interval) }
    }

    /// The author's restorable posts, newest deletion first (backend #663).
    private func listRecentlyDeleted(_ request: Post_V1_ListRecentlyDeletedRequest) -> Result<Post_V1_ListRecentlyDeletedResponse, ConnectError> {
        let now = Date()
        let entries = lock.withLock { deletedPosts }
            .filter { now.timeIntervalSince($0.value) <= Self.restoreWindow }
            .filter { author(ofPost: $0.key) == request.profileID }
            .sorted { $0.value > $1.value }
        var response = Post_V1_ListRecentlyDeletedResponse()
        response.posts = entries.compactMap { postID, _ in
            var get = Post_V1_GetPostRequest()
            get.postID = postID
            return try? getPost(get).get()
        }
        return .success(response)
    }

    private static let defaultTabSettings: Profile_V1_TabSettings = {
        var settings = Profile_V1_TabSettings()
        settings.postWindow = .all
        settings.showLikes = true
        settings.showSaved = false
        settings.showReposts = true
        settings.showPlaces = true
        return settings
    }()

    /// The oldest creation time a visitor may see of `profileID`'s posts, or
    /// nil for no limit. The viewer's own account sees everything (backend
    /// #729: the author and the mesh are never windowed).
    private func windowStartMS(for profileID: String) -> Int64? {
        guard !dataset.profileIDs(inAccount: MockAuthService.accountID).contains(profileID) else { return nil }
        let days: Double? = switch lock.withLock({ tabSettings[profileID]?.postWindow }) {
        case .sixMonths: 183
        case .oneMonth: 30
        case .threeDays: 3
        default: nil
        }
        return days.map { Int64((Date().timeIntervalSince1970 - $0 * 86_400) * 1_000) }
    }

    static let defaultDiscoverySettings: Profile_V1_DiscoverySettings = {
        var settings = Profile_V1_DiscoverySettings()
        settings.activityStatus = true
        settings.readReceipts = true
        settings.byPhone = true
        settings.byEmail = true
        settings.byHandleSearch = true
        settings.byQr = true
        settings.inSuggestions = true
        return settings
    }()

    /// A fresh token, as the server makes them: 128 random bits, URL-safe
    /// base64 without padding (22 characters).
    static func newShareToken() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether suggestions may show `profileID`: "appear in suggestions"
    /// (`in_suggestions`), read by social_graph's `SuggestProfiles` (#644).
    public func isSuggestible(_ profileID: String) -> Bool {
        (lock.withLock { discoverySettings[profileID] } ?? Self.defaultDiscoverySettings).inSuggestions
    }

    /// Whether search may show `profileID` (backend #726: `discoverable`).
    public func isFindableInSearch(_ profileID: String) -> Bool {
        (lock.withLock { discoverySettings[profileID] } ?? Self.defaultDiscoverySettings).byHandleSearch
    }

    /// The kind and card on any profile view: public, unlike the settings.
    private func applyAccountType(to view: inout Profile_V1_ProfileView) {
        let stored = lock.withLock { accountTypes[view.profileID] }
        view.profileKind = stored?.kind ?? .personal
        if let business = stored?.business { view.businessInfo = business }
    }

    static let defaultInteractionSettings: Profile_V1_InteractionSettings = {
        var settings = Profile_V1_InteractionSettings()
        settings.comments = .everyone
        settings.mentions = .everyone
        settings.messages = .everyone
        settings.allowDownloads = true
        settings.showLikeCounts = true
        settings.allowRemix = true
        settings.allowSoundReuse = true
        return settings
    }()

    private func storedInteractionSettings(for profileID: String) -> Profile_V1_InteractionSettings {
        lock.withLock { interactionSettings[profileID] } ?? Self.defaultInteractionSettings
    }

    /// Who may comment on `profileID`'s posts; the comment mock asks it.
    public func commentAudience(of profileID: String) -> Profile_V1_InteractionAudience {
        storedInteractionSettings(for: profileID).comments
    }

    /// Who may mention `profileID`; the post mock asks it.
    public func mentionAudience(of profileID: String) -> Profile_V1_InteractionAudience {
        storedInteractionSettings(for: profileID).mentions
    }

    /// Who may message `profileID`; the chat mock asks it.
    public func messageAudience(of profileID: String) -> Profile_V1_InteractionAudience {
        storedInteractionSettings(for: profileID).messages
    }

    /// The profile a `@handle` names, or nil.
    public func profileID(forHandle handle: String) -> String? {
        let handle = handle.lowercased()
        if handle == lock.withLock({ viewerHandle }).lowercased() { return MockPostStore.viewer.profileID }
        return dataset.authors.first { $0.handle.lowercased() == handle }?.profileID
    }

    /// A post older than its author's window reads as not found to visitors;
    /// a deleted post still reads, as the tombstone it is.
    private func getPost(_ request: Post_V1_GetPostRequest) -> Result<Post_V1_PostView, ConnectError> {
        var result = windowlessPost(request)
        if case .success(let view) = result, let start = windowStartMS(for: view.profileID), view.publishedAtMs < start {
            return .failure(ConnectError(code: .notFound, message: "PST-1001: post \(request.postID) not found"))
        }
        if case .success(var view) = result, let deletedAt = lock.withLock({ deletedPosts[request.postID] }) {
            view.status = .deleted
            view.deletedAtMs = Int64(deletedAt.timeIntervalSince1970 * 1_000)
            result = .success(view)
        }
        // The author's "Show Like Counts" off hides them from every reader
        // but the author (backend #809). The viewer is the only reader here.
        if case .success(var view) = result, view.profileID != MockSocialDataset.viewerProfileID,
           !storedInteractionSettings(for: view.profileID).showLikeCounts {
            view.likeCountsHidden = true
            result = .success(view)
        }
        return result
    }

    private func windowlessPost(_ request: Post_V1_GetPostRequest) -> Result<Post_V1_PostView, ConnectError> {
        // Client-authored posts first, then the seeded dataset.
        if let draft = postStore?.record(for: request.postID) {
            var view = Post_V1_PostView()
            view.postID = draft.postID
            view.profileID = draft.profileID
            view.caption = draft.caption
            view.publishedAtMs = draft.createdAtMS
            // The kind the seeded posts carry, so an authored post reads the
            // same on the wire.
            view.kind = Self.kind(forMediaURL: draft.media?.url)
            if let media = draft.media {
                view.attachments = [makeAttachment(url: media.url, width: media.width, height: media.height)]
            }
            return .success(view)
        }

        guard let record = dataset.post(for: request.postID) else {
            return .failure(ConnectError(code: .notFound, message: "post \(request.postID) not found"))
        }
        var view = Post_V1_PostView()
        view.postID = record.postID
        view.profileID = record.authorProfileID
        view.caption = record.caption
        view.publishedAtMs = record.publishedAtMS
        view.kind = Self.kind(forMediaURL: record.media?.url)
        view.parentID = record.parentID
        if let media = record.media {
            // Head plus tail, in the author's order — `attachments` is repeated
            // on the wire and the mock used to vend exactly one, which is why a
            // carousel could not be seen even though the contract allowed it.
            view.attachments = [makeAttachment(url: media.url, width: media.width, height: media.height)]
                + record.extraMedia.map {
                    makeAttachment(url: $0.url, width: $0.width, height: $0.height)
                }
        }
        return .success(view)
    }

    /// The author's own posts, newest first, with cursor pagination — the
    /// profile gallery's source. Client-authored posts only exist for the
    /// viewer's own profile; seeded authors serve the dataset.
    private func listPostsByProfile(_ request: Post_V1_ListPostsByProfileRequest) -> Result<Post_V1_ListPostsByProfileResponse, ConnectError> {
        let authored = (postStore?.publishedRecords ?? [])
            .filter { $0.profileID == request.profileID }
            .map { (postID: $0.postID, mediaURL: $0.media?.url, createdAtMS: $0.createdAtMS) }
        let seeded = dataset.posts
            .filter { $0.authorProfileID == request.profileID }
            .map { (postID: $0.postID, mediaURL: $0.media?.url, createdAtMS: $0.publishedAtMS) }
        let deleted = lock.withLock { Set(deletedPosts.keys) }
        // Visitors' listing stops at the author's window (backend #729).
        let windowStart = windowStartMS(for: request.profileID) ?? .min
        let all = (authored + seeded)
            .filter { !deleted.contains($0.postID) && $0.createdAtMS >= windowStart }
            .sorted { $0.createdAtMS > $1.createdAtMS }

        let start = Int(request.pageToken) ?? 0
        let limit = Int(min(max(request.limit, 1), pageSizeCap))
        let end = min(start + limit, all.count)
        guard start <= end else {
            return .failure(ConnectError(code: .invalidArgument, message: "bad page token"))
        }

        var response = Post_V1_ListPostsByProfileResponse()
        response.posts = all[start..<end].map { record in
            var summary = Post_V1_PostSummary()
            summary.postID = record.postID
            summary.kind = Self.kind(forMediaURL: record.mediaURL)
            summary.status = .published
            summary.createdAtMs = record.createdAtMS
            return summary
        }
        response.nextToken = end < all.count ? String(end) : ""
        return .success(response)
    }

    /// The dataset encodes post kind in the media URL — the `video` host under
    /// the synthetic catalog, the file extension under the real one; no media
    /// at all is a text-only post.
    private static func kind(forMediaURL url: String?) -> Post_V1_PostKind {
        guard let url else { return .textOnly }
        return MockMediaFixtures.isVideoURL(url) ? .mainVideo : .carousel
    }

    private func makeAttachment(url: String, width: Int, height: Int) -> Post_V1_MediaAttachmentView {
        var attachment = Post_V1_MediaAttachmentView()
        attachment.cdnURL = url
        // The snap feed routes on MIME, so this is what decides whether a post
        // plays. An HLS manifest would declare the manifest type, not a
        // `video/*` one.
        attachment.mimeType = MockMediaFixtures.mimeType(for: url)
        attachment.width = UInt32(width)
        attachment.height = UInt32(height)
        // A still poster for video, mirroring what `thumbnail_url` means on the
        // wire — never the video URL itself, which an image pipeline cannot
        // decode.
        // ⚠️ A CLIP'S POSTER IS ITS OWN FIRST FRAME, when we have one.
        //
        // This used to hand every video post a picsum photograph, because an
        // HLS manifest is useless to an image pipeline. But a poster is what the
        // page SHOWS until the first frame decodes, so a picture of somewhere
        // else is what the viewer saw — and after a map flight carrying the
        // clip's own frame, it read as the post changing its mind. Where the
        // clip has a baked preview, this points at it instead and the app
        // resolves the scheme from the sheet it already holds.
        attachment.thumbnailURL = if let clip = MockMediaFixtures.bakedClip(for: url) {
            "\(MockMediaFixtures.previewPosterScheme)\(clip)"
        } else if MockMediaFixtures.isVideoURL(url) {
            // ⚠️ NOT A PHOTOGRAPH. This branch used to hand a clip with no baked
            // sheet a stock picture, which is the same lie the map's pin URL
            // told: a picture of somewhere else standing in for a frame we do
            // not have from a SHEET — so it comes from the clip itself, which
            // is the same picture by a slower route.
            MockMediaFixtures.frameZeroURL(for: url)
        } else {
            url
        }
        return attachment
    }

    // MARK: - profile.v1

    private func getProfileByID(_ request: Profile_V1_GetProfileByIdRequest) -> Result<Profile_V1_ProfileView, ConnectError> {
        // The viewer's own profile, so their authored posts hydrate. Identity
        // fields come from the mutable overlay so a save via UpdateProfile /
        // ChangeHandle is reflected on the next read.
        if request.profileID == MockPostStore.viewer.profileID {
            let snapshot = lock.withLock {
                (handle: viewerHandle, name: viewerDisplayName, bio: viewerBio, website: viewerWebsite, links: viewerLinks)
            }
            var view = Profile_V1_ProfileView()
            view.profileID = MockPostStore.viewer.profileID
            view.accountID = dataset.accountID(for: MockPostStore.viewer.profileID)
            view.handle = snapshot.handle
            view.displayName = snapshot.name
            view.avatarURL = MockPostStore.viewer.avatarURL
            view.bio = snapshot.bio
            view.websiteURL = snapshot.website
            view.customLinks = snapshot.links.map { link in
                var proto = Profile_V1_ProfileLinkProto()
                proto.label = link.label
                proto.url = link.url
                return proto
            }
            view.visibility = lock.withLock { visibilityOverrides[view.profileID] } ?? .public
            applyAccountType(to: &view)
            // An approved request is the badge.
            if let approved = lock.withLock({ verificationRequests[view.profileID] }), approved.status == .approved {
                view.verified = true
                view.verificationKind = approved.category
            }
            if let location = lock.withLock({ locationSettings[view.profileID] }) { view.locationSettings = location }
            // Owner-only on the fleet; the viewer's own view here.
            view.discoverySettings = lock.withLock { discoverySettings[view.profileID] } ?? Self.defaultDiscoverySettings
            view.interactionSettings = storedInteractionSettings(for: view.profileID)
            // Owner-only on the fleet; the viewer's own view here.
            view.feedSettings = lock.withLock { feedSettings[view.profileID] } ?? {
                var settings = Profile_V1_FeedSettings()
                settings.sensitiveContent = .less
                return settings
            }()
            view.tabSettings = lock.withLock { tabSettings[view.profileID] } ?? Self.defaultTabSettings
            view.commentFilters = storedCommentFilters(for: view.profileID)
            return .success(view)
        }
        guard let author = dataset.author(for: request.profileID) else {
            return .failure(ConnectError(code: .notFound, message: "profile \(request.profileID) not found"))
        }
        var view = Profile_V1_ProfileView()
        view.profileID = author.profileID
        view.accountID = dataset.accountID(for: author.profileID)
        view.handle = author.handle
        view.displayName = author.displayName
        view.avatarURL = author.avatarURL
        view.bio = author.bio
        view.websiteURL = author.websiteURL
        // Relationship-list privacy, carried on the whole-profile flag because
        // it is the only privacy field `profile.v1` has. Roughly half the
        // roster is restricted — see `MockSocialDataset.isRelationshipsPrivate`
        // for the pattern and `dev/BACKEND_GAPS.md` §13 for the contract this
        // is standing in for.
        view.visibility = lock.withLock { visibilityOverrides[author.profileID] }
            ?? (dataset.isRelationshipsPrivate(author.profileID) ? .private : .public)
        applyAccountType(to: &view)
        // Public on the view, so others can show "comments limited".
        view.interactionSettings = storedInteractionSettings(for: author.profileID)
        // The viewer's other profiles answer here too.
        if let settings = lock.withLock({ feedSettings[author.profileID] }) { view.feedSettings = settings }
        return .success(view)
    }

    /// A `@handle` in text, to the profile it names (#524): the same view
    /// `GetProfileById` answers, so the push carries everything it would.
    private func getProfileByHandle(_ request: Profile_V1_GetProfileByHandleRequest) -> Result<Profile_V1_ProfileView, ConnectError> {
        let handle = request.handle.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        let ownHandle = lock.withLock { self.viewerHandle }
        let profileID = handle == ownHandle.lowercased()
            ? MockPostStore.viewer.profileID
            : dataset.authors.first { $0.handle.lowercased() == handle }?.profileID
        guard let profileID else {
            return .failure(ConnectError(code: .notFound, message: "no profile @\(handle)"))
        }
        var byID = Profile_V1_GetProfileByIdRequest()
        byID.profileID = profileID
        return getProfileByID(byID)
    }

    private func listProfilesByAccount(_ request: Profile_V1_ListProfilesByAccountRequest) -> Result<Profile_V1_ListProfilesByAccountResponse, ConnectError> {
        var response = Profile_V1_ListProfilesByAccountResponse()
        func summary(id: String, handle: String, name: String, avatar: String) -> Profile_V1_ProfileSummaryView {
            var summary = Profile_V1_ProfileSummaryView()
            summary.profileID = id
            summary.handle = handle
            summary.displayName = name
            summary.avatarURL = avatar
            return summary
        }
        // Answers for ANY seeded account, not just the viewer's: the profile
        // screen's account-wide block resolves a stranger's aliases through
        // this route. (Whether the real fleet should expose that to an
        // arbitrary viewer is an open question — see dev/BACKEND_GAPS.md §12.)
        // The viewer's own account keeps its exact previous answer, viewer
        // first, because every viewer-id resolver takes `.first`.
        response.profiles = dataset.profileIDs(inAccount: request.accountID).compactMap { id in
            if id == MockSocialDataset.viewerProfileID {
                return summary(
                    id: id, handle: "you",
                    name: "Demo Viewer", avatar: MockPostStore.viewer.avatarURL
                )
            }
            guard let author = dataset.author(for: id) else { return nil }
            return summary(
                id: author.profileID, handle: author.handle,
                name: author.displayName, avatar: author.avatarURL
            )
        }
        return .success(response)
    }

    /// Persists edited metadata (display name, bio, website, links) into the
    /// mutable overlay so the next `GetProfileById` reflects it. No field mask
    /// in the contract, so the request carries the full set — we store it whole.
    private func updateProfile(_ request: Profile_V1_UpdateProfileRequest) -> Result<Profile_V1_CommandResponse, ConnectError> {
        guard request.profileID == MockPostStore.viewer.profileID else {
            return .failure(ConnectError(code: .permissionDenied, message: "can only edit your own profile"))
        }
        lock.withLock {
            viewerDisplayName = request.displayName
            viewerBio = request.bio
            viewerWebsite = request.websiteURL
            viewerLinks = request.customLinks.map { (label: $0.label, url: $0.url) }
        }
        return .success(Self.accepted(profileID: request.profileID))
    }

    /// Swaps the viewer's @handle in the overlay (the fleet tombstones the old
    /// one for 30 days; the mock just renames). Rejects an empty handle.
    private func changeHandle(_ request: Profile_V1_ChangeHandleRequest) -> Result<Profile_V1_CommandResponse, ConnectError> {
        guard request.profileID == MockPostStore.viewer.profileID else {
            return .failure(ConnectError(code: .permissionDenied, message: "can only change your own handle"))
        }
        let handle = request.newHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else {
            return .failure(ConnectError(code: .invalidArgument, message: "handle cannot be empty"))
        }
        lock.withLock { viewerHandle = handle }
        return .success(Self.accepted(profileID: request.profileID))
    }

    /// Whether a profile is private right now: a `SetVisibility` write, else
    /// the seed (the viewer's profiles start public). The social graph reads
    /// it to turn a follow into a request.
    public func isPrivate(_ profileID: String) -> Bool {
        if let override = lock.withLock({ visibilityOverrides[profileID] }) { return override == .private }
        guard dataset.author(for: profileID) != nil else { return false }
        return dataset.isRelationshipsPrivate(profileID)
    }

    private func setVisibility(_ request: Profile_V1_SetVisibilityRequest) -> Result<Profile_V1_CommandResponse, ConnectError> {
        let viewerAccount = dataset.accountID(for: MockPostStore.viewer.profileID)
        guard request.profileID == MockPostStore.viewer.profileID
            || dataset.accountID(for: request.profileID) == viewerAccount else {
            return .failure(ConnectError(code: .permissionDenied, message: "can only change your own profiles"))
        }
        guard request.visibility == .public || request.visibility == .private else {
            return .failure(ConnectError(code: .invalidArgument, message: "visibility must be PUBLIC or PRIVATE"))
        }
        lock.withLock { visibilityOverrides[request.profileID] = request.visibility }
        return .success(Self.accepted(profileID: request.profileID))
    }

    private static func accepted(profileID: String) -> Profile_V1_CommandResponse {
        var response = Profile_V1_CommandResponse()
        response.success = true
        response.profileID = profileID
        return response
    }
}
