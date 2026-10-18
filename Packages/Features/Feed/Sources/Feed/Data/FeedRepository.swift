import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreStorage
import Foundation
import OSLog

public enum FeedError: Error, Equatable, Sendable {
    case notAuthenticated
    case noProfileForAccount
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
    /// The server shows this post to no one but its author (#447, backend
    /// #686/#688/#691): a draft, a deleted or taken-down post, or one its
    /// author's audience withholds. An answer — retrying changes nothing.
    case notFound
}

extension FeedError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// What the feed UI consumes; implemented by `FeedRepository`, faked in
/// view-model tests.
public protocol FeedProviding: Sendable {
    /// Last persisted first page, for instant offline-first render. Never fails
    /// visibly — a broken or missing copy is just a cache miss.
    func cachedFirstPage() async -> [FeedEntry]?
    func loadFirstPage() async throws -> FeedPage
    func loadPage(afterToken token: String) async throws -> FeedPage
    /// A single post hydrated with its author and like count — the post-detail
    /// read path.
    func loadPost(_ id: PostID) async throws -> FeedEntry
    /// The post as the server holds it NOW, past any warm copy — what a
    /// screen opened on one post (its detail, its comments) confirms with
    /// (#447). A post taken down, deleted or withheld since it was cached
    /// reads as `FeedError.notFound`, and leaves the cache.
    func revalidatePost(_ id: PostID) async throws -> FeedEntry
    /// Best-effort, cancellable warming of `ids` into the repository's post
    /// cache, so a later `loadPost` (e.g. a Maps pin tap opening the snap feed)
    /// resolves from memory instead of the network. Safe to call for ids that
    /// may never be opened.
    func prewarm(_ ids: [PostID]) async
    /// A SYNCHRONOUS peek at the warmed post cache — nil on a miss, never a
    /// fetch. Exists for exactly one caller: seeding a pin-opened snap feed
    /// BEFORE its push begins, the way For You seeds from its grid. An async
    /// read cannot serve that moment — the push starts in the same runloop
    /// turn the feed is built in, so anything awaited lands mid-flight and
    /// rebuilds the nav chrome inside the animation (the measured "flash").
    nonisolated func peekPost(_ id: PostID) -> FeedEntry?
    /// The viewer was shown `id` (#970): see `FeedLocalCache.didShow`.
    nonisolated func didShow(_ id: PostID)
    /// Holds a post the client already has in full, so it is never fetched
    /// back.
    ///
    /// For the one post that can be on screen before the server has served it:
    /// the viewer's own, just published from the Text Post page. The fleet's
    /// GetPost may lag behind PublishPost, and the page that post becomes would
    /// then render "Couldn't load this post" over text the viewer can see they
    /// wrote.
    func remember(_ entry: FeedEntry) async
    /// Whether a page's like counts were read for it (the timeline's batched
    /// counter read) rather than taken from a copy — a post cache keeps each
    /// post as it was fetched. A fresh count replaces the app's live one
    /// (`EntityStore`, #896); a copy only fills one it does not know.
    nonisolated var pagesCarryFreshCounts: Bool { get }
}

public extension FeedProviding {
    /// A provider with no cache of its own: its read is already fresh.
    func revalidatePost(_ id: PostID) async throws -> FeedEntry { try await loadPost(id) }

    /// The viewer was shown `id`: a page fetched ahead that carries it is
    /// promoted on the device (#970). Nothing for a provider with no device
    /// cache.
    nonisolated func didShow(_ id: PostID) {}

    /// Most providers have no synchronous cache; a miss just means the
    /// caller falls back to the async path it already has.
    nonisolated func peekPost(_ id: PostID) -> FeedEntry? { nil }
    nonisolated var pagesCarryFreshCounts: Bool { true }
}

public extension FeedProviding {
    /// Providers without a cache (test doubles, the fixed-set adapter) treat
    /// warming as a no-op.
    func prewarm(_ ids: [PostID]) async {}
    /// …and remembering too: they fetch whatever they are asked for.
    func remember(_ entry: FeedEntry) async {}
}

/// The engagement write/read path the feed UI consumes.
///
/// ⚠️ A LIKE IS A POINT (#676, backend #665): staked through `wallet.Stake`,
/// final — there is no unlike — and the count is the sum of everyone's
/// points. The reaction kinds (heart, fire, …) and their upsert/remove are
/// gone from the contracts.
public protocol EngagementProviding: Sendable {
    /// One like: one point on the post, committed at once. Throws when it
    /// does not land — a transport failure, or a refusal (`LikeRefused`) —
    /// and callers roll back their optimistic state.
    func like(_ postID: PostID) async throws
    /// Authoritative like counts — the reconcile read after a realtime
    /// reconnect (the plane buffers nothing). engagement.v1 `BatchGetLikes`.
    func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64]
}

