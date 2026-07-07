import AuthInterface
import CoreContracts
import CoreModels
import CoreStorage
import Foundation
import OSLog

public enum FeedError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    case transport(message: String)
}

/// What the feed UI consumes; implemented by `FeedRepository`, faked in
/// view-model tests.
public protocol FeedProviding: Sendable {
    /// Last persisted first page, for instant offline-first render. Never fails
    /// visibly — a broken snapshot is just a cache miss.
    func cachedFirstPage() async -> [FeedEntry]?
    func loadFirstPage() async throws -> FeedPage
    func loadPage(afterToken token: String) async throws -> FeedPage
}

/// The engagement write/read path the feed UI consumes.
public protocol EngagementProviding: Sendable {
    /// Heart reaction on/off. Throws when the server rejects; callers roll
    /// back their optimistic state.
    func setLiked(_ liked: Bool, for postID: PostID) async throws
    /// Authoritative like counts — the reconcile read after a realtime
    /// reconnect (the plane buffers nothing).
    func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64]
}

/// Orchestrates the timeline read path: bare (post_id, author_id) tuples from
/// timeline.v1, hydrated via post.v1/profile.v1 with a concurrent fan-out and
/// per-repository author caching.
///
/// NOTE for the backend team: the contracts expose only singular GetPost /
/// GetProfileById, so a 20-item page costs up to 21+ round trips. Fine against
/// the in-process mock; before real-network launch the BFF should grow a
/// batched or pre-hydrated feed endpoint.
public actor FeedRepository: FeedProviding {
    private let timelineClient: any Timeline_V1_TimelineServiceClientInterface
    private let postClient: any Post_V1_PostServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let counterClient: any Counter_V1_CounterServiceClientInterface
    private let engagementClient: any Engagement_V1_EngagementServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let snapshotStore: CodableFileStore<[FeedEntry]>?
    private let pageSize: Int32
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "feed")

    private var viewerProfileID: ProfileID?
    private var authorCache: [ProfileID: AuthorSummary] = [:]

    public init(
        timelineClient: any Timeline_V1_TimelineServiceClientInterface,
        postClient: any Post_V1_PostServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        counterClient: any Counter_V1_CounterServiceClientInterface,
        engagementClient: any Engagement_V1_EngagementServiceClientInterface,
        authSession: any AuthSessionProviding,
        snapshotStore: CodableFileStore<[FeedEntry]>? = nil,
        pageSize: Int32 = 20
    ) {
        self.timelineClient = timelineClient
        self.postClient = postClient
        self.profileClient = profileClient
        self.counterClient = counterClient
        self.engagementClient = engagementClient
        self.authSession = authSession
        self.snapshotStore = snapshotStore
        self.pageSize = pageSize
    }

    // MARK: - FeedProviding

    public func cachedFirstPage() async -> [FeedEntry]? {
        guard let entries = try? snapshotStore?.load(), !entries.isEmpty else { return nil }
        return entries
    }

    public func loadFirstPage() async throws -> FeedPage {
        let page = try await loadPage(token: "")
        if let snapshotStore {
            do {
                try snapshotStore.save(page.entries)
            } catch {
                logger.error("feed snapshot write failed: \(error)")
            }
        }
        return page
    }

    public func loadPage(afterToken token: String) async throws -> FeedPage {
        try await loadPage(token: token)
    }

    // MARK: - Timeline + hydration

    private func loadPage(token: String) async throws -> FeedPage {
        var request = Timeline_V1_GetFollowingFeedRequest()
        request.profileID = try await resolveViewerProfileID().rawValue
        request.limit = pageSize
        request.pageToken = token

        let response = await timelineClient.getFollowingFeed(request: request, headers: [:])
        let body: Timeline_V1_GetFollowingFeedResponse
        switch response.result {
        case .success(let value):
            body = value
        case .failure(let error):
            throw FeedError.transport(message: error.message ?? "code \(error.code)")
        }

        let entries = await hydrate(items: body.items)
        return FeedPage(
            entries: entries,
            nextPageToken: body.nextPageToken.isEmpty ? nil : body.nextPageToken,
            isCold: body.isCold
        )
    }

    /// Fetches missing authors, then all posts, concurrently. Items whose post
    /// or author can't be hydrated are dropped (logged) rather than failing
    /// the page — one deleted post must not blank the feed.
    private func hydrate(items: [Timeline_V1_FeedItem]) async -> [FeedEntry] {
        let missingAuthorIDs = Set(items.map { ProfileID($0.authorID) }).filter { authorCache[$0] == nil }
        if !missingAuthorIDs.isEmpty {
            let client = profileClient
            let fetched = await withTaskGroup(of: AuthorSummary?.self) { group in
                for id in missingAuthorIDs {
                    group.addTask {
                        var request = Profile_V1_GetProfileByIdRequest()
                        request.profileID = id.rawValue
                        let response = await client.getProfileByID(request: request, headers: [:])
                        guard let view = response.message else { return nil }
                        return AuthorSummary(
                            id: ProfileID(view.profileID),
                            handle: view.handle,
                            displayName: view.displayName,
                            avatarURL: URL(string: view.avatarURL)
                        )
                    }
                }
                return await group.reduce(into: [AuthorSummary]()) { partial, author in
                    if let author { partial.append(author) }
                }
            }
            for author in fetched {
                authorCache[author.id] = author
            }
        }

        let client = postClient
        let posts = await withTaskGroup(of: (Int, Post?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    var request = Post_V1_GetPostRequest()
                    request.postID = item.postID
                    let response = await client.getPost(request: request, headers: [:])
                    guard let view = response.message else { return (index, nil) }
                    return (index, Self.makePost(from: view))
                }
            }
            var indexed: [(Int, Post?)] = []
            for await result in group {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var hydrated: [(Timeline_V1_FeedItem, Post)] = []
        for (item, post) in zip(items, posts) {
            guard let post, authorCache[ProfileID(item.authorID)] != nil else {
                logger.info("dropping feed item \(item.postID): hydration incomplete")
                continue
            }
            hydrated.append((item, post))
        }

        // One batched counter read per page (counter.v1 is built for this).
        let counts = (try? await likeCounts(for: hydrated.map(\.1.id))) ?? [:]

        return hydrated.map { item, post in
            FeedEntry(
                post: post,
                author: authorCache[ProfileID(item.authorID)]!,
                likeCount: counts[post.id] ?? 0
            )
        }
    }

    private func resolveViewerProfileID() async throws -> ProfileID {
        if let viewerProfileID {
            return viewerProfileID
        }
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw FeedError.notAuthenticated
        }

        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            guard let profile = body.profiles.first else {
                throw FeedError.noProfileForAccount
            }
            let id = ProfileID(profile.profileID)
            viewerProfileID = id
            return id
        case .failure(let error):
            throw FeedError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    private static func makePost(from view: Post_V1_PostView) -> Post {
        Post(
            id: PostID(view.postID),
            authorID: ProfileID(view.profileID),
            caption: view.caption,
            attachments: view.attachments.map { attachment in
                MediaAttachment(
                    url: URL(string: attachment.cdnURL),
                    thumbnailURL: URL(string: attachment.thumbnailURL),
                    mimeType: attachment.mimeType,
                    pixelWidth: Int(attachment.width),
                    pixelHeight: Int(attachment.height)
                )
            },
            publishedAt: Date(timeIntervalSince1970: TimeInterval(view.publishedAtMs) / 1000)
        )
    }
}

