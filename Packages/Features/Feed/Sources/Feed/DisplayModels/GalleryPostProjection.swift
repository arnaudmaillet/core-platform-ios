import CoreModels
import Foundation
import MediaCore
import PostGrid

/// Turns the posts a GRID is already showing into the models the snap feed
/// renders, so a tapped post can be on screen in the tap's own frame.
///
/// # Why a projection exists at all
/// The destination is built around ids and fetches its own entries. Pushed
/// cold it therefore has nothing to draw until that fetch returns — measured
/// at ~0.7s of empty destination on a warm mock, and unbounded on a cold
/// network. The opener does not have that problem: it is showing these posts
/// right now. Handing them over is not a cache, a prefetch, or a second source
/// of truth — it is one frame of content, immediately replaced by the real
/// entries when they land (`FeedViewModel.seed` is additive and a seed
/// arriving after a real page is ignored).
///
/// # Why it is shared
/// It was a private static on `ForYouViewController`, which is why only For
/// You's openings were ever fast: the profile gallery holds exactly the same
/// `GalleryPost`s and threw them away at the route boundary, so the identical
/// tap on the identical post opened a black screen. Two surfaces mapping the
/// same type to the same model is one mapping, and it belongs beside the model.
///
/// A free type rather than an extension on `FeedItemDisplayModel`, so the
/// shared display model stays free of `PostGrid`: a grid is one opener among
/// several, and the feed is also reached from a Maps pin and from a route,
/// neither of which has a `GalleryPost` to offer.
enum GalleryPostProjection {
    static func seedModels(from posts: [GalleryPost]) -> [FeedItemDisplayModel] {
        posts.map(seedModel)
    }

    /// ⚠️ A PROJECTION, not a substitute for hydration: it carries only what a
    /// grid knows. Fields are left at their empty values rather than guessed,
    /// so nothing renders a number the backend has not confirmed.
    ///
    /// The metric line is the one thing that travels the OTHER way. A
    /// `FeedEntry` has a like count and no more, so a hydrated model knows
    /// strictly less about views and comments than the grid that opened it —
    /// which is why `cardMetrics` is seeded here and never recomputed
    /// downstream (see `CaptionBubbleCell.configure`).
    ///
    /// **How complete this is depends on the origin, and the difference is
    /// visible.** `ForYouDiscovery` and `ExploreRepository` build their
    /// `GalleryPost`s from feed entries, so they carry author identity and the
    /// page opens with its author pill already populated.
    /// `ProfileGalleryRepository` does not populate it at all — a profile grid
    /// has no need of it, since every tile on the authored pages is by the
    /// profile you are looking at — so a post opened from there shows an
    /// unnamed pill for the length of one fetch. Strictly better than the black
    /// screen it replaces, and worth closing at the repository rather than by
    /// guessing an author here (a tagged, saved or liked post is by somebody
    /// else, and this type cannot tell which).
    ///
    /// Both time strings are the FEED's registers, deliberately not the grid's.
    /// A tile spells an old post's age as a calendar date and the feed keeps
    /// counting days; seeding the tile's spelling made the nav pill rewrite
    /// itself from "28 May" to "75d" the moment the entry landed.
    static func seedModel(from post: GalleryPost) -> FeedItemDisplayModel {
        let handle = post.authorHandle.map { "@\($0)" } ?? ""
        let published = Date(timeIntervalSince1970: TimeInterval(post.publishedAtMS) / 1000)
        let now = Date()
        let age = FeedDisplayModelBuilder.relativeTime(from: published, to: now)
        return FeedItemDisplayModel(
            id: post.id,
            authorID: post.authorID ?? ProfileID(""),
            authorName: post.authorName ?? "",
            metaText: handle.isEmpty ? age : "\(handle) · \(age)",
            avatarURL: post.authorAvatarURL,
            caption: post.caption.isEmpty ? nil : post.caption,
            mediaURL: post.videoURL ?? post.thumbnailURL,
            mediaKind: post.kind == .video ? .video : .image,
            thumbnailURL: post.thumbnailURL,
            audioText: post.kind == .video && !handle.isEmpty
                ? "Original audio · \(handle)" : nil,
            likeCount: post.reactionCount ?? 0,
            timestampText: FeedDisplayModelBuilder.readableTimestamp(from: published, to: now),
            // Passed through as OPTIONALS, not collapsed to zero: this is the
            // one place that knows all three, and a text page's caption row
            // spells them exactly as the row it was opened from does.
            cardMetrics: PostCardMetrics(
                views: post.viewCount,
                reactions: post.reactionCount,
                comments: post.commentCount
            )
        )
    }
}
