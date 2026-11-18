import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import MediaCore
import PostGrid

/// One page of the discovery corpus.
public struct DiscoverPage: Sendable, Equatable {
    public let posts: [GalleryPost]
    /// Opaque cursor; nil when the corpus is exhausted.
    public let nextPageToken: String?

    public init(posts: [GalleryPost], nextPageToken: String?) {
        self.posts = posts
        self.nextPageToken = nextPageToken
    }
}

/// What the For You grid consumes; faked in view-model tests.
///
/// Two corpora: `firstPage`/`page(after:)` is the FOLLOWING timeline (the
/// rows, the pushed Friends and Following lists); `discoveryFirstPage`/
/// `discoveryPage(after:)` is DISCOVER's own (`GetDiscoveryFeed`). A provider
/// with no discovery answers nil, and Discover is then the timeline — what
/// it was before the backend served one.
public protocol DiscoverProviding: Sendable {
    func firstPage() async throws -> DiscoverPage
    func page(after token: String) async throws -> DiscoverPage
    func discoveryFirstPage() async throws -> DiscoverPage?
    func discoveryPage(after token: String) async throws -> DiscoverPage?
    /// What the last session loaded, read from the device SYNCHRONOUSLY: the
    /// screen opens on it in its first frame, then revalidates (#893). nil
    /// when nothing is stored for this viewer.
    func cachedPages() -> DiscoverCachedPages?
    /// Keeps where the viewer stands with these authors, so the next cold
    /// start splits the rows as this one did.
    func rememberRelations(_ relations: [ProfileID: FollowRelation]) async
    /// The viewer was shown `id` (#970): a page fetched ahead that carries
    /// it is promoted on the device (`FeedLocalCache.didShow`).
    nonisolated func didShow(_ id: PostID)
}

public extension DiscoverProviding {
    func discoveryFirstPage() async throws -> DiscoverPage? { nil }
    func discoveryPage(after token: String) async throws -> DiscoverPage? { nil }
    func cachedPages() -> DiscoverCachedPages? { nil }
    func rememberRelations(_ relations: [ProfileID: FollowRelation]) async {}
    nonisolated func didShow(_ id: PostID) {}
}

/// For You's corpora as the last session left them on the device.
public struct DiscoverCachedPages: Sendable, Equatable {
    /// Discover's corpus; nil when the provider serves no discovery.
    public let discovery: DiscoverPage?
    /// The following timeline (the rows); empty when none was stored.
    public let following: DiscoverPage
    /// Where the viewer stood with the authors of both.
    public let relations: [ProfileID: FollowRelation]

    public init(discovery: DiscoverPage?, following: DiscoverPage, relations: [ProfileID: FollowRelation]) {
        self.discovery = discovery
        self.following = following
        self.relations = relations
    }
}