// MARK: - EngagementProviding

extension FeedRepository: EngagementProviding {
    public func setLiked(_ liked: Bool, for postID: PostID) async throws {
        let profileID = try await resolveViewerProfileID()

        if liked {
            var request = Engagement_V1_UpsertReactionRequest()
            request.postID = postID.rawValue
            request.profileID = profileID.rawValue
            request.kind = .heart
            let response = await engagementClient.upsertReaction(request: request, headers: [:])
            if let error = response.error {
                throw FeedError.transport(message: error.message ?? "code \(error.code)")
            }
        } else {
            var request = Engagement_V1_RemoveReactionRequest()
            request.postID = postID.rawValue
            request.profileID = profileID.rawValue
            let response = await engagementClient.removeReaction(request: request, headers: [:])
            if let error = response.error {
                throw FeedError.transport(message: error.message ?? "code \(error.code)")
            }
        }
    }

    public func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] {
        guard !postIDs.isEmpty else { return [:] }

        var request = Counter_V1_BatchGetCountersRequest()
        request.entities = postIDs.map { id in
            var entity = Counter_V1_EntityRef()
            entity.entityType = .post
            entity.id = id.rawValue
            return entity
        }
        request.metrics = [.like]

        let response = await counterClient.batchGetCounters(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            var counts: [PostID: Int64] = [:]
            // Snapshots are positional, 1:1 with the request per the contract.
            for snapshot in body.snapshots {
                if let like = snapshot.values.first(where: { $0.metric == .like }) {
                    counts[PostID(snapshot.entity.id)] = like.value
                }
            }
            return counts
        case .failure(let error):
            throw FeedError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
