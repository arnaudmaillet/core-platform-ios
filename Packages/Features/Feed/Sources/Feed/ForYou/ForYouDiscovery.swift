import CoreModels
import Foundation
import MediaCore
import PostGrid

/// The For You tab's source axis — what the filter tray's drop-down picks.
///
/// This is the discovery counterpart of the profile gallery's
/// `GalleryFilter.Source`, and deliberately a separate enum: the profile asks
/// "whose posts am I looking at" (own / reposts / tagged), which means nothing
/// on a curated surface. The *format* axis (Activity / Media / Short) is shared
/// — see `GalleryFilter.Format`.
///
/// ⚠️ **All three read the same corpus today.** There is no recommendation or
/// discovery RPC in the contracts — `timeline.v1` exposes only
/// `GetFollowingFeed` and `GetAudioFeed` — so the tab is served by the
/// following timeline and these are three ORDERINGS of it, not three feeds.
/// `.following` is the timeline's own order, `.recent` sorts by publication and
/// `.trending` by reactions. See `dev/BACKEND_GAPS.md` §14; when a real
/// discovery endpoint lands, this enum is the seam that picks between corpora
/// and the ordering falls away.
public enum DiscoverySource: Equatable, Sendable, CaseIterable {
    /// Most-reacted first. Ranked over what has been LOADED, not globally —
    /// see the note above.
    case trending
    /// Newest first.
    case recent
    /// The timeline's own order, unmodified.
    case following

    /// Applies the ordering. Stable within equal keys (`sorted(by:)` is not
    /// guaranteed stable, so ties break on publication then id — otherwise a
    /// page append could reshuffle rows the user is already looking at).
    func ordering(_ posts: [GalleryPost]) -> [GalleryPost] {
        switch self {
        case .following:
            posts
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

    public init(feed: any FeedProviding) {
        self.feed = feed
    }

    public func firstPage() async throws -> ForYouPage {
        Self.map(try await feed.loadFirstPage())
    }

    public func page(after token: String) async throws -> ForYouPage {
        Self.map(try await feed.loadPage(afterToken: token))
    }

    /// Projects hydrated timeline entries onto grid tiles.
    ///
    /// Two fields cannot be answered from a `FeedEntry` and are left absent
    /// rather than asserted: `commentCount`/`viewCount` (the timeline read
    /// hydrates likes only — the cells hide a counter with no value), and
    /// `isRepost` (a `FeedEntry` carries no `parent_id` lineage). The
    /// discovery axis reads none of them, so nothing is lost here; a repost
    /// split would need the lineage threaded through `FeedEntry` first.
    private static func map(_ page: FeedPage) -> ForYouPage {
        ForYouPage(
            posts: page.entries.map { entry in
                let attachment = entry.post.attachments.first
                let kind: GalleryPost.Kind = switch attachment.map({ MediaKind(mimeType: $0.mimeType) }) {
                case .video: .video
                case .image: .photo
                case nil: .text
                }
                return GalleryPost(
                    id: entry.post.id,
                    kind: kind,
                    isRepost: false,
                    thumbnailURL: attachment.flatMap { $0.thumbnailURL ?? $0.url },
                    // `url` is the stream itself, so a tile and the full-screen
                    // viewer open the same asset — see `GalleryPost.videoURL`.
                    videoURL: kind == .video ? attachment?.url : nil,
                    // Already 1 when the contract carried no dimensions, which
                    // reads as square and so withholds autoplay — see
                    // `GalleryPost.aspectRatio`.
                    aspectRatio: attachment?.aspectRatio ?? 1,
                    caption: entry.post.caption,
                    publishedAtMS: Int64(entry.post.publishedAt.timeIntervalSince1970 * 1000),
                    reactionCount: entry.likeCount
                )
            },
            nextPageToken: page.nextPageToken
        )
    }
}
