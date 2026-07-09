import CoreModels
import UIKit

/// How the post-detail screen presents.
public enum PostDetailMode: Sendable, Equatable {
    /// The full post (header, media, engagement) above its comments — used when
    /// arriving at a post you can't already see (e.g. from a notification).
    case full
    /// Comments + compose bar only, no post header/media — used from the snap
    /// feed, where the post is already full-screen.
    case commentsOnly
}

/// Entry point contract for the Feed feature. Other modules (the app shell,
/// or features that embed feed surfaces) depend on this interface package —
/// never on the Feed implementation — so editing Feed internals recompiles
/// nothing but Feed itself.
@MainActor
public protocol FeedFeatureBuilding {
    func makeFeedViewController() -> UIViewController
    /// The detail screen for a single post. `.full` for the `.post` route (e.g.
    /// from a notification); `.commentsOnly` for the `.comments` route (the snap
    /// feed's comment button).
    func makePostDetailViewController(for postID: PostID, mode: PostDetailMode) -> UIViewController
}
