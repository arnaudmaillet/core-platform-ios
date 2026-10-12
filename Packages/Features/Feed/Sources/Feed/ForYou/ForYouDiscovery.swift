import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import MediaCore
import PostGrid

/// The For You tab's source axis — what the navigation bar's drop-down picks.
///
/// This is the discovery counterpart of the profile gallery's
/// `GalleryFilter.Source`, and deliberately a separate enum: the profile asks
/// "whose posts am I looking at" (own / reposts / tagged), which means nothing
/// on a curated surface. The *format* axis is shared — see
/// `GalleryFilter.Format`.
///
/// ⚠️ **Orderings of a LOADED corpus, applied only where Discover has no
/// corpus of its own.** With `timeline.v1.GetDiscoveryFeed` wired
/// (`ForYouProviding.discoveryFirstPage`), Discover keeps the SERVER's order
/// and these apply to nothing; they remain for a provider that serves the
/// following timeline alone (tests, a composition without discovery) —
/// `.recent` by publication, `.trending` by reactions.
///
/// ❌ **There was a third case, `.following` — the timeline's own order,
/// unmodified — and it was REMOVED (2026-08-03), not lost.** The screen's tabs
/// became Discover / Following in the same change, and a source called
/// "Following" sitting beside a tab called "Following" named two independent
/// axes with one word: the pair could be set to disagree (the Following tab
/// showing Trending-ordered posts) and no label on screen explained which was
/// which. Re-adding it needs a different name, not a different menu position —
/// and note it was also the only case that ordered nothing, so what it offered
/// was "however the server happened to answer", which is not a choice a viewer
/// can reason about.
public enum DiscoverySource: Equatable, Sendable, CaseIterable {
    /// Most-reacted first. Ranked over what has been LOADED, not globally —
    /// see the note above.
    case trending
    /// Newest first.
    case recent

    /// Applies the ordering. Stable within equal keys (`sorted(by:)` is not
    /// guaranteed stable, so ties break on publication then id — otherwise a
    /// page append could reshuffle rows the user is already looking at).
    func ordering(_ posts: [GalleryPost]) -> [GalleryPost] {
        switch self {
        case .recent:
            posts.sorted { ($0.publishedAtMS, $0.id.rawValue) > ($1.publishedAtMS, $1.id.rawValue) }
        case .trending:
            posts.sorted {
                ($0.reactionCount ?? 0, $0.publishedAtMS, $0.id.rawValue)
                    > ($1.reactionCount ?? 0, $1.publishedAtMS, $1.id.rawValue)
            }
        }
    }
}

/// One page of the discovery corpus.
public struct ForYouPage: Sendable, Equatable {
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
public protocol ForYouProviding: Sendable {
    func firstPage() async throws -> ForYouPage
    func page(after token: String) async throws -> ForYouPage
    func discoveryFirstPage() async throws -> ForYouPage?
    func discoveryPage(after token: String) async throws -> ForYouPage?
    /// What the last session loaded, read from the device SYNCHRONOUSLY: the
    /// screen opens on it in its first frame, then revalidates (#893). nil
    /// when nothing is stored for this viewer.
    func cachedPages() -> ForYouCachedPages?
    /// Keeps where the viewer stands with these authors, so the next cold
    /// start splits the rows as this one did.
    func rememberRelations(_ relations: [ProfileID: FollowRelation]) async
    /// The viewer was shown `id` (#970): a page fetched ahead that carries
    /// it is promoted on the device (`FeedLocalCache.didShow`).
    nonisolated func didShow(_ id: PostID)
}

public extension ForYouProviding {
    func discoveryFirstPage() async throws -> ForYouPage? { nil }
    func discoveryPage(after token: String) async throws -> ForYouPage? { nil }
    func cachedPages() -> ForYouCachedPages? { nil }
    func rememberRelations(_ relations: [ProfileID: FollowRelation]) async {}
    nonisolated func didShow(_ id: PostID) {}
}

/// For You's corpora as the last session left them on the device.
public struct ForYouCachedPages: Sendable, Equatable {
    /// Discover's corpus; nil when the provider serves no discovery.
    public let discovery: ForYouPage?
    /// The following timeline (the rows); empty when none was stored.
    public let following: ForYouPage
    /// Where the viewer stood with the authors of both.
    public let relations: [ProfileID: FollowRelation]

