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
    /// Posts deleted this session, with when (backend #663: a tombstone,
    /// restorable for 30 days). Guarded by `lock`.
    private var deletedPosts: [String: Date] = [:]
    /// How long a deleted post can be restored.
    public static let restoreWindow: TimeInterval = 30 * 86_400
    /// `SetFeedSettings` writes, by profile (backend #731); absent is Less.
    private var feedSettings: [String: Profile_V1_FeedSettings] = [:]
    /// `SetTabSettings` writes, by profile (backend #729): the post window
    /// visitors see, and the tab flags. Absent is the defaults.
    private var tabSettings: [String: Profile_V1_TabSettings] = [:]
    private var viewerDisplayName = MockPostStore.viewer.displayName
    private var viewerBio = MockPostStore.viewer.bio
    private var viewerWebsite = MockPostStore.viewer.websiteURL
    private var viewerLinks: [(label: String, url: String)] = [
        (label: "Portfolio", url: "https://www.example.com/demo/portfolio")
    ]

    public init(
        dataset: MockSocialDataset = MockSocialDataset(),
        postStore: MockPostStore? = nil,
        pageSizeCap: Int32 = 50
    ) {
        self.dataset = dataset
        self.postStore = postStore
        self.pageSizeCap = pageSizeCap
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
        bff.register(path: "/profile.v1.ProfileService/ListProfilesByAccount") { [self] (request: Profile_V1_ListProfilesByAccountRequest) in
            listProfilesByAccount(request)
        }
        bff.register(path: "/profile.v1.ProfileService/UpdateProfile") { [self] (request: Profile_V1_UpdateProfileRequest) in
            updateProfile(request)
        }
        bff.register(path: "/profile.v1.ProfileService/SetFeedSettings") { [self] (request: Profile_V1_SetFeedSettingsRequest) in
            lock.withLock { feedSettings[request.profileID] = request.settings }
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
        bff.register(path: "/profile.v1.ProfileService/SetVisibility") { [self] (request: Profile_V1_SetVisibilityRequest) in
            setVisibility(request)
        }
        bff.register(path: "/profile.v1.ProfileService/ChangeHandle") { [self] (request: Profile_V1_ChangeHandleRequest) in
            changeHandle(request)
        }
    }

    // MARK: - timeline.v1

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
            // Owner-only on the fleet; the viewer's own view here.
            view.feedSettings = lock.withLock { feedSettings[view.profileID] } ?? {
                var settings = Profile_V1_FeedSettings()
                settings.sensitiveContent = .less
                return settings
            }()
            view.tabSettings = lock.withLock { tabSettings[view.profileID] } ?? Self.defaultTabSettings
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
        // The viewer's other profiles answer here too.
        if let settings = lock.withLock({ feedSettings[author.profileID] }) { view.feedSettings = settings }
        return .success(view)
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