/// A comment's likes (#637): its count — everyone's points — and the
/// viewer's own points on it.
public struct CommentLikes: Equatable, Sendable {
    public var count: Int64
    public var mine: Int64

    public init(count: Int64, mine: Int64) {
        self.count = count
        self.mine = mine
    }
}

/// Comment likes, as point stakes like a post's (#637, the owner's call
/// 2026-10-13): one point per tap through `wallet.Stake` on the comment,
/// final, read back by engagement's `BatchGetLikes`. A capability of its
/// own, so engagement fakes that know only posts need not answer it.
public protocol CommentLiking: Sendable {
    /// One point on the comment, committed at once. Throws when it does not
    /// land (a transport failure, or `LikeRefused`).
    func likeComment(_ commentID: String) async throws
    /// The comments' likes, by id; a comment the server does not answer for
    /// is absent.
    func commentLikes(for commentIDs: [String]) async throws -> [String: CommentLikes]
}

/// The server answered a like with a refusal: no point went on the post.
public struct LikeRefused: Error, Equatable {
    public let outcome: LikeStakeAnswer.Outcome
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
    /// Where a like is committed (`wallet.Stake`); nil outside the app, where
    /// a like throws.
    private let likeStaking: (any LikeStaking)?
    private let authSession: any AuthSessionProviding
    /// The following timeline's pages on the device (#893): the first page a
    /// cold start opens on, the pages after it, and the cursor to go on.
    private nonisolated let localCache: FeedLocalCache?
    private let pageSize: Int32
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "feed")

    /// Who is signed in, and as which profile — shared with every other
    /// repository (`ViewerSession`), so a switch or a sign-out reaches all of them.
    private let viewer: any ViewerProviding
    private var authorCache: [ProfileID: AuthorSummary] = [:]

    /// Bounded LRU cache of hydrated posts, warmed by `prewarm` and read by
    /// `loadPost`. Kept small so a long map-panning session can't accumulate
    /// unbounded cards in memory — the point of the lightweight Radar tier.
    private var postCache: [PostID: FeedEntry] = [:]
    /// Post ids in least→most-recently-used order (last == most recent).
    private var postCacheOrder: [PostID] = []
    private let postCacheLimit = 80
    /// In-flight hydrations, so a prewarm sweep and a real tap for the same id
    /// share one network fetch instead of racing (single-flight).
    private var inFlightPosts: [PostID: Task<FeedEntry, any Error>] = [:]

    public init(
        timelineClient: any Timeline_V1_TimelineServiceClientInterface,
        postClient: any Post_V1_PostServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        counterClient: any Counter_V1_CounterServiceClientInterface,
        engagementClient: any Engagement_V1_EngagementServiceClientInterface,
        likeStaking: (any LikeStaking)? = nil,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil,
        localCache: FeedLocalCache? = nil,
        pageSize: Int32 = 20
    ) {
        self.timelineClient = timelineClient
        self.postClient = postClient
        self.profileClient = profileClient
        self.counterClient = counterClient
        self.engagementClient = engagementClient
        self.likeStaking = likeStaking
        self.authSession = authSession
        // Nil only outside the app (tests, previews): a session of its own,
        // resolving through this repository's profile client.
        self.viewer = viewer ?? ViewerSession(authSession: authSession) { [profileClient] account in
            try await AccountProfilesReader.profileIDs(ofAccount: account.rawValue, using: profileClient)
                .map { ProfileID($0) }
        }
        self.localCache = localCache
        self.pageSize = pageSize
    }

    // MARK: - FeedProviding

    public func cachedFirstPage() async -> [FeedEntry]? {
        guard let entries = localCache?.firstPage(of: .following)?.entries, !entries.isEmpty else { return nil }
        return entries
    }

    public func loadFirstPage() async throws -> FeedPage {
        // Whose page this is, asked BEFORE the fetch: a page that lands after
        // a switch is not written as the next viewer's.
        let writer = localCache?.viewer
        let page = try await loadPage(token: "")
        localCache?.storeFirstPage(page.entries, nextCursor: page.nextPageToken, in: .following, as: writer)
        return page
    }

    public func loadPage(afterToken token: String) async throws -> FeedPage {
        let writer = localCache?.viewer
        let page: FeedPage
        do {
            page = try await loadPage(token: token)
        } catch {
            // Offline after a cold start: the pages the device holds go on
            // where the network cannot.
            guard let stored = localCache?.page(after: token, in: .following) else { throw error }
            return FeedPage(entries: stored.entries, nextPageToken: stored.nextCursor, isCold: false)
        }
        // Fetched ahead of the viewer (`LookaheadPaging`, #970): speculative
        // until one of its posts is shown.
        localCache?.storeNextPage(
            page.entries, nextCursor: page.nextPageToken, after: token, in: .following, as: writer, tier: .speculative
        )
        return page
    }

    public nonisolated func didShow(_ id: PostID) {
        localCache?.didShow(id)
    }

    /// Past the warm cache (#447): `loadPost` answers from memory, so a post
    /// moderation took down after it was cached kept opening until the cache
    /// let it go.
    ///
    /// - **Warm:** one `GetPost` confirms the post is still shown. The copy's
    ///   author and like count stay (the `EntityStore` keeps the live count),
    ///   so the entry differs from the copy only if the post itself changed:
    ///   no counter read, no second render for a count.
    /// - **Cold:** `loadPost`, single-flight with any read already on its way.
    /// - **The viewer's own just-published post** (`remember`): the fleet may
    ///   not serve it yet, so a `NOT_FOUND` keeps the copy until the fleet has
    ///   served it once.
    public func revalidatePost(_ id: PostID) async throws -> FeedEntry {
        let warm = cachedPost(id)
        do {
            let entry: FeedEntry
            if let warm {
                let post = try await fetchPost(id)
                entry = FeedEntry(post: post, author: warm.author, likeCount: warm.likeCount)
                storeInCache(entry)
            } else {
                entry = try await loadPost(id)
            }
            rememberedPosts.remove(id)
            return entry
        } catch FeedError.notFound {
            if rememberedPosts.contains(id), let warm { return warm }
            forgetPosts([id])
            throw FeedError.notFound
        }
    }

    /// Cache-first, single-flight hydration of one post. A warm id returns from
    /// memory; concurrent callers for the same cold id (e.g. a prewarm sweep and
    /// the tap that races it) share a single fetch.
    public func loadPost(_ id: PostID) async throws -> FeedEntry {
        if let cached = cachedPost(id) { return cached }
        if let inFlight = inFlightPosts[id] {
            return try await inFlight.value
        }
        let task = Task { try await hydratePost(id) }
        inFlightPosts[id] = task
        defer { inFlightPosts[id] = nil }
        let entry = try await task.value
        storeInCache(entry)
        return entry
    }

    public func prewarm(_ ids: [PostID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [self] in
                    guard !Task.isCancelled else { return }
                    _ = try? await loadPost(id) // cache-first + single-flight; failures are ignored
                }
            }
        }
    }

    /// The actual network hydration (post + author + like count), unchanged from
    /// the pre-cache path. Isolated so `loadPost` can wrap it with the cache.
    private func hydratePost(_ id: PostID) async throws -> FeedEntry {
        #if DEBUG
        // `-feed-cold-open [ms]` — see `FeedFeatureBuilder.isColdOpenForced`.
        // On the FETCH, deliberately, and not on the transport: the map's tile
        // query has to stay fast or the pin under test never appears.
        if let position = ProcessInfo.processInfo.arguments.firstIndex(of: "-feed-cold-open") {
            let ms = ProcessInfo.processInfo.arguments.dropFirst(position + 1)
                .first.flatMap(Int.init) ?? 800
            try? await Task.sleep(for: .milliseconds(ms))
        }
        #endif
        let post = try await fetchPost(id)

        async let author = fetchAuthor(id: post.authorID)
        async let count = likeCount(for: post.id)
        guard let resolvedAuthor = await author else {
            throw FeedError.transport(message: "author \(post.authorID) unavailable")
        }
        return FeedEntry(post: post, author: resolvedAuthor, likeCount: await count)
    }

    /// The post alone, as the server shows it to this viewer now: `NOT_FOUND`
    /// (a draft, deleted, taken down or withheld) is `FeedError.notFound`.
    private func fetchPost(_ id: PostID) async throws -> Post {
        var request = Post_V1_GetPostRequest()
        request.postID = id.rawValue
        let response = await postClient.getPost(request: request, headers: [:])
        if response.error?.code == .notFound { throw FeedError.notFound }
        guard let view = response.message else {
            throw FeedError.transport(message: response.error?.message ?? "post \(id) unavailable", failure: response.error.map { NetworkFailure($0) })
        }
        return Self.makePost(from: view)
    }

    // MARK: - Post cache (LRU)

    /// The post cache's SYNCHRONOUS mirror — same entries, same evictions,
    /// readable without an actor hop. It exists because `peekPost` (the
    /// pre-push seed's read) must answer in the caller's own runloop turn;
    /// the actor-isolated `postCache` stays the authority and this shadow
    /// is written only where it is.
    private nonisolated let peekablePostCache = LockedPostCacheMirror()

    public nonisolated func peekPost(_ id: PostID) -> FeedEntry? {
        peekablePostCache.entry(for: id)
    }

    /// Into the same cache a warm read fills, so both `loadPost` and the
    /// synchronous peek answer with it.
    public func remember(_ entry: FeedEntry) async {
        rememberedPosts.insert(entry.post.id)
        storeInCache(entry)
    }

    /// Posts the client wrote itself and holds in full (`remember`), until
    /// the fleet has served them once (`revalidatePost`).
    private var rememberedPosts: Set<PostID> = []

    /// Out of every cache: the server no longer shows it (#447). The device's
    /// copy goes too, so a cold start, or an offline page read from the
    /// device, does not open on it before the network has answered.
    private func forgetPosts(_ ids: Set<PostID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            postCache[id] = nil
            peekablePostCache.remove(id)
        }
        postCacheOrder.removeAll { ids.contains($0) }
        localCache?.forgetPosts(ids)
    }

    private func cachedPost(_ id: PostID) -> FeedEntry? {
        guard let entry = postCache[id] else { return nil }
        touchLRU(id)
        return entry
    }

    private func storeInCache(_ entry: FeedEntry) {
        let id = entry.post.id
        postCache[id] = entry
        peekablePostCache.store(entry, for: id)
        touchLRU(id)
        while postCacheOrder.count > postCacheLimit {
            let evicted = postCacheOrder.removeFirst()
            postCache[evicted] = nil
            peekablePostCache.remove(evicted)
        }
    }

    private func touchLRU(_ id: PostID) {
        if let index = postCacheOrder.firstIndex(of: id) {
            postCacheOrder.remove(at: index)
        }
        postCacheOrder.append(id)
    }

    /// Fetches (and caches) a single author, reusing the page-hydration cache.
    private func fetchAuthor(id: ProfileID) async -> AuthorSummary? {
        if let cached = authorCache[id] { return cached }
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = id.rawValue
        let response = await profileClient.getProfileByID(request: request, headers: [:])
        guard let view = response.message else { return nil }
        let author = AuthorSummary(
            id: ProfileID(view.profileID),
            handle: view.handle,
            displayName: view.displayName,
            avatarURL: URL(string: view.avatarURL)
        )
        authorCache[author.id] = author
        return author
    }

    /// The like count for one post, degrading to 0 when the counter read fails.
    private func likeCount(for id: PostID) async -> Int64 {
        ((try? await likeCounts(for: [id])) ?? [:])[id] ?? 0
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
            throw FeedError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
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
        let fetched = await withTaskGroup(of: (Int, Post?, Bool).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    var request = Post_V1_GetPostRequest()
                    request.postID = item.postID
                    let response = await client.getPost(request: request, headers: [:])
                    guard let view = response.message else { return (index, nil, response.error?.code == .notFound) }
                    return (index, Self.makePost(from: view), false)
                }
            }
            var indexed: [(Int, Post?, Bool)] = []
            for await result in group {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }
        }
        let posts = fetched.map(\.1)
        // A post the server no longer shows (#447: taken down, deleted,
        // withheld) leaves the post caches too, memory and device, or a stream
        // opened on it later, or the next cold start, would still serve the copy.
        // The viewer's own just-published post stays: the fleet may not serve
        // it yet (`revalidatePost`).
        forgetPosts(Set(fetched.filter { $0.2 }.map { PostID(items[$0.0].postID) }).subtracting(rememberedPosts))

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

    /// `write` names the caller when it is a write, so a guest reaching it is
    /// reported (`GateAudit`): the member gate should have stopped them first.
    private func resolveViewerProfileID(forWrite write: String? = nil) async throws -> ProfileID {
        do {
            return try await viewer.activeProfileID()
        } catch ViewerError.requiresMember {
            if let write { GateAudit.ungatedWrite(write) }
            throw FeedError.notAuthenticated
        } catch ViewerError.noProfileForAccount {
            throw FeedError.noProfileForAccount
        } catch let error as AccountProfilesReader.ReadError {
            throw FeedError.transport(message: error.message, failure: error.networkFailure)
        }
    }

    /// The domain post a `post.v1` view maps to: the network read and the
    /// device copy (`FeedLocalCache`) decode the same way.
    static func makePost(from view: Post_V1_PostView) -> Post {
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
                    pixelHeight: Int(attachment.height),
                    // The asset behind it (#990): the cache's stable key.
                    assetID: attachment.assetID.isEmpty ? nil : attachment.assetID
                )
            },
            publishedAt: Date(timeIntervalSince1970: TimeInterval(view.publishedAtMs) / 1000),
            likeCountsHidden: view.likeCountsHidden
        )
    }
}

