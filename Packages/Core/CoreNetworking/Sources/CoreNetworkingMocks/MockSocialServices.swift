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
        bff.register(path: "/profile.v1.ProfileService/GetProfileById") { [self] (request: Profile_V1_GetProfileByIdRequest) in
            getProfileByID(request)
        }
        bff.register(path: "/profile.v1.ProfileService/ListProfilesByAccount") { [self] (request: Profile_V1_ListProfilesByAccountRequest) in
            listProfilesByAccount(request)
        }
        bff.register(path: "/profile.v1.ProfileService/UpdateProfile") { [self] (request: Profile_V1_UpdateProfileRequest) in
            updateProfile(request)
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

    private func getPost(_ request: Post_V1_GetPostRequest) -> Result<Post_V1_PostView, ConnectError> {
        // Client-authored posts first, then the seeded dataset.
        if let draft = postStore?.record(for: request.postID) {
            var view = Post_V1_PostView()
            view.postID = draft.postID
            view.profileID = draft.profileID
            view.caption = draft.caption
            view.publishedAtMs = draft.createdAtMS
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
            view.attachments = [makeAttachment(url: media.url, width: media.width, height: media.height)]
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
        let all = (authored + seeded).sorted { $0.createdAtMS > $1.createdAtMS }

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

    /// The dataset encodes post kind in the media URL host (`video` vs
    /// `media`); no media at all is a text-only post.
    private static func kind(forMediaURL url: String?) -> Post_V1_PostKind {
        guard let url else { return .textOnly }
        return url.contains("mock://video/") ? .mainVideo : .carousel
    }

    private func makeAttachment(url: String, width: Int, height: Int) -> Post_V1_MediaAttachmentView {
        var attachment = Post_V1_MediaAttachmentView()
        attachment.cdnURL = url
        // The snap feed routes on MIME: `mock://video/…` posts play, others render as images.
        attachment.mimeType = url.contains("mock://video/") ? "video/mp4" : "image/png"
        attachment.width = UInt32(width)
        attachment.height = UInt32(height)
        attachment.thumbnailURL = url
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
                    name: "Demo Viewer", avatar: "mock://avatar/viewer?w=128&h=128"
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

    private static func accepted(profileID: String) -> Profile_V1_CommandResponse {
        var response = Profile_V1_CommandResponse()
        response.success = true
        response.profileID = profileID
        return response
    }
}
