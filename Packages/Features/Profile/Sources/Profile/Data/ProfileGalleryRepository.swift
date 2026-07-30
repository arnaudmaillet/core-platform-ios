import Connect
import CoreContracts
import CoreModels
import Foundation
import PostGrid

/// What the gallery UI consumes; implemented by `ProfileGalleryRepository`,
/// faked in view-model tests.
public protocol ProfileGalleryProviding: Sendable {
    /// The profile's own published posts (reposts included — split client-side
    /// on `isRepost`), newest first.
    func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost]
    /// Posts by *others* that mention `handle` — the "Tagged" category.
    /// Resolved through search.v1 post search, so fleet quality tracks the
    /// search index; the mock indexes captions exactly.
    func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost]
}

/// Reads the gallery from post.v1 (listing + hydration) and search.v1 (tagged).
///
/// `ListPostsByProfile` returns bare summaries; every tile needs media, so each
/// page is hydrated through `GetPost` — the same summary→view pattern the feed
/// uses. Hydration failures drop the single post rather than failing the grid.
public actor ProfileGalleryRepository: ProfileGalleryProviding {
    private let postClient: any Post_V1_PostServiceClientInterface
    private let searchClient: any Search_V1_SearchServiceClientInterface
    private let counterClient: any Counter_V1_CounterServiceClientInterface
    /// One page today; the grid paginates when profiles outgrow it.
    private let pageLimit: Int32

    public init(
        postClient: any Post_V1_PostServiceClientInterface,
        searchClient: any Search_V1_SearchServiceClientInterface,
        counterClient: any Counter_V1_CounterServiceClientInterface,
        pageLimit: Int32 = 90
    ) {
        self.postClient = postClient
        self.searchClient = searchClient
        self.counterClient = counterClient
        self.pageLimit = pageLimit
    }

    public func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
        var request = Post_V1_ListPostsByProfileRequest()
        request.profileID = profileID.rawValue
        request.limit = pageLimit
        let response = await postClient.listPostsByProfile(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return await withCounters(hydrate(postIDs: body.posts.map(\.postID)).map(\.post))
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] {
        var request = Search_V1_SearchRequest()
        request.query = "@" + handle
        request.entityTypes = [.post]
        let response = await searchClient.search(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            let ids = body.hits.filter { $0.entityType == .post }.map(\.id)
            // Self-mentions aren't "tagged by others"; drop own posts.
            return await withCounters(
                hydrate(postIDs: ids)
                    .filter { $0.authorProfileID != profileID }
                    .map(\.post)
            )
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// Decorates tiles with their counter.v1 projections — reactions,
    /// comments, views — in ONE batched read for the whole page. Best-effort:
    /// a counter outage leaves the counts nil (cells hide them) rather than
    /// failing the grid.
    private func withCounters(_ posts: [GalleryPost]) async -> [GalleryPost] {
        guard !posts.isEmpty else { return posts }
        var request = Counter_V1_BatchGetCountersRequest()
        request.entities = posts.map { post in
            var entity = Counter_V1_EntityRef()
            entity.entityType = .post
            entity.id = post.id.rawValue
            return entity
        }
        request.metrics = [.like, .comment, .view]
        let response = await counterClient.batchGetCounters(request: request, headers: [:])
        guard let snapshots = response.message?.snapshots else { return posts }

        let byPostID = Dictionary(
            snapshots.map { ($0.entity.id, $0.values) },
            uniquingKeysWith: { first, _ in first }
        )
        return posts.map { post in
            guard let values = byPostID[post.id.rawValue] else { return post }
            var decorated = post
            decorated.reactionCount = values.first { $0.metric == .like }?.value
            decorated.commentCount = values.first { $0.metric == .comment }?.value
            decorated.viewCount = values.first { $0.metric == .view }?.value
            return decorated
        }
    }

    /// Hydrates summaries into tiles concurrently, preserving input order.
    private func hydrate(postIDs: [String]) async -> [HydratedPost] {
        await withTaskGroup(of: (Int, HydratedPost?).self) { group in
            for (index, postID) in postIDs.enumerated() {
                group.addTask { [postClient] in
                    var request = Post_V1_GetPostRequest()
                    request.postID = postID
                    let response = await postClient.getPost(request: request, headers: [:])
                    return (index, response.message.map(HydratedPost.init))
                }
            }
            var slots = [HydratedPost?](repeating: nil, count: postIDs.count)
            for await (index, post) in group {
                slots[index] = post
            }
            return slots.compactMap(\.self)
        }
    }
}

/// A gallery post plus the author id (needed for the tagged self-mention
/// filter, but not part of the public tile model).
private struct HydratedPost {
    let post: GalleryPost
    let authorProfileID: ProfileID

    init(view: Post_V1_PostView) {
        let attachment = view.attachments.first
        let kind: GalleryPost.Kind = switch view.kind {
        case .textOnly: .text
        case .mainVideo: .video
        case .carousel: .photo
        case .unspecified, .UNRECOGNIZED:
            // Older services may not stamp a kind; route on MIME like the feed.
            if let mime = attachment?.mimeType, mime.hasPrefix("video/") {
                .video
            } else if attachment != nil {
                .photo
            } else {
                .text
            }
        }
        post = GalleryPost(
            id: PostID(view.postID),
            kind: kind,
            isRepost: !view.parentID.isEmpty,
            thumbnailURL: attachment.flatMap {
                URL(string: $0.thumbnailURL.isEmpty ? $0.cdnURL : $0.thumbnailURL)
            },
            // The stream itself, shared with the full-screen viewer so the hero
            // zoom keeps one item — see `GalleryPost.videoURL`.
            videoURL: kind == .video ? attachment.flatMap { URL(string: $0.cdnURL) } : nil,
            caption: view.caption,
            publishedAtMS: view.publishedAtMs
        )
        authorProfileID = ProfileID(view.profileID)
    }
}