// MARK: - EngagementProviding

extension FeedRepository: EngagementProviding {
    public func like(_ postID: PostID) async throws {
        try await stakeOnePoint(on: .post(postID.rawValue), write: "like")
    }

    /// One sealed point on `target`, committed now rather than through the
    /// outbox: the screen rolls back what does not land.
    private func stakeOnePoint(on target: LikeOutbox.Target, write: String) async throws {
        let profileID = try await resolveViewerProfileID(forWrite: write)
        guard let likeStaking else { throw FeedError.transport(message: "no like path") }
        let now = Date()
        let batch = LikeOutbox.Batch(
            target: target, points: 1, usesStakeShot: false,
            idempotencyKey: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            firstTapAt: now, lastTapAt: now, isSealed: true,
            accountID: nil, profileID: profileID.rawValue
        )
        let answer = try await likeStaking.stake(batch)
        guard answer.outcome == .staked, answer.spent > 0 else { throw LikeRefused(outcome: answer.outcome) }
    }

    public func likeCounts(for postIDs: [PostID]) async throws -> [PostID: Int64] {
        guard !postIDs.isEmpty else { return [:] }
        var counts: [PostID: Int64] = [:]
        // At most 100 targets a call.
        for start in stride(from: 0, to: postIDs.count, by: 100) {
            let chunk = postIDs[start..<min(start + 100, postIDs.count)]
            var request = Engagement_V1_BatchGetLikesRequest()
            request.targets = chunk.map { id in
                var target = Engagement_V1_LikeTarget()
                target.postID = id.rawValue
                return target
            }
            let response = await engagementClient.batchGetLikes(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                // In request order, one view per target.
                for view in body.likes where !view.target.postID.isEmpty {
                    counts[PostID(view.target.postID)] = view.count
                }
            case .failure(let error):
                throw FeedError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
            }
        }
        return counts
    }

}

