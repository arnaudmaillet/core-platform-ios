import Connect
import CoreContracts
import CoreModels
import CoreNetworking
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
    /// Tiles for a list of post ids the caller already has.
    ///
    /// The Saved pile is the only corpus the client itself owns — no service
    /// lists it, so it arrives as bare ids from `PostBookmarkStore` and needs
    /// the same hydration every other tile gets. Order is the caller's, because
    /// a saved pile is ordered by when you saved it and nothing on the wire
    /// knows that.
    func posts(ids: [String]) async throws -> [GalleryPost]
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
    /// Resolves the people whose posts these are. Optional so a composition
    /// root without one still gets a working grid — the tiles simply carry no
    /// author, which is what every tile did before this existed.
    private let profileClient: (any Profile_V1_ProfileServiceClientInterface)?
    /// Identities already resolved, for the life of this actor.
    ///
    /// Cheap and worth it: the authored pages of a profile are by ONE person,
    /// so the whole grid costs a single read and every later page — a tab
    /// switch, a pull to refresh, the saved pile — costs none. A failed read is
    /// cached as nothing known, deliberately: retrying it per page would turn
    /// one unreachable person into a request per render.
    private var authors: [ProfileID: GalleryAuthor?] = [:]
    /// One page today; the grid paginates when profiles outgrow it.
    private let pageLimit: Int32

    public init(
        postClient: any Post_V1_PostServiceClientInterface,
        searchClient: any Search_V1_SearchServiceClientInterface,
        counterClient: any Counter_V1_CounterServiceClientInterface,
        profileClient: (any Profile_V1_ProfileServiceClientInterface)? = nil,
        pageLimit: Int32 = 90
    ) {
        self.postClient = postClient
        self.searchClient = searchClient
        self.counterClient = counterClient
        self.profileClient = profileClient
        self.pageLimit = pageLimit
    }

    public func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
        var request = Post_V1_ListPostsByProfileRequest()
        request.profileID = profileID.rawValue
        request.limit = pageLimit
        let response = await postClient.listPostsByProfile(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return await withCounters(withAuthors(hydrate(postIDs: body.posts.map(\.postID))))
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
                withAuthors(hydrate(postIDs: ids).filter { $0.authorProfileID != profileID })
            )
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    /// Decorates tiles with their counter.v1 projections — reactions,
    /// comments, views — in ONE batched read for the whole page. Best-effort:
    /// a counter outage leaves the counts nil (cells hide them) rather than
    /// failing the grid.
    public func posts(ids: [String]) async throws -> [GalleryPost] {
        guard !ids.isEmpty else { return [] }
        return await withCounters(withAuthors(hydrate(postIDs: ids)))
    }

    /// Attaches the person each tile belongs to.
    ///
    /// ⚠️ **The grid renders none of this**, which is exactly why it was missing
    /// for so long: a profile page has no need to repeat whose posts you are
    /// looking at. It is carried for the surface a tile OPENS INTO — the
    /// full-screen page's author capsule and its attribution pill are seeded
    /// from the tile's own model, and a tile with no author seeds a page with
    /// an anonymous one. `ForYouDiscovery` has carried it for the same reason
    /// since that grid learned to seed; this is the same fact, resolved the only
    /// way this repository can get it.
    ///
    /// One read per DISTINCT author, not per post: the authored pages are a
    /// single person, so a whole grid is one round trip. `post.v1` carries only
    /// `profile_id` on a post view, so this cannot be folded into hydration —
    /// see `dev/BACKEND_GAPS.md`; a `GetPost` that embedded its author would
    /// remove this hop entirely.
    private func withAuthors(_ hydrated: [HydratedPost]) async -> [GalleryPost] {
        guard profileClient != nil else { return hydrated.map(\.post) }
        let wanted = Set(hydrated.map(\.authorProfileID)).filter { authors[$0] == nil }
        if !wanted.isEmpty {
            let resolved = await withTaskGroup(of: (ProfileID, GalleryAuthor?).self) { group in
                for id in wanted {
                    group.addTask { [profileClient] in (id, await Self.author(of: id, using: profileClient)) }
                }
                var collected: [(ProfileID, GalleryAuthor?)] = []
                for await pair in group { collected.append(pair) }
                return collected
            }
            for (id, author) in resolved { authors[id] = author }
        }
        return hydrated.map { item in
            guard let author = authors[item.authorProfileID] ?? nil else { return item.post }
            var decorated = item.post
            decorated.authorID = item.authorProfileID
            decorated.authorName = author.displayName
            decorated.authorHandle = author.handle
            decorated.authorAvatarURL = author.avatarURL
            return decorated
        }
    }

    private static func author(
        of id: ProfileID, using client: (any Profile_V1_ProfileServiceClientInterface)?
    ) async -> GalleryAuthor? {
        guard let client else { return nil }
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = id.rawValue
        let response = await client.getProfileByID(request: request, headers: [:])
        guard case .success(let view) = response.result else { return nil }
        return GalleryAuthor(
            displayName: view.displayName,
            handle: view.handle,
            avatarURL: URL(string: view.avatarURL)
        )
    }

    private func withCounters(_ posts: [GalleryPost]) async -> [GalleryPost] {
        guard !posts.isEmpty else { return posts }
        // The read itself is `PostCounterReader`, shared with the feed since its
        // cards started showing reach — one batch shape, not two.
        let byPostID = await PostCounterReader.counters(
            forPostIDs: posts.map(\.id.rawValue), using: counterClient
        )
        return posts.map { post in
            guard let counts = byPostID[post.id.rawValue] else { return post }
            var decorated = post
            decorated.reactionCount = counts.likes
            decorated.commentCount = counts.comments
            decorated.viewCount = counts.views
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

/// The identity slice a full-screen page needs from whoever wrote a tile —
/// nothing more, since the grid itself draws none of it.
private struct GalleryAuthor: Sendable {
    let displayName: String
    let handle: String
    let avatarURL: URL?
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
            // Every attachment, in the author's order — `attachments` is a
            // repeated field and this projection used to keep only its head.
            pages: view.attachments.map { attachment in
                GalleryPost.MediaPage(
                    thumbnailURL: URL(
                        string: attachment.thumbnailURL.isEmpty
                            ? attachment.cdnURL : attachment.thumbnailURL
                    ),
                    // The stream itself, shared with the full-screen viewer so
                    // the hero zoom keeps one item — see `GalleryPost.videoURL`.
                    videoURL: attachment.mimeType.hasPrefix("video/")
                        ? URL(string: attachment.cdnURL) : nil,
                    // Missing dimensions fall through to 1 (square), which
                    // withholds autoplay rather than guessing — see
                    // `GalleryPost.aspectRatio`.
                    aspectRatio: attachment.width > 0 && attachment.height > 0
                        ? Double(attachment.width) / Double(attachment.height)
                        : 1
                )
            },
            caption: view.caption,
            publishedAtMS: view.publishedAtMs
        )
        authorProfileID = ProfileID(view.profileID)
    }
}
