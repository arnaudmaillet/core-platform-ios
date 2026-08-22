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
/// ⚠️ **Both read the same corpus today.** There is no recommendation or
/// discovery RPC in the contracts — `timeline.v1` exposes only
/// `GetFollowingFeed` and `GetAudioFeed` — so the tab is served by the
/// following timeline and these are ORDERINGS of it, not separate feeds.
/// `.recent` sorts by publication and `.trending` by reactions. See
/// `dev/BACKEND_GAPS.md` §14; when a real discovery endpoint lands, this enum
/// is the seam that picks between corpora and the ordering falls away.
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
public protocol ForYouProviding: Sendable {
    func firstPage() async throws -> ForYouPage
    func page(after token: String) async throws -> ForYouPage
}

/// Serves the For You grid off the existing timeline read path.
///
/// It holds a `FeedProviding` rather than its own clients precisely because the
/// tab is the timeline today: one repository, one hydration path, one cache —
/// so a post opened from a tile is already warm in the snap feed it opens into.
/// When discovery gets its own endpoint this is the type that changes, and
/// nothing above it has to.
public actor ForYouRepository: ForYouProviding {
    private let feed: any FeedProviding
    /// Reads the numbers the timeline does not carry — see `withCounters`.
    /// Optional so a composition root without one still gets a working grid,
    /// with its counters hidden, which is what every card did before this.
    private let counterClient: (any Counter_V1_CounterServiceClientInterface)?

    public init(
        feed: any FeedProviding,
        counterClient: (any Counter_V1_CounterServiceClientInterface)? = nil
    ) {
        self.feed = feed
        self.counterClient = counterClient
    }

    public func firstPage() async throws -> ForYouPage {
        await withCounters(Self.map(try await feed.loadFirstPage()))
    }

    public func page(after token: String) async throws -> ForYouPage {
        await withCounters(Self.map(try await feed.loadPage(afterToken: token)))
    }

    /// Decorates a page with its `counter.v1` projections.
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
    private func withCounters(_ page: ForYouPage) async -> ForYouPage {
        guard let counterClient, !page.posts.isEmpty else { return page }
        let byPostID = await PostCounterReader.counters(
            forPostIDs: page.posts.map(\.id.rawValue), using: counterClient
        )
        guard !byPostID.isEmpty else { return page }
        return ForYouPage(
            posts: page.posts.map { post in
                guard let counts = byPostID[post.id.rawValue] else { return post }
                var decorated = post
                decorated.reactionCount = counts.likes ?? post.reactionCount
                decorated.commentCount = counts.comments
                decorated.viewCount = counts.views
                return decorated
            },
            nextPageToken: page.nextPageToken
        )
    }

    /// Projects hydrated timeline entries onto grid tiles.
    ///
    /// `commentCount`/`viewCount` are left absent HERE and filled by
    /// `withCounters` afterwards: a `FeedEntry` carries a like count and nothing
    /// else, so the numbers come from `counter.v1` in one batched read per page.
    ///
    /// `isRepost` is still absent and still asserted nowhere — a `FeedEntry`
    /// carries no `parent_id` lineage, and a repost split would need it threaded
    /// through first.
    private static func map(_ page: FeedPage) -> ForYouPage {
        ForYouPage(
            posts: page.entries.map { entry in
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
                    reactionCount: entry.likeCount
                )
            },
            nextPageToken: page.nextPageToken
        )
    }
}