// MARK: - CommentLiking

extension FeedRepository: CommentLiking {
    public func likeComment(_ commentID: String) async throws {
        try await stakeOnePoint(on: .comment(commentID), write: "likeComment")
    }

    public func commentLikes(for commentIDs: [String]) async throws -> [String: CommentLikes] {
        var likes: [String: CommentLikes] = [:]
        // At most 100 targets a call.
        for start in stride(from: 0, to: commentIDs.count, by: 100) {
            var request = Engagement_V1_BatchGetLikesRequest()
            request.targets = commentIDs[start..<min(start + 100, commentIDs.count)].map { id in
                var target = Engagement_V1_LikeTarget()
                target.commentID = id
                return target
            }
            let response = await engagementClient.batchGetLikes(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                for view in body.likes where !view.target.commentID.isEmpty {
                    likes[view.target.commentID] = CommentLikes(count: view.count, mine: view.mine)
                }
            case .failure(let error):
                throw FeedError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
            }
        }
        return likes
    }
}

/// The lock-guarded shadow behind `FeedRepository.peekPost` — a plain
/// dictionary under an `NSLock` (the store idiom), because the actor's own
/// cache cannot be read without a hop and the peek's whole reason to exist
/// is answering synchronously. `@unchecked Sendable`: every access goes
/// through the lock.
private final class LockedPostCacheMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PostID: FeedEntry] = [:]

    func entry(for id: PostID) -> FeedEntry? {
        lock.withLock { entries[id] }
    }

    func store(_ entry: FeedEntry, for id: PostID) {
        lock.withLock { entries[id] = entry }
    }

    func remove(_ id: PostID) {
        lock.withLock { entries[id] = nil }
    }
}
