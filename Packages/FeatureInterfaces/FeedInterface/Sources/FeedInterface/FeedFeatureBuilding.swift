import CoreModels
import UIKit

/// How the post-detail screen presents.
public enum PostDetailMode: Sendable, Equatable {
    /// The full post (header, media, engagement) above its comments — used when
    /// arriving at a post you can't already see (e.g. from a notification).
    case full
    /// Comments + compose bar only, no post header/media — used from the snap
    /// feed, where the post is already full-screen. Text-only snap pages use
    /// this mode too: their engagement is pixel-identical to the media
    /// layouts' (the floating card simply has an empty media slot), so one
    /// mode serves every hosted engagement.
    case commentsOnly
}

/// Entry point contract for the Feed feature. Other modules (the app shell,
/// or features that embed feed surfaces) depend on this interface package —
/// never on the Feed implementation — so editing Feed internals recompiles
/// nothing but Feed itself.
@MainActor
public protocol FeedFeatureBuilding {
    func makeFeedViewController() -> UIViewController
    /// The For You discovery tab's root: curated content in a three-format
    /// grid (Activity / Media / Short), where tapping a tile opens the
    /// full-screen feed seeded from that page's ordered posts.
    ///
    /// It lives behind the *feed* builder rather than a feature of its own
    /// because the destination it opens (`makeSnapFeedViewController`) and the
    /// read path it shares are both here — one repository, one post cache, so
    /// a tapped tile is already warm in the feed it expands into.
    func makeForYouViewController() -> UIViewController
    /// The detail screen for a single post. `.full` for the `.post` route (e.g.
    /// from a notification); `.commentsOnly` for the `.comments` route (the snap
    /// feed's comment button).
    func makePostDetailViewController(for postID: PostID, mode: PostDetailMode) -> UIViewController
    /// A full-screen snap feed seeded with a fixed, ordered set of posts rather
    /// than the following timeline — the surface a Maps pin/cluster tap expands
    /// into. Reuses the entire snap feed (video pool, likes, comments, active-
    /// cell lifecycle); only the data source differs. The returned VC conforms
    /// to `ZoomTransitionDestination` so a hero transition can drive it.
    func makeSnapFeedViewController(postIDs: [PostID]) -> UIViewController
    /// Best-effort, cancellable warming of these posts into the shared cache, so
    /// a subsequent `makeSnapFeedViewController` hydrates from memory rather than
    /// the network — used by Maps to prefetch the visible pins on viewport
    /// settle, eliminating the metadata desync on tap. Safe for ids never opened.
    func prewarmPosts(_ ids: [PostID]) async
}