/// Serves the For You grid off the existing timeline read path.
///
/// It holds a `FeedProviding` rather than its own clients precisely because the
/// tab is the timeline today: one repository, one hydration path, one cache —
/// so a post opened from a tile is already warm in the snap feed it opens into.
/// When discovery gets its own endpoint this is the type that changes, and
/// nothing above it has to.
public actor DiscoverRepository: DiscoverProviding {
    private nonisolated let feed: any FeedProviding
    /// Reads the numbers the timeline does not carry — see `counters(for:)`.
    /// Optional so a composition root without one still gets a working grid,
    /// with its counters hidden, which is what every card did before this.
    private let postCounters: (any PostCounterReading)?
    /// Discover's own corpus (`DiscoveryFeedRepository`). Nil: Discover is
    /// `feed`.
    private let discovery: (any FeedProviding)?
    /// Both corpora on the device (#893): every page that lands is written
    /// with its counters, and `cachedPages` reads them back at cold start.
    private nonisolated let localCache: FeedLocalCache?

    public init(
        feed: any FeedProviding,
        postCounters: (any PostCounterReading)? = nil,
        discovery: (any FeedProviding)? = nil,
        localCache: FeedLocalCache? = nil
    ) {
        self.feed = feed
        self.postCounters = postCounters
        self.discovery = discovery
        self.localCache = localCache
    }

    public func discoveryFirstPage() async throws -> DiscoverPage? {
        guard let discovery else { return nil }
        let writer = localCache?.viewer
        let page = try await discovery.loadFirstPage()
        let pageCounters = await counters(for: page)
        localCache?.storeFirstPage(page.entries, counters: pageCounters, nextCursor: page.nextPageToken, in: .gridDiscover, as: writer)
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    public func discoveryPage(after token: String) async throws -> DiscoverPage? {
        guard let discovery else { return nil }
        let writer = localCache?.viewer
        let page: FeedPage
        do {
            page = try await discovery.loadPage(afterToken: token)
        } catch {
            guard let stored = storedPage(after: token, in: .gridDiscover) else { throw error }
            return stored
        }
        let pageCounters = await counters(for: page)
        // Fetched ahead of the viewer (`LookaheadPaging`, #970).
        localCache?.storeNextPage(
            page.entries, counters: pageCounters, nextCursor: page.nextPageToken, after: token, in: .gridDiscover,
            as: writer, tier: .speculative
        )
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    public func firstPage() async throws -> DiscoverPage {
        let writer = localCache?.viewer
        let page = try await feed.loadFirstPage()
        let pageCounters = await counters(for: page)
        localCache?.storeFirstPage(page.entries, counters: pageCounters, nextCursor: page.nextPageToken, in: .gridFollowing, as: writer)
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    public func page(after token: String) async throws -> DiscoverPage {
        let writer = localCache?.viewer
        let page: FeedPage
        do {
            page = try await feed.loadPage(afterToken: token)
        } catch {
            guard let stored = storedPage(after: token, in: .gridFollowing) else { throw error }
            return stored
        }
        let pageCounters = await counters(for: page)
        localCache?.storeNextPage(
            page.entries, counters: pageCounters, nextCursor: page.nextPageToken, after: token, in: .gridFollowing,
            as: writer, tier: .speculative
        )
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    /// The page the device holds after `token`, for when the network cannot
    /// answer (offline after a cold start): paging goes on through what the
    /// last session loaded.
    private func storedPage(after token: String, in key: FeedLocalCache.ListKey) -> DiscoverPage? {
        guard let stored = localCache?.page(after: token, in: key) else { return nil }
        let projected = DiscoverPage(posts: stored.entries.map(Self.galleryPost(from:)), nextPageToken: stored.nextCursor)
        return Self.decorate(projected, with: stored.counters)
    }

    /// Discover (when served) and the following timeline's FIRST pages as the
    /// device holds them, projected and decorated exactly as a network page is, so the
    /// revalidation that follows changes nothing when nothing changed.
    ///
    /// nil unless the corpus Discover draws from is stored with posts in it:
    /// a screen half-restored would reshuffle when the rest lands.
    public nonisolated func cachedPages() -> DiscoverCachedPages? {
        guard let localCache else { return nil }
        let following = localCache.firstPage(of: .gridFollowing)
        let discover = discovery == nil ? nil : localCache.firstPage(of: .gridDiscover)
        if discovery != nil {
            guard let discover, !discover.entries.isEmpty else { return nil }
        } else {
            guard let following, !following.entries.isEmpty else { return nil }
        }
        func page(_ list: FeedLocalCache.CachedList?) -> DiscoverPage? {
            guard let list else { return nil }
            let projected = DiscoverPage(posts: list.entries.map(Self.galleryPost(from:)), nextPageToken: list.nextCursor)
            return Self.decorate(projected, with: list.counters)
        }
        let followingPage = page(following) ?? DiscoverPage(posts: [], nextPageToken: nil)
        let discoveryPage = page(discover)
        let authors = Set((followingPage.posts + (discoveryPage?.posts ?? [])).compactMap(\.authorID))
        return DiscoverCachedPages(
            discovery: discoveryPage,
            following: followingPage,
            relations: localCache.relations(for: authors)
        )
    }

    public func rememberRelations(_ relations: [ProfileID: FollowRelation]) async {
        localCache?.storeRelations(relations, as: localCache?.viewer)
    }

    /// Both corpora's prefetched pages, and the timeline's own list
    /// (`feed` writes the following timeline's pages too).
    public nonisolated func didShow(_ id: PostID) {
        localCache?.didShow(id)
        feed.didShow(id)
    }

    /// A page's `counter.v1` projections, applied by `decorate`.
    ///
    /// The timeline read hydrates LIKES only — a `FeedEntry` carries a like
    /// count and nothing else — so a card had no reach to show, and once its
    /// counter chip became views alone it showed no chip at all. One batched
    /// read per page, through `PostCounterReading`, which the profile gallery
    /// uses for the same three numbers.
    ///
    /// Best-effort by construction: an outage answers no snapshots, the counts
    /// stay nil, and the chip hides rather than asserting a zero.
    ///
    /// ⚠️ Likes are taken from the COUNTER when it answers, not merged with the
    /// timeline's own. Two sources for one number is how a card and the post it
    /// opens end up disagreeing; the counter is the one the rest of the app
    /// reads.
    private func counters(for page: FeedPage) async -> [PostID: PostCounters] {
        guard let postCounters, !page.entries.isEmpty else { return [:] }
        let byPostID = await postCounters.counters(forPostIDs: page.entries.map(\.post.id.rawValue))
        return Dictionary(byPostID.map { (PostID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// `page` with its counters applied — the network page and the stored
    /// one alike.
    private static func decorate(_ page: DiscoverPage, with counters: [PostID: PostCounters]) -> DiscoverPage {
        guard !counters.isEmpty else { return page }
        return DiscoverPage(
            posts: page.posts.map { post in
                guard let counts = counters[post.id] else { return post }
                var decorated = post
                decorated.reactionCount = counts.likes ?? post.reactionCount
                decorated.commentCount = counts.comments
                return decorated
            },
            nextPageToken: page.nextPageToken
        )
    }

    /// Projects hydrated timeline entries onto grid tiles.
    ///
    /// `commentCount` is left absent HERE and filled by
    /// `decorate` afterwards: a `FeedEntry` carries a like count and nothing
    /// else, so the numbers come from `counter.v1` in one batched read per page.
    ///
    /// `isRepost` is still absent and still asserted nowhere — a `FeedEntry`
    /// carries no `parent_id` lineage, and a repost split would need it threaded
    /// through first.
    private static func map(_ page: FeedPage) -> DiscoverPage {
        DiscoverPage(
            posts: page.entries.map(galleryPost(from:)),
            nextPageToken: page.nextPageToken
        )
    }
}

extension DiscoverRepository {
    /// One hydrated timeline entry as a grid post — the projection every
    /// surface that draws or flies a post from a `FeedEntry` shares (For You's
    /// pages, the wallet sheet's stakes), so a card and the feed it opens
    /// can never disagree about what the post is.
    static func galleryPost(from entry: FeedEntry) -> GalleryPost {
        let attachment = entry.post.attachments.first
        let kind: GalleryPost.Kind = switch attachment.map({ MediaKind(mimeType: $0.mimeType) }) {
        case .video: .video
        case .image: .photo
        case nil: .text
        }
        // ALL of them, in the author's order. `post.v1.PostView`
        // has always carried a repeated `attachments`; this projection
        // took `.first` and the collection died here rather than on the
        // wire. The kind above still reads the first page, because a
        // post is one thing in a filter even when it is five photos.
        var post = GalleryPost(
            id: entry.post.id,
            kind: kind,
            isRepost: false,
            pages: entry.post.attachments.map { attachment in
                let isVideo = MediaKind(mimeType: attachment.mimeType) == .video
                return GalleryPost.MediaPage(
                    thumbnailURL: attachment.thumbnailURL ?? attachment.url,
                    // `url` is the stream itself, so a tile and the
                    // full-screen viewer open the same asset — see
                    // `GalleryPost.videoURL`.
                    videoURL: isVideo ? attachment.url : nil,
                    // Already 1 when the contract carried no dimensions,
                    // which reads as square and so withholds autoplay —
                    // see `GalleryPost.aspectRatio`.
                    aspectRatio: attachment.aspectRatio
                )
            },
            caption: entry.post.caption,
            publishedAtMS: Int64(entry.post.publishedAt.timeIntervalSince1970 * 1000),
            // Carried so a tile tap can seed the full-screen page with
            // a COMPLETE projection; the grid renders none of it.
            authorID: entry.author.id,
            authorName: entry.author.displayName,
            authorHandle: entry.author.handle,
            authorAvatarURL: entry.author.avatarURL,
            reactionCount: entry.likeCount
        )
        // A text post's voice (#2206): the tile stays `.text`.
        post.voice = entry.post.voice
        // …and a showcase's card (#2216): the tile stays `.text`.
        post.embed = entry.post.embed
        return post
    }
}