    public init(discovery: ForYouPage?, following: ForYouPage, relations: [ProfileID: FollowRelation]) {
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
public actor ForYouRepository: ForYouProviding {
    private nonisolated let feed: any FeedProviding
    /// Reads the numbers the timeline does not carry — see `counters(for:)`.
    /// Optional so a composition root without one still gets a working grid,
    /// with its counters hidden, which is what every card did before this.
    private let counterClient: (any Counter_V1_CounterServiceClientInterface)?
    /// Discover's own corpus (`DiscoveryFeedRepository`). Nil: Discover is
    /// `feed`.
    private let discovery: (any FeedProviding)?
    /// Both corpora on the device (#893): every page that lands is written
    /// with its counters, and `cachedPages` reads them back at cold start.
    private nonisolated let localCache: FeedLocalCache?

    public init(
        feed: any FeedProviding,
        counterClient: (any Counter_V1_CounterServiceClientInterface)? = nil,
        discovery: (any FeedProviding)? = nil,
        localCache: FeedLocalCache? = nil
    ) {
        self.feed = feed
        self.counterClient = counterClient
        self.discovery = discovery
        self.localCache = localCache
    }

    public func discoveryFirstPage() async throws -> ForYouPage? {
        guard let discovery else { return nil }
        let writer = localCache?.viewer
        let page = try await discovery.loadFirstPage()
        let pageCounters = await counters(for: page)
        localCache?.storeFirstPage(page.entries, counters: pageCounters, nextCursor: page.nextPageToken, in: .forYouDiscover, as: writer)
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    public func discoveryPage(after token: String) async throws -> ForYouPage? {
        guard let discovery else { return nil }
        let writer = localCache?.viewer
        let page: FeedPage
        do {
            page = try await discovery.loadPage(afterToken: token)
        } catch {
            guard let stored = storedPage(after: token, in: .forYouDiscover) else { throw error }
            return stored
        }
        let pageCounters = await counters(for: page)
        // Fetched ahead of the viewer (`LookaheadPaging`, #970).
        localCache?.storeNextPage(
            page.entries, counters: pageCounters, nextCursor: page.nextPageToken, after: token, in: .forYouDiscover,
            as: writer, tier: .speculative
        )
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    public func firstPage() async throws -> ForYouPage {
        let writer = localCache?.viewer
        let page = try await feed.loadFirstPage()
        let pageCounters = await counters(for: page)
        localCache?.storeFirstPage(page.entries, counters: pageCounters, nextCursor: page.nextPageToken, in: .forYouFollowing, as: writer)
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    public func page(after token: String) async throws -> ForYouPage {
        let writer = localCache?.viewer
        let page: FeedPage
        do {
            page = try await feed.loadPage(afterToken: token)
        } catch {
            guard let stored = storedPage(after: token, in: .forYouFollowing) else { throw error }
            return stored
        }
        let pageCounters = await counters(for: page)
        localCache?.storeNextPage(
            page.entries, counters: pageCounters, nextCursor: page.nextPageToken, after: token, in: .forYouFollowing,
            as: writer, tier: .speculative
        )
        return Self.decorate(Self.map(page), with: pageCounters)
    }

    /// The page the device holds after `token`, for when the network cannot
    /// answer (offline after a cold start): paging goes on through what the
    /// last session loaded.
    private func storedPage(after token: String, in key: FeedLocalCache.ListKey) -> ForYouPage? {
        guard let stored = localCache?.page(after: token, in: key) else { return nil }
        let projected = ForYouPage(posts: stored.entries.map(Self.galleryPost(from:)), nextPageToken: stored.nextCursor)
        return Self.decorate(projected, with: stored.counters)
    }

    /// Discover (when served) and the following timeline's FIRST pages as the
    /// device holds them, projected and decorated exactly as a network page is, so the
    /// revalidation that follows changes nothing when nothing changed.
    ///
    /// nil unless the corpus Discover draws from is stored with posts in it:
    /// a screen half-restored would reshuffle when the rest lands.
    public nonisolated func cachedPages() -> ForYouCachedPages? {
        guard let localCache else { return nil }
        let following = localCache.firstPage(of: .forYouFollowing)
        let discover = discovery == nil ? nil : localCache.firstPage(of: .forYouDiscover)
        if discovery != nil {
            guard let discover, !discover.entries.isEmpty else { return nil }
        } else {
            guard let following, !following.entries.isEmpty else { return nil }
        }
        func page(_ list: FeedLocalCache.CachedList?) -> ForYouPage? {
            guard let list else { return nil }
            let projected = ForYouPage(posts: list.entries.map(Self.galleryPost(from:)), nextPageToken: list.nextCursor)
            return Self.decorate(projected, with: list.counters)
        }
        let followingPage = page(following) ?? ForYouPage(posts: [], nextPageToken: nil)
        let discoveryPage = page(discover)
        let authors = Set((followingPage.posts + (discoveryPage?.posts ?? [])).compactMap(\.authorID))
        return ForYouCachedPages(
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
    /// read per page, through `PostCounterReader`, which the profile gallery
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
        guard let counterClient, !page.entries.isEmpty else { return [:] }
        let byPostID = await PostCounterReader.counters(
            forPostIDs: page.entries.map(\.post.id.rawValue), using: counterClient
        )
        return Dictionary(byPostID.map { (PostID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// `page` with its counters applied — the network page and the stored
    /// one alike.
    private static func decorate(_ page: ForYouPage, with counters: [PostID: PostCounters]) -> ForYouPage {
        guard !counters.isEmpty else { return page }
        return ForYouPage(
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
    private static func map(_ page: FeedPage) -> ForYouPage {
        ForYouPage(
            posts: page.entries.map(galleryPost(from:)),
            nextPageToken: page.nextPageToken
        )
    }
}

extension ForYouRepository {
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
        return GalleryPost(
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
            reactionCount: entry.visibleLikeCount
        )
    }
}
